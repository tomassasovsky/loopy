---
date: 2026-07-04
topic: control-state-robustness
---

# Control-State Robustness: derive, don't accumulate — and fuzz the seams

## What We're Building

A structural fix for the class of bug where **derived control state goes stale**
— the "redo didn't relight the LED" family. Today, user-intent state is
scattered and imperatively maintained: `PedalCubit` owns mode / cursor /
`playArmed` (mutated by ~14 handler paths, reconciled ad-hoc in
`_onLooperState`), `TracksCubit` owns a second cursor + bank (bridged by
widget listeners), and `MonitorCubit` caches engine effect chains that drift
if any mutation path forgets to re-read. Every new engine state (like
undo-to-empty) forces us to re-audit every handler.

Two coordinated changes:

1. **Derive, don't accumulate.** One shared *control overlay* cubit owns the
   few things that are genuinely user intent and nothing else: `mode`,
   `cursor` (one, not two), `activeBank`, and Play-mode **exclusions** (tracks
   the user deliberately pulled out of the mix). Everything else — the armed
   set, every LED, the ring, transport-button behavior — becomes a **pure
   function of (LooperState × overlay)** computed at projection time. The
   armed set is no longer stored: `armed = sounding(truth) ∖ excluded`, so a
   redo, an on-screen play, or any future engine state is reflected the moment
   the snapshot changes — there is no set to forget to update. The
   `_onLooperState` reconciler, the stored `playArmed`, and the
   `PedalCursorBridge` all disappear.

2. **Fuzz the seams against the real engine.** A sequence-fuzzing test harness
   that drives the *actual* native engine (device-free: `configure` + a
   test-only `process(frames)` pump exposed through the FFI test surface, the
   same way `test_engine_core.c` pumps it) wired to the real
   `LooperRepository` + cubits. It fires seeded random event sequences across
   all surfaces (pedal buttons, keyboard commands, on-screen actions, engine
   time passing) and asserts a written-down invariant set after every step.
   Failures print the seed + a shrunk repro sequence. This mechanically hunts
   the bugs the projection refactor can't prevent (engine↔UI contract gaps,
   ordering races) — the exact seam where the last four bugs lived.

## Why This Approach

Approaches considered:

- **Invariant asserts only** — cheapest, but catches bugs at runtime in front
  of the user rather than preventing or pre-finding them.
- **Fuzz harness only** — finds bugs mechanically but leaves the architecture
  that breeds them; every finding is another hand-patched reconciler edge.
- **Derive inside PedalCubit only** — kills the armed-set staleness but keeps
  the duplicated cursor, the widget bridge, and per-cubit drift (MonitorCubit
  pattern) intact.
- **Push overlay into LooperRepository** — one stream, but mixes UI intent
  into the data layer against the repo's layering conventions.
- **Chosen: shared overlay cubit + pure projection + real-engine fuzzing** —
  the projection makes staleness structurally impossible for everything
  derivable; the fuzzer guards the seam that remains (engine semantics × user
  sequences); the overlay cubit keeps layering clean (intent stays in the
  presentation layer, truth stays in the repository).

This also matches the codebase's own stated principle — "loopy is the single
source of truth" (pedal firmware brainstorm 2026-06-14: state that lives in
two places drifts; the pedal became a pure thin client for exactly this
reason). This refactor applies the same medicine one layer up: the cubits
become thin clients of the repository.

## Key Decisions

- **Sequencing: safety net first, refactor second.** Phase 1 builds the fuzz
  harness + invariant spec against *today's* architecture (behavior-preserving
  — it must go green on current code, and any red it finds is a real bug to
  fix first). Phase 2 executes the projection refactor **under** that green
  fuzzer, so a live music tool's control path is never restructured without a
  regression net. Rationale: the refactor's risk is subtle UX drift
  (park/resume, mode-entry arming); the fuzzer pins those behaviors before
  anything moves.
- **Armed set becomes derived; the residual stored intent is a closed,
  audited inventory.** Some intent is irreducibly stateful — the design's
  honesty is that *every* stored bit is enumerated with a written invalidation
  rule, and the fuzzer checks each rule as an invariant. Nothing else may be
  stored; the armed set itself is always derived:
  `armed = parked ? parkedResume : (sounding(truth) ∖ excluded)`.
  Rationale: sets you *derive* can't go stale; sets you *store* can — so store
  the minimum and spec each one.

  | Stored bit | Written by | Invalidated / cleared when |
  |---|---|---|
  | `mode` | mode footswitch, `M` key, mode chip, boot default, clear-all (an explicit whole-rig reset → record) | never implicit otherwise |
  | `cursor` (one, shared) | track buttons, tile clicks, digit keys | clamped to a valid channel on every snapshot; clear-all and session load reset/clamp |
  | `activeBank` | bank button/switch (browse WITHOUT moving the cursor — a real flow), and any cursor write (bank = cursor ~/ 4) | stored, with the cursor-write rule; never drifts from a visible cursor |
  | `excluded` (Play-mode opt-outs) | deliberate disarm of a sounding/armed track | track empties, clear of that track, clear-all, mode entry, session load |
  | `parkedResume` (what Rec/Play resumes) | latched at PARK INTENT time from the then-derived armed set (Stop-park), or ∅ (mute-last-track park → resume falls back to all content); mode entry into Play sets it to all content tracks | any member empties, clear-all, mode entry, session load, next resume |

  Definitions the derivation depends on (state-based, mute-ignored so
  keyboard-muting everything does NOT park — today's deliberate behavior):
  `parked := anyContent ∧ no content track ∈ {playing, overdubbing}`.
  This table ships as executable predicates in the fuzzer's invariant spec —
  documentation and enforcement are the same artifact.
- **One cursor, one owner**: `selectedTrack` + `activeBank` live only in the
  shared overlay cubit; `TracksCubit` keeps names/showIndicators (true UI
  prefs) and drops selection/bank; `PedalCursorBridge` is deleted. Rationale:
  the bridge was a patch over duplicated state; the two undo surfaces must be
  physically unable to target different tracks.
- **LED/frame projection is a pure top-level function**
  `projectFrame(LooperState, ControlOverlay) → PedalStateFrame`, unit-testable
  without a cubit. `PedalCubit` shrinks to: transport binding/hotplug, event
  decode → intents, and pushing `projectFrame(...)` diffs to the wire.
- **Fuzz against the real engine, not a fake**: the unit suite today never
  touches the native engine (only `integration_test/` does, with a live
  device); the fake-engine path would make the fuzzer test a second
  implementation. Enabler: expose `le_engine_configure` + `le_engine_process`
  (and a deterministic input generator) through a test-only FFI surface so
  Dart tests pump the engine synchronously, exactly like the C tests do.
  Fallback if FFI-in-`flutter test` proves painful on CI: run the fuzz suite
  under `dart test` in `packages/loopy_engine` — CI already has a dedicated
  native-tests job (`.github/workflows/main.yaml`, `run_native_tests.sh` on
  ubuntu) that builds the engine, a natural home for it.
- **Invariants are the spec, written once**: e.g. `EMPTY ⟹ dark LED ∧ not
  armed ∧ no content`, `sounding ∧ ¬excluded ⟹ armed ⟹ green`,
  `canRedo ⟹ redo() != INVALID` (unless capturing), `clear-all ⟹ no track
  canRedo`, `undoDepth/redoDepth monotonic rules across passes`, `mute never
  changed by undo/redo except redo-from-empty ⟹ unmuted`. The same predicate
  list runs in the fuzzer after every step AND as debug-mode asserts on every
  `projectFrame` call in the app — one spec, two enforcement points.
- **Fuzzer ergonomics, YAGNI-fenced**: a hand-rolled seeded PRNG, fixed step
  budget per case, and simple prefix/removal shrinking (~100 lines) — no
  property-testing framework dependency. Failure output = replayable seed +
  minimal sequence pasted as a ready-to-commit regression test. A small corpus
  of found seeds becomes a permanent regression suite; CI runs N random seeds
  per push.
- **MonitorCubit is follow-up scope**: same disease (cached engine truth,
  manual re-read), same medicine (derive from the repository stream), but it's
  isolated — flagged as a second, smaller plan after this one lands.

## Success Criteria

- The stored `playArmed` set, the `_onLooperState` reconciler, and
  `PedalCursorBridge` no longer exist; grep proves no cubit stores state
  derivable from a `LooperState` snapshot outside the inventory table above.
- The invariant spec exists as one Dart file used by both the fuzzer and
  debug-mode projection asserts; every bug fixed in the 2026-07-03/04 sessions
  is covered by at least one invariant.
- Fuzzer: green in CI against the real engine — default budget ~50 seeds ×
  200 steps per push (tuned in planning; hard-capped ≤ 2 min of CI time),
  deeper nightly run optional. One-time validation: each previously-found bug
  class reproduces (goes red) when its fix is reverted locally — proof the net
  actually catches this class.

## Open Questions

- **Parked membership semantics**: when everything is parked (STOPPED), what
  exactly should Rec/Play resume — the last-played subset (`parkedResume`) or
  all content tracks? Needs a UX decision in planning.
- **Engine pump surface**: add `le_engine_process` to the public FFI header
  guarded as test-only, or a separate `loopy_engine_test` dylib target?
  (Planning question — affects bindings regen.)
- **Fuzzer time model**: fixed frames-per-step vs random block sizes
  (including 0-frame pumps to hit drain/queued-undo windows) — likely both,
  weighted.
- **Persisted default-mode load path**: `mode` moves to the overlay cubit
  (settled); its boot-time restore currently lives in `PedalCubit._restore` —
  verify no other consumer reads it before the overlay cubit exists.

## Inputs

- Latent-issue hunt (session 2026-07-04) — disposition:
  - **Fixed in-session** (each with a regression test): stale-grid deadlock /
    tempo-lock after last-track undo-to-empty (grid now resets on a fresh
    define unless a sibling's redo needs it; quantized presses act immediately
    while the transport is held); re-punch during the drain window restarting
    the layer capture instead of tearing it; command-ring replay of presses
    made while the device was down; session save/load of the ghost grid;
    drain RT budget scaled per lane; repository lane-mute cache mirroring the
    engine's forced unmutes (reconnect no longer re-mutes an audible take);
    a11y "Undone" announcements and undo/redo buttons gated while capturing;
    lane-count changes rejected mid-capture.
  - **Fix-first items for the plan**: (M2) shadow-layer memory model —
    allocate at track length (quantized), byte-budget eviction alongside the
    256-slot cap, free on clear/evict, surface the OOM "undo capture stopped"
    condition; (L3) `le_engine_export_track` vs the punch-out fade tail — a
    save inside the ~10 ms window copies under concurrent write; skip/settle
    on `a_layer_in_flight`.
- Research maps: PedalCubit state ownership + mutation table, TracksCubit /
  LooperBloc / bootstrap replay inventory, existing test-pattern survey (no
  property-based testing today; unit suite is 100% fake/mock-based; CI has a
  dedicated native-tests job).
