# feat: make clear undoable/redoable

**Status:** Planned (awaiting direction sign-off) · **Date:** 2026-07-16 · **Type:** feature (engine + repository + control)

> Tracking: #219 (`stage:plan`, `autonomy:plan-gate`). Verified against `master` @ `8c97a44`.
>
> Scope fixed with the user: **full-stack restore**, **per-track + clear-all**, **audio + FX + mutes**.

## What "clear" destroys today

Clear is deliberately the opposite of undo. `engine_commands.c:661` says so in as many words:
*"The master grid is deliberately kept — redo needs it, and a full reset stays Clear's job."*

| Layer | Site | What it throws away |
| --- | --- | --- |
| Engine (control) | `le_engine_clear` (`engine_commands.c:563`) | `undo_count = 0`, `le_clear_redo`, `outstanding_count = 0`, `dub_generation++`, len → 0 |
| Engine (audio) | `handle_clear` (`engine_process.c:495`) | state → EMPTY, multiple → 1, unmutes every lane, **resets master clock + viz when the last track empties** |
| Repository | `LooperRepository.clear` (`looper_repository.dart:783`) | FX chains (cache + engine) **and persists them empty** via `onLaneChainChanged`; `_forgetLaneMutes` |
| Control | `ControlCubit.clearAll` (`control_cubit.dart:483`) | fans out per-track clear + unmute + `saveLaneMute` |

**The audio survives.** Clear never frees pool buffers (RT-unsafe by design — `engine_process.c:530`), so the PCM is still resident; the slots merely become reclaimable by `track_acquire_slot`. Restoring is bookkeeping, not allocation. That is what makes this tractable.

## The core obstacle

The undo stack is `int32_t undo_stack[LE_POOL_SLOTS]` (`engine_private.h:282`) — **bare pool-slot indices**. A layer is representable; "a clear happened here" is not. Clear is not a layer: it carries the whole prior state (live slot + len + multiple + mutes + the stack beneath it).

So the per-track history must become a stack of **tagged entries**, not slot indices.

## Design (Option A — extend the per-track model)

Rejected alternative (Option B): a parallel command history in Dart. It fights the existing per-track engine model, and the audio restore still needs the engine work regardless — so it buys nothing and duplicates the invariant surface.

### Entry model

```c
typedef enum { LE_HIST_LAYER = 0, LE_HIST_CLEAR = 1 } le_hist_kind;

typedef struct {
  int32_t kind;
  int32_t slot;        /* LAYER: the retired slot. CLEAR: the pre-clear live slot. */
  int32_t len;         /* CLEAR: pre-clear loop length */
  int32_t multiple;    /* CLEAR: pre-clear loop multiple */
  int32_t state;       /* CLEAR: pre-clear PLAYING/STOPPED */
  uint32_t muted_mask; /* CLEAR: per-lane mute bits (LE_MAX_LANES) */
} le_hist_entry;
```

A clear **pushes a `LE_HIST_CLEAR` restore point on top of the existing stack rather than resetting it** — the layers beneath stay put and stay peelable after the restore. That is exactly the "full stack" semantic the user asked for, and it falls out of the data structure for free.

- **undo** pops `LE_HIST_CLEAR` → restore `a_live`/len/multiple/state/mutes on every active lane in lockstep, push the mark onto `redo_stack`.
- **redo** re-applies the clear (empty again), push back onto `undo_stack`.
- **undo** on a `LE_HIST_LAYER` → unchanged `le_undo_swap`.

This reuses the existing lockstep-across-lanes rule and the control-thread ownership of `a_live`, so it introduces no new thread-safety surface.

### The three open calls

**1. Master-grid invalidation (needs your sign-off).**
`handle_clear` resets the loop clock once the last track empties. A restore point whose `len` no longer matches a re-established master grid is incoherent — you cannot drop a 4-bar take back onto a grid a later recording redefined.

*Proposal:* a clear restore point is **invalidated when a new recording redefines the master grid**, mirroring how `le_clear_redo` already invalidates the resurrect path on a fresh action. Concretely: clear-all → undo restores everything (grid still 0, restore point re-establishes it from the saved `len`); clear-all → record → undo does **not** resurrect. Simple, matches the existing invalidation idiom, and the alternative (grid coexistence / re-alignment) is a much larger design.

**2. Undo-a-clear-all polarity.**
Undo/redo are per-track and channel-addressed (`control_cubit.dart:513`; pedal tap = undo, long-press = redo on the cursor's track). Clear-all is global.

*Proposal:* clear-all pushes a restore point **per track**, and a new global "undo clear-all" fans out — no parallel global history. Consequence to accept: after clear-all, a per-track undo restores just that track. That is coherent, and it keeps one history model.

**3. Pool eviction.**
`track_acquire_slot` (`engine_commands.c:45`) evicts the **bottom** of the undo stack under pressure. It must never evict a slot a `LE_HIST_CLEAR` depends on, and its `used` scan must learn the tagged entries. Layers *beneath* a restore point may still be evicted — graceful degradation (you lose peel depth, not the restore).

### Repository / FX + mutes

The engine cannot own chains. `LooperRepository.clear` snapshots `_laneEffects` + lane mutes for the channel into a `_clearRestore` map keyed by channel, and restores them when a clear is undone — re-pushing to the engine and re-persisting via `onLaneChainChanged` (otherwise settings keeps the emptied chain and a restart replays it — the same F3 hazard the current code notes at `looper_repository.dart:791`).

The repository must know an undo *restored a clear* rather than peeled a layer. Cleanest: the engine reports it — a new `le_engine_undo_kind` out-param or a snapshot-visible `clearRestorePoints` depth on `Track`, so `LooperRepository.undo` can branch without inferring from before/after state.

`applySession` must keep destructive semantics → it calls a `le_engine_clear` that takes an explicit "no restore point" flag (or keeps the current entry point, with the undoable path as a new one). Session load must never be undoable.

## Risks / interactions to cover

- **Performance recording (D-CLEAR).** `clearAll` awaits `persistLiveLanes` first; `perf_render.c:687` special-cases `LE_CMD_CLEAR` during render. A restore point must not confuse layer staging (`le_stage_retired_layer` stages regardless of generation — deliberately).
- **`dub_generation`.** Still bumped on clear (it invalidates in-flight retire events); the restore point must not resurrect a stale in-flight layer.
- **Memory.** Retained slots stay pinned per cleared track (256 slots/track, lazily allocated, layer-quantum sized). Clear no longer returns them to the pool until invalidation — call out in `docs/PROGRESS.md`.
- **`le_effective_state` / posted-but-unacked ordering.** The restore point is control-thread state; the empty→restored flip is a state command and must go through `le_mark_state_cmd` like the undo-to-empty path (`engine_commands.c:184`).

## PR breakdown (each independently mergeable)

1. **Engine: tagged history entries.** Replace `int32_t undo_stack/redo_stack` with `le_hist_entry`; teach `track_acquire_slot`, `le_undo_swap`, `le_handle_retired`, `le_clear_redo`. Pure refactor — no behaviour change, all existing engine tests stay green. *(`autonomy:auto`)*
2. **Engine: clear restore point.** Undoable clear entry point + `LE_HIST_CLEAR` push/undo/redo + master-grid invalidation rule; `applySession`'s clear stays destructive. Native tests for restore, invalidation, eviction, in-flight-layer race. *(`autonomy:merge-gate`)*
3. **Dart engine layer + repository.** FFI surface for the new entry point + restore-kind reporting; `_clearRestore` snapshot/restore of FX + mutes with re-persist. *(`autonomy:merge-gate`)*
4. **Control + UI.** `ControlCubit.clearAll` restore points + global undo-clear-all; surface it (pedal/keyboard/UI affordance TBD). *(`autonomy:merge-gate`)*

## Verification

- Native: `packages/loopy_engine/src/test` — restore fidelity (PCM identical), full-stack peelability after restore, invalidation-on-new-recording, eviction never drops a restore point, clear-during-in-flight-layer.
- Dart: repository restores chains + mutes + re-persists; `applySession` clears stay destructive; control-layer invariants (`test/control/invariants_test.dart`, `test/control/control_projection_test.dart`).
- Real app: record → overdub ×2 → clear → undo → take + both layers back, FX + mutes intact, still peelable.
