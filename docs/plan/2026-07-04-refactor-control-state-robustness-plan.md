---
title: "refactor: control-state robustness — derived projections + real-engine fuzzing"
type: refactor
date: 2026-07-04
---

## refactor: control-state robustness — Extensive

> **Status (2026-07-04):** Phase 0 landed (3df7145) and Phase 1 landed
> (e5a0e4c) — the fuzzer is green (60 seeds x 160 steps + 4-case corpus) and
> the invariant spec asserts on every projection. Phase 2 executes next,
> under the green fuzzer, in a fresh /build session (atomic PR).

## Overview

Kill the "derived state went stale" bug class (the redo-didn't-relight-the-LED
family) structurally, in three PR-sized phases: **(0)** the two engine
fix-first items the 2026-07-04 issue hunt deferred, **(1)** a sequence-fuzzing
safety net that drives the *real* native engine + real cubits against a
written invariant spec, **(2)** the projection refactor — one shared control
overlay, everything else computed from `(LooperState × overlay)` — executed
under the green fuzzer from phase 1.

Design rationale, approach comparison, and the stored-intent inventory live in
[docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md](../brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md).

## Problem Statement

User-intent state is scattered and imperatively maintained: `PedalCubit` owns
mode/cursor/`playArmed` mutated by ~14 handler paths and reconciled ad-hoc in
`_onLooperState` (lib/pedal/cubit/pedal_cubit.dart); `TracksCubit` owns a
second cursor + bank, bridged by widget listeners
(lib/pedal/view/pedal_cursor_bridge.dart); `MonitorCubit` caches engine effect
chains kept honest only by re-read-after-write. Every new engine state
(undo-to-empty, redo-from-empty, queued undo) forces a re-audit of every
handler — four LED/armed-set bugs shipped from exactly this in two days.
Nothing mechanically hunts the engine↔UI seam: the unit suite never touches
the native engine, and no property/sequence testing exists.

Two engine items from the hunt remain open and block "robust" claims:
per-pass undo layers each allocate `max_loop_frames` (92 MB/layer/lane at the
8-minute cap; OOM silently disables undo capture), and
`le_engine_export_track` can copy a buffer while the punch-out fade tail is
still writing it.

## Proposed Solution

- **Phase 0 — engine fix-first**: right-size + budget the undo layer pool;
  make session capture wait out in-flight layers.
- **Phase 1 — safety net**: device-free FFI pump for the real engine, one
  invariant spec file, a seeded sequence fuzzer across all control surfaces
  with shrinking + a seed corpus, wired into CI. Must go green against
  *today's* architecture.
- **Phase 2 — derive, don't accumulate**: `ControlOverlayCubit` owns the
  closed stored-intent inventory (mode, defaultMode, cursor, bank, excluded,
  parkedResume); armed set and every LED become pure functions; PedalCubit
  shrinks to transport I/O + projection; TracksCubit drops selection/bank;
  the cursor bridge and the reconciler are deleted.

## Technical Approach

### Architecture

```
                       engine truth (polled snapshot)
  LooperRepository ──────────────► LooperState ────────┐
                                                       │  pure functions
  ControlOverlayCubit ───────────► ControlOverlay ─────┤  (lib/control/control_projection.dart)
   mode · defaultMode · cursor ·                       │
   bank · excluded · parkedResume                      ├─► armed = parked ? parkedResume
   (closed inventory, each bit has                     │            : sounding ∖ excluded
    a written invalidation rule)                       ├─► PedalStateFrame (LEDs, ring)
          ▲                                            ├─► tracks view selection/mode
          │ intents                                    └─► debug asserts: invariant spec
  ControlIntents (one interpreter: pedal decode AND
  keyboard/screen actions call the SAME methods —
  park, resume, mode entry, clear-all — so the
  surfaces cannot diverge in command sequences)

  fuzzer (test/fuzz/): seeded events ─► [pedal MIDI | intents | cursor |
      mode | poll tick | engine pump 0..N frames] ─► after every settled step:
      invariant spec over (LooperState, overlay, projections) — real native
      engine underneath
```

**Semantics pinned by flow analysis** (the derivation is only sound with
these written down):

- `parked := anyContent ∧ no content track ∈ {playing, overdubbing}` —
  state-based and **mute-ignored**, so keyboard-muting every track does NOT
  park (today's deliberate behavior, pedal_cubit.dart:322-325).
- `parkedResume` latches at **park-intent time** from the then-derived armed
  set (engine truth lags the stop commands by a poll — snapshot-time latching
  would always capture ∅). Two park paths, two rules: Stop-park keeps the
  set; mute-last-track park sets ∅ (Rec/Play then resumes ALL content —
  today's fallback, pedal_cubit.dart:461-478).
- Mode entry into Play = enter **parked** with `parkedResume` = all content
  tracks — this reproduces today's `_enterPlayMode` arming of stopped AND
  muted tracks, which `sounding ∖ excluded` alone cannot.
- Clear-all is an explicit whole-rig reset: mode → record, cursor → 0,
  excluded/parkedResume cleared — **unified across surfaces** (today only the
  pedal resets mode; the `C` key gains it — a deliberate, small UX change).
- `activeBank` stays a stored bit: bank browse WITHOUT moving the cursor is a
  real flow (on-screen BankSwitch arms the other bank's tracks); any cursor
  write sets `bank = cursor ~/ 4`.
- Session load invalidates: excluded/parkedResume cleared, cursor clamped.

### Implementation Phases

#### Phase 0: engine fix-first (PR 1) — ~1 day

**0a. Undo-layer memory model** (packages/loopy_engine/src/core)

- [ ] Per-lane `pool_cap[LE_POOL_SLOTS]` (allocated frames per slot) in
      `le_lane` (engine_private.h). Shadow slots allocate at
      `round_up(track_len, LE_LAYER_QUANTUM)` (quantum ~1 s) instead of
      `max_loop_frames` (`le_post_dub_shadows`, engine_commands.c); grow
      (realloc-or-replace) when a reused slot is too small for the current
      track length.
- [ ] **Live-buffer invariant**: any slot becoming the RECORDING target must
      be `max_loop_frames`-sized — enforce in `le_prepare_new_capture`,
      `le_engine_import_track`, and `le_engine_set_lane_count` (a fresh
      defining/new-track capture writes up to the cap; undo can have swapped a
      len-sized snapshot slot into `a_live`).
- [ ] **Deliberately NOT in scope** (YAGNI per simplicity review): byte-budget
      eviction, ack-gated free lists, and an `a_undo_starved` flag. Quantized
      allocation makes layer cost proportional to actual loop length, the
      256-slot count cap bounds the rest, and calloc failure already degrades
      gracefully (shadow posting stops; audio unharmed). Revisit only if
      profiling shows real pressure — parked in Future Considerations.
- [ ] C tests: slot reuse across lengths (small→large regrow), live-buffer
      invariant on record-after-undo, quantized-size accounting via a test
      hook. Existing suite stays green.

**0b. Export vs fade tail** (engine_snapshot.c / session_repository)

- [ ] Add `layer_in_flight` to `le_track_snapshot` (loopy_engine_api.h —
      additive ABI; regen bindings) → `TrackSnapshot.layerInFlight` →
      `Track.layerInFlight`.
- [ ] `SessionRepository._capture` treats an in-flight track as unsettled:
      wait (poll with timeout ~2 s) for `!layerInFlight` before exporting;
      on timeout skip the track loudly (throw, not silent drop). Acceptance:
      exported audio equals post-drain content, byte-deterministic (settle,
      don't skip — a save inside the window must not lose the tail).
- [ ] Dart tests: capture waits out a simulated in-flight flag; timeout
      throws. C test: export pumped through the `a_layer_in_flight` window
      matches the post-drain buffer exactly.
- [ ] Note for the fuzzer's depth invariants: the EXISTING count-cap eviction
      (oldest-first at 256 slots) shrinks `undoDepth` without user action —
      whitelist it.

Success criteria: native + Dart suites green; a 2 s loop's undo layer costs
~2 s of floats, not 30 s; recording after deep undo still captures at full
cap.

#### Phase 1: the safety net (PR 2) — ~1–2 days

**Enablers**

- [ ] Export `le_engine_configure` + `le_engine_process` with `LE_EXPORT` in
      loopy_engine_api.h (documented "test pump — not part of the app
      surface"); regen per the documented two-step workflow
      (`dart run ffigen --config ffigen.yaml` THEN
      `dart format lib/src/generated/loopy_engine_bindings.dart` — skipping
      the format rewrites the whole file and hides the real diff). Same
      workflow applies to phase 0b's snapshot-field regen.
- [ ] `PumpedNativeEngine implements AudioEngine`
      (packages/loopy_engine/lib/src/pumped_native_engine.dart, exported from
      the MAIN barrel like the existing `MockAudioEngine` precedent — no new
      testing.dart sub-library): `start()` →
      `le_engine_configure` only (no device); `pump({int frames, double
      input})` → `le_engine_process` with a deterministic input block;
      `snapshot()` reuses NativeAudioEngine's marshalling. Library loading:
      REUSE NativeAudioEngine's existing DynamicLibrary lookup, adding one
      `LOOPY_ENGINE_LIB` environment override checked first (tests/CI point
      it at an explicitly built lib).
- [ ] Test-lib build (pinned, no "or"): a small script
      `packages/loopy_engine/tool/build_test_lib.sh` compiling the same
      engine source list as run_native_tests.sh into a shared lib
      (`-shared -fPIC`, per-OS extension) at a known path. Locally it's
      one command; in CI the app-test job runs it and exports
      `LOOPY_ENGINE_LIB` before `flutter test`.

- [ ] Latch the undo long-press target at PRESS time (pedal_cubit.dart:592
      fires redo against `state.selectedTrack` at timer fire — an on-screen
      click mid-hold retargets it). Two-line fix; the fuzzer would find it.
- [ ] Expose the quantize-pending arm in the snapshot (`a_pending` is already
      published engine-side; add `pending` to `le_track_snapshot`, regen) so
      invariants can distinguish "ignored" from "deferred", plus a liveness
      invariant: an accepted command takes effect within one loop period of
      pumping.

**The spec**

- [ ] `lib/control/invariants.dart` (NOT under test/ — lib code cannot import
      test/, and the debug asserts live in lib; exported from the
      `lib/control/control.dart` feature barrel): `List<ControlInvariant>` of
      named predicates over
      `(LooperState, PedalState, TracksState, PedalStateFrame)` — the
      signature grows a `ControlOverlay` parameter in phase 2 when PedalState
      loses mode/cursor/bank.
      Each invariant is tagged **timeless** (must survive phase 2) or
      **current-behavior pin** (phase 2 replaces it with a pre-written
      successor — written NOW, so the refactor's expected diffs are explicit,
      not discovered). Invariants assert on SETTLED states (after pump + poll
      tick), with a bounded-staleness rule: within N ticks of quiescence,
      projections match truth.
- [ ] The stored-intent invalidation table ships here as executable
      predicates (rows for clear-all, track-empties, mode-entry, session
      load) — the brainstorm's table and its enforcement are one artifact.
- [ ] `Track.undoStarved ⟹ undo affordance stops growing` lands in the spec
      the moment the phase-0 engine bit exists — no released window where
      undo silently dies with no observable rule.
      Initial set (grows in phase 2):
      - EMPTY track ⟹ dark LED ∧ not armed ∧ lengthFrames == 0
      - sounding (playing/overdubbing, content, unmuted) ⟹ armed ⟹ green LED
      - muted ⟹ LED off; capturing ⟹ red LED (rec mode)
      - canRedo ∧ ¬capturing ⟹ `redo()` returns OK
      - after clear-all: no track canRedo, master resets, all unmuted
      - undo/redo never change mute, EXCEPT redo-from-empty ⟹ unmuted
      - cursor is always a valid channel; bank == cursor ~/ 4
      - loopLengthMicros == 0 ⟺ no track has/captures content
      - queued-undo eventually applies (bounded pumps)
- [ ] Debug-assert hook: `assert(checkControlInvariants(...))` at
      `PedalCubit._pushProjected` (moves into the pure projection in phase 2).
      `assert(...)` only — zero release-mode cost by construction; no runtime
      flag, no alternative gating.

**The fuzzer**

- [ ] `test/fuzz/control_sequence_fuzz_test.dart`: real engine
      (`PumpedNativeEngine`) → real `LooperRepository` (injected ticker —
      polls are explicit fuzzer steps) → real `LooperBloc`, `PedalCubit`
      (pollInterval: zero), `TracksCubit`, `SimulatorPedalTransport` for
      pedal-surface events. Runs under `fake_async` so the undo long-press
      `Timer` (pedal_cubit.dart:592) and any debounce are fuzzer-controlled
      (`elapse` is itself an action).
      Action alphabet: pedal press/release per button (incl. held/long-press
      via `fakeAsync.elapse` as an explicit action), encoder deltas,
      `Looper*Pressed` bloc events, cursor select, bank browse, mode toggle,
      clear-all, `PedalCubit.reconnect()` (hotplug), session save/load,
      engine pump of 0/1/partial/full-loop frames, and the repository poll
      tick as a SEPARATE action from pumps — so snapshot-lag races are
      reachable. Microtasks flushed deterministically between steps
      (unawaited settings saves), plugin-editor timers excluded from the
      alphabet.
- [ ] Extract the key→intent mapping out of `TracksCommands.handleKey`
      (needs BuildContext/l10n today, tracks_commands.dart:126-140) into a
      context-free function the fuzzer drives — otherwise real behaviors like
      "digit key selects AND mute-toggles in play mode" go untested.
- [ ] Seeded PRNG; per-case budget ~200 steps; on failure: prefix/removal
      shrink, print seed + minimal action list as paste-ready Dart.
- [ ] `test/fuzz/corpus/` — named replays of every found bug + the four fixed
      2026-07-03/04 bug classes (redo-relight, clear-all-canRedo,
      redo-unmute, stale-grid), each annotated with the invariant it trips.
      Validation task: revert each fix locally once and confirm its corpus
      case goes red — the net must not be tautological.
- [ ] CI: the full-stack fuzzer imports app cubits, so it MUST run under
      `flutter test` — but the app test job is the reusable
      `very_good_workflows/flutter_package.yml` (no pre-steps injectable),
      and a DLL-requiring test would redden it. Follow the repo's OWN
      precedent (`test/screenshots/` + dart_test.yaml): declare a `fuzz` tag,
      self-skip with a clear message when `LOOPY_ENGINE_LIB` is unset (plain
      local `flutter test` stays green), and add a bespoke `fuzz` job to
      .github/workflows/main.yaml: checkout → `tool/build_test_lib.sh` →
      `flutter test --tags fuzz` with the env exported. Because fuzz tests
      are outside the coverage job, `lib/control/*` must clear the 90%
      min_coverage gate from its UNIT tests alone (projection, overlay
      reducer, ControlIntents — all directly tested in test/control/).
      Budget: ≤ 2 min (≈50 seeds × 200 steps).
- [ ] `fake_async` added as a dev_dependency (it resolves transitively via
      flutter_test, but `depend_on_referenced_packages` requires the explicit
      declaration).

Success criteria: fuzzer green on current `master`+phase-0 code across ≥5k
random cases locally; every red it finds first is triaged (fix or documented
expectation) before phase 2 starts.

#### Phase 2: derive, don't accumulate (PR 3) — ~2–3 days

- [ ] `lib/control/cubit/control_overlay_cubit.dart` +
      `control_overlay_state.dart` (part-file Equatable state, same pattern
      as pedal_state.dart incl. the copyWith sentinel): the closed inventory
      {mode, defaultMode, cursor, activeBank, excluded, parkedResume} with
      the brainstorm's invalidation table implemented in ONE reducer over
      `(overlay, LooperState)` — the only place stored intent changes in
      response to engine truth (e.g. excluded/parkedResume entries drop when
      their track empties; cursor clamps).
      Boot restore of `defaultMode` moves here from `PedalCubit._restore`.
      New feature barrel `lib/control/control.dart` (house-style library
      doc); the bridge deletion also removes its export from
      lib/pedal/pedal.dart. Unit tests mirror in test/control/.
- [ ] `lib/control/control_projection.dart` (pure, top-level; filename
      matches its exports repo-wide):
      `Set<int> armedTracks(LooperState, ControlOverlay)`,
      `PedalTrackLed ledFor(...)`, `PedalStateFrame projectFrame(...)` —
      logic lifted from PedalCubit `_ledFor`/`_projectFrame`/reconciler,
      with `armed = parked ? parkedResume : sounding ∖ excluded`.
      Debug-mode invariant asserts run here (same spec file as the fuzzer).
- [ ] `lib/control/control_intents.dart` — the ONE intent interpreter both
      surfaces call (park, resume, mode entry incl. finalize-captures,
      clear-all, track press semantics): pedal decode and keyboard/screen
      paths invoke the SAME methods, so command sequences cannot diverge.
      Wiring (pinned): ControlIntents holds the LooperRepository reference
      for COMMANDS OUT; the overlay cubit owns its OWN subscription to
      `LooperRepository.looperState` for STATE IN (its reducer applies the
      invalidation table per snapshot). State flows in via the subscription,
      commands flow out via intents — structurally no second command path.
      Stretch (optional, not a gate): metamorphic fuzz invariant
      "pedal Rec/Play ≡ keyboard `R` on the same state" — only if the
      fuzzer's replay makes it cheap; skip rather than build a
      state-clone framework for it.
- [ ] `PedalCubit` slims to: transport bind/hotplug/output picker, MIDI event
      decode → ControlIntents calls, frame diff-push of
      `projectFrame(latest LooperState, latest overlay)` — re-pushed on
      EITHER stream and on rebind (reads the current overlay: unplug → change
      mode via keyboard → replug must show the new mode/bank).
      `PedalState` keeps only bindStatus/availableOutputs/boundOutputId.
      DELETED: stored `playArmed`, `_onLooperState` reconciliation,
      `_sounding` edge logic, `mode/selectedTrack/activeBank` fields.
      `setDefaultMode` + `_setMode`/`_enterPlayMode` migrate TOGETHER (the
      settings-page picker's live-apply side effect must never straddle the
      split). Dead-API sweep — class-qualified to avoid a wrong deletion:
      **PedalCubit**.selectBank / **PedalCubit**.togglePlayArm have no lib/
      callers (wire to the overlay or delete); **TracksCubit**.selectBank IS
      live (tracks_chrome.dart:308, the bank-browse flow) and migrates to the
      overlay's bank field.
- [ ] `TracksCubit` drops `selectedChannel`/`activeBank` (keeps
      names/showIndicators); `PedalCursorBridge` deleted; provider wiring in
      lib/app + lib/looper/view/looper_page.dart adds the overlay cubit.
      **Atomicity**: ownership move + ALL consumer migrations + bridge
      deletion land in one PR — any window with two live cursors (or two
      modes) reintroduces the exact divergence bug the bridge patched.
- [ ] Consumer migration (all reads become overlay reads):
      lib/looper/view/tracks_view.dart:40, track_meters.dart:30,
      tracks_commands.dart:96/136 (+ digit-key select), track_column.dart
      taps, tracks_chrome.dart:308 (bank browse), settings_page.dart:124/166
      (defaultMode), pedal_faceplate.dart (unchanged — reads the frame),
      simulator path unchanged. FINAL STEP: a grep-driven sweep for
      `TracksCubit`/`PedalCubit` state reads (`selectedChannel|activeBank|
      \.mode|playArmed|selectedTrack`) — the hand-curated list above is a
      starting point, not the completeness proof.
- [ ] Behavior parity: every UX flow pinned by phase 1 stays green —
      mode-entry auto-arm, park/resume subset, mute-last-parks-all, bank
      switching, clear-all reset, hotplug re-push, undo-to-empty/redo LED
      cycle, quantize pending display. Migrate/replace the retired
      PedalCubit unit tests; projection gets direct pure-function tests.
- [ ] Post-refactor: delete invariants that became unrepresentable (stale
      armed set can no longer exist) and note that in the spec file.

Success criteria: fuzzer green (same seeds + fresh ones); grep shows no cubit
stores snapshot-derivable state outside the inventory; app suite green;
manual smoke on hardware pedal + simulator.

## Alternative Approaches Considered

See the brainstorm doc: invariant-asserts-only, fuzz-only,
derive-inside-PedalCubit-only, and overlay-in-repository were considered and
rejected (staleness stays possible, or layering breaks).

## Acceptance Criteria

### Functional Requirements

- [ ] All phase success criteria above
- [ ] The 2026-07-03/04 bug classes are corpus-covered and go red on revert
- [ ] No behavior change observable at the pedal/UI for the pinned flows
      (single deliberate exception: on-screen clear-all now resets mode, like
      the pedal)
- [ ] Hotplug: unplug → change mode/cursor from the keyboard → replug →
      pedal frame reflects the current overlay
- [ ] Boot with a `play` default mode + persisted session: armed set and
      LEDs resolve correctly as tracks come up (pinned as a fuzz scenario)

### Non-Functional Requirements

- [ ] Fuzz job ≤ 2 min in CI; deterministic (seed-replayable) failures only
- [ ] Undo memory: layer cost proportional to loop length; budget eviction
      exercised in tests; RT budget unchanged (no new audio-thread work)
- [ ] No new framework dependencies (hand-rolled PRNG/shrinker);
      `fake_async` declared as a dev_dependency

### Quality Gates

- [ ] `bash packages/loopy_engine/src/test/run_native_tests.sh` — ALL PASSED
- [ ] `flutter test` + package suites + `flutter analyze` clean, each phase
- [ ] Each phase is an independently green, revertable PR

## Dependencies & Prerequisites

- Phase 2 depends on phase 1 green; phase 1 depends on phase 0 only for the
  in-flight snapshot field (fuzzer invariants use it). Uncommitted 2026-07-03/04
  work on `refactor/control-state-robustness` lands first (its own PR).

## Risk Analysis & Mitigation

| Risk | Mitigation |
|---|---|
| Projection refactor drifts UX (park/resume, mode-entry arming) | Phase-1 fuzzer + parity checklist pinned BEFORE refactor; invariants tagged timeless vs pin with pre-written phase-2 successors; hardware smoke test |
| FFI pump flaky on CI runners | Fixed seeds for the corpus in the required job; random seeds in a tolerant job; the app test job builds the engine lib explicitly (no device I/O anywhere) |
| Free-on-clear use-after-free (audio thread vs freed shadow) | Ack-gated deferred free list; C test for ordering; ASan run locally |
| Fuzzer nondeterminism (timers, ticker) | fake_async everywhere; repository ticker injected; polls + elapse are explicit actions; microtask flush between steps |
| Derived LEDs lag commands by ≤ one poll (~16 ms) | Invariants phrased over settled states + bounded-staleness rule; imperceptible to users (frame push already diff-based) |
| Overlay cubit accretes engine access and becomes a second command path | ControlIntents is the only command interpreter; the overlay cubit is a pure inventory + reducer; metamorphic invariant pins surface equivalence |
| Fuzzer green-but-hollow (spec tautological under the new architecture) | Revert-the-fix validation per corpus case; timeless invariants derived from engine truth, not from the projection |

## Future Considerations

- MonitorCubit gets the same medicine (derive effects from the repository
  stream) as a follow-up plan.
- The fuzzer's action alphabet can grow to sessions (save/load) and device
  loss/reconnect once those paths are deterministic under the pump.
- `a_undo_starved` UI badge.

## Documentation Plan

- Update the brainstorm doc's status line when each phase lands.
- `test/fuzz/README.md`: how to run, replay a seed, add a corpus case.

## References & Research

### Internal References

- Brainstorm + stored-intent inventory: docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md
- Reconciler being replaced: lib/pedal/cubit/pedal_cubit.dart (`_onLooperState`, `_sounding`)
- Cursor duplication: lib/pedal/view/pedal_cursor_bridge.dart, lib/looper/cubit/tracks_cubit.dart
- Engine pump precedent: packages/loopy_engine/src/test/test_engine_core.c (`process_const`, `drain`)
- Snapshot polling / injectable ticker: packages/looper_repository/lib/src/looper_repository.dart:75-90
- Per-pass undo machinery: packages/loopy_engine/src/core/engine_commands.c, engine_process.c, engine_private.h
- Prior art for "single source of truth": docs/brainstorm/2026-06-14-looper-pedal-firmware-protocol-brainstorm-doc.md

### Related Work

- 2026-07-03/04 session: per-layer unlimited undo/redo + clear-unmute + the
  ten LED/undo bug fixes now on `refactor/control-state-robustness`
  (uncommitted at plan time).
