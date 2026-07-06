---
title: "fix: input FX not recorded into takes (snapshot race) — robust one-owner fix"
type: fix
date: 2026-07-05
---

## fix: input FX not printing onto recorded takes — the snapshot race — Standard

## Problem (root cause, verified against the code)

Put FX on a hardware input, record it, and the take plays **dry** — the UI /
session show the FX but the engine take has none.

There are **two** record-time snapshot mechanisms that copy an input's monitor
FX chain onto the recording lane, and they can disagree:

1. **Dart** — `LooperRepository.record` → `_snapshotMonitorChainsOntoLanes`
   ([looper_repository.dart:635/662]). Reads the **synchronously-correct**
   `_monitorEffects[input]` cache, captures plugin opaque state (D-P1), writes
   `_laneEffects` + persistence. **It never pushes the copied chain to the
   engine's lane FX.**
2. **C engine** — `le_snapshot_input_fx_to_lanes`
   ([engine_commands.c:300], called from `le_engine_record` when a track leaves
   EMPTY). Reads `monitors[c].a_fx_count` — an atomic the audio thread only
   stores **one buffer after** the FX write is published through the command
   ring ([engine_process.c:839]). It runs **synchronously on the control
   thread**, so if record fires before the audio thread drained the ring it
   reads `0`, `continue`s (L311), and copies **nothing** → dry take.

The race window is widest with **auto-record** (snapshot + arm in one
control-thread turn) and add-FX-then-record in quick succession.

Two independently confirmed facts shape the fix:

- **Non-clobber (good):** the C-side `continue`s on an empty monitor and keeps
  the lane's existing chain (never pushes `count=0`) — so a Dart-pushed lane
  chain would survive a lost race.
- **Plugin divergence (risk):** the C-side copies `a_fx_type`/`a_fx_param`
  only; it cannot carry a plugin's opaque state. For a **plugin** monitor FX, a
  *won* race copies a stateless placeholder onto the lane, and because the
  C-side runs after Dart's push in the ring, it would **clobber** the correct
  Dart snapshot. So "Dart pushes + keep the C-side" is safe for built-ins but
  **not** safe for plugin monitor chains.

## Authoritative flow (the organizing principle)

**The `LooperRepository` is the single authority for all FX.** Its
`_monitorEffects` / `_laneEffects` caches are the source of truth; the
FX-fingerprint fuzzer's **`cache == engine`** invariant is the enforced contract
that every downstream consumer must match it. Consumers:

- **Persistence + `LooperState` / UI** — already derive from the repo cache.
  Consistent.
- **Engine** — must be a *pure sink*: it holds exactly the lane FX the repo
  pushes and computes none of its own.

The bug exists because the engine currently is **not** a pure sink — the C-side
`le_snapshot_input_fx_to_lanes` is a *second, independent authority* that
recomputes the snapshot from the engine's own (ring-deferred, plugin-incomplete)
monitor state. Two authorities → divergence (the race, the plugin placeholder).

## Decision — make the engine a pure sink (one authority)

**Remove the engine's self-snapshot; the repository is the sole computer of the
record-time snapshot and pushes it to the engine like any other lane-FX edit.**

1. `LooperRepository.record` (record-from-EMPTY): `_snapshotMonitorChainsOntoLanes`
   computes each lane's chain into `_laneEffects` from the synchronous
   `_monitorEffects` cache (with D-P1 plugin-state capture) + persistence — as
   today — and then **pushes it to the engine** via `_applyLaneEffects(channel,
   lane)` for each active lane. No read of ring-deferred engine state; no race.
2. Native: drop the `le_snapshot_input_fx_to_lanes` call from `le_engine_record`
   (and the now-dead function + `snapshot_copy_count` bookkeeping). The engine
   no longer computes a snapshot; it only applies what the ring delivers.
3. The native contract test (`test_engine_core.c` `snapshot_copy_count`
   assertions) is **rewritten** to the new contract: `le_engine_record` does
   *not* self-snapshot (the host owns it). The "snapshots once, not on overdub,
   never on the audio thread" behavior is re-asserted at the **repository**
   level (record-from-EMPTY snapshots; overdub does not) where the authority now
   lives.

Why this is the consistent choice (not just the correct one): there is exactly
**one** computation of the snapshot (the repo's), so there is nothing to race or
diverge; the engine's lane FX are, by construction, whatever the repo last
pushed; and the existing `cache == engine` fuzzer invariant becomes the single
mechanism that *proves* the engine relies on the authority. Every non-
authoritative part (engine, persistence, UI) now derives from the one owner.

## Alternatives (rejected)

- **Keep the C-side, have Dart re-apply *after* to win the ring.** Correct and
  pure-Dart, but leaves **two** computations where one silently overrides the
  other — the opposite of "non-authoritative parts rely on the authority." A
  masked second authority is exactly the fragility we're removing. Rejected in
  favour of one owner.
- **Dart pushes *before* `_engine.record` + keep the C-side.** Unsafe: on a won
  race the C-side runs after Dart and clobbers plugins with a placeholder.
- **C-side reads control-thread-visible monitor state / a ring fence.** Keeps
  two authorities; native work; blocks the record path. Rejected.

## Must-verify while building

1. **No *other* caller/consumer of the engine self-snapshot.** Confirmed:
   `le_snapshot_input_fx_to_lanes` has a single caller (`le_engine_record`), and
   `snapshot_copy_count` is only read by the one native test — so removal is
   contained to that call site + that test.
2. **`_applyLaneEffects` sends the captured chain**, including plugin entries
   with their frozen state (the same object D-P1 wrote into `_laneEffects`).
3. **Push covers exactly the track's active lanes** and only on
   record-from-EMPTY (not overdub / non-EMPTY), preserving the old gate; the
   per-lane recorded-input (`_laneInput[(ch,lane)]`) is respected.
4. **No audible gap from async push.** Lane FX are *playback* FX and the take is
   EMPTY→recording; the pushed chain lands (ring drained each buffer) well
   before the take ever plays, so dry-record is intact and playback is correct.
5. **`cache == engine` stays the single enforced contract** — the fuzzer's
   lane-FX invariant is what proves the engine (now a pure sink) matches the
   authority after record-snapshot.

## Test plan (the crux of "no issues")

- **Deterministic race regression (repo test):** set monitor FX on an input,
  then `record(channel)` **without draining the ring** (no `process()` between),
  then drain once and assert the lane's engine chain == the monitor chain.
  Without the fix this fails (dry); with it, passes. Cover **built-in and
  plugin** monitor chains.
- **Plugin snapshot:** a plugin on the input records a lane whose FX is the
  frozen plugin (state carried), not a placeholder.
- **Non-clobber:** a lane with staged/persistence-restored FX and a *dry* input
  keeps its own chain after record.
- **FX fuzzer:** add a "set monitor FX then record-from-empty" action and keep
  the `cache == engine` lane-FX invariant green (this catches ordering
  regressions the unit test can't enumerate).
- Existing suites stay green; `flutter analyze` clean; native-tests pass.

## Files (primary)

- `packages/looper_repository/lib/src/looper_repository.dart` — `record` pushes
  the snapshotted lane chains to the engine (`_applyLaneEffects`) on
  record-from-EMPTY. (Repo is now the sole snapshot computer.)
- `packages/loopy_engine/src/core/engine_commands.c` — remove the
  `le_snapshot_input_fx_to_lanes` call from `le_engine_record` + the function;
  drop `snapshot_copy_count` (engine.c / engine_private.h / engine_internal.h /
  the `_for_test` accessor).
- `packages/loopy_engine/src/test/test_engine_core.c` — rewrite the snapshot
  assertions to the new contract (engine does not self-snapshot).
- `packages/looper_repository/test/…` — the deterministic race + plugin tests,
  and the record-from-EMPTY-snapshots / overdub-does-not assertions (moved here
  from the engine test).
- The FX fuzzer harness — the "set monitor FX → record-from-empty" action.

## Acceptance criteria

- Recording an input with built-in **or** plugin FX yields a take whose lane
  chain equals what was monitored, **regardless of ring-drain timing**
  (auto-record included).
- **One authority:** the repository computes the snapshot; the engine holds only
  what the repo pushed (no engine self-snapshot); `cache == engine` is the
  single enforced contract, kept green by the fuzzer.
- Deterministic race test + plugin test + fuzzer action pass; native-tests +
  full app/repo suites green; `flutter analyze` clean; `dart format` stable.
- Dry-recording invariant intact (only playback FX are set).
