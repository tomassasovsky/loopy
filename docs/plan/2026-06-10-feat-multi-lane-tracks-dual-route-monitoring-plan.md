---
title: "feat: multi-lane tracks + dual-route (record/monitor) per-input effects"
type: feat
date: 2026-06-10
---

## feat: multi-lane tracks + dual-route (record/monitor) per-input effects — Extensive

> Source brainstorm: [docs/brainstorm/2026-06-10-multi-lane-tracks-dual-route-monitoring-brainstorm-doc.md](../brainstorm/2026-06-10-multi-lane-tracks-dual-route-monitoring-brainstorm-doc.md)
> Requirements: `~/Downloads/audioroutingrequirements.md` (voice memo)

## Overview

Rework the looper's routing/monitoring/effects so each input has **two
independent routes**: a **clean recording route** into a *lane* of a track, and
an **independent live monitoring route** to the output — each route with its own
chainable effects. A **track becomes a multi-lane container**: assigning several
inputs to one track records each as its **own clean mono buffer** (not merged),
all sharing one transport and loop, all playing back together. Effects on the
record route are **per-lane** and non-destructive; effects on the monitor route
are **per-input**, live-only, and never recorded.

This replaces the per-track pre/post "stage" model and the single global
monitor-FX bus shipped on PR #11, reusing the existing effect DSP substrate.

## Problem Statement

The current engine is **mono-per-track**: a track averages its selected input
channels into one buffer, so two inputs on one track are *merged* and
indistinguishable. Effects are a single per-track chain with a pre/post `stage`,
and live monitoring runs through one **global** monitor-FX bus (or "follows" a
track). The requirements doc wants the opposite shape:

1. Recording is always clean (already true after PR #11). ✅
2. Each input recorded into a track stays **separate** and **both play back**
   (no merge). ❌ conflicts with the mono core.
3. Two distinct per-input routes — clean record→track→track-FX→out, and a
   separate input→out monitor with its **own** FX that never records. ❌ monitor
   FX is currently global, not per-input.
4. Monitoring works independent of whether the track is recorded/playing. ❌
   today's "follow" couples them.
5. Chainable effects in series. ✅
6. Tracks stack by loop layers **and** by number of inputs. ❌ no multi-lane.

## Proposed Solution

Adopt the locked brainstorm decisions:

- **`le_track` owns an array of lanes (Impl A).** A **lane** is the fundamental
  recordable unit: `{ assigned input channel, clean mono buffer + undo pool,
  effect-chain config + DSP state (le_fx_state), output mask, volume, mute }`.
  The **track** owns the shared transport, master-clock phase, loop
  length/multiple, quantize, pending-arm, and a single undo span driven across
  all its lanes.
- **Per-lane record effects.** Relocate the existing per-track effect chain into
  the lane (the DSP already exists; this is a move, not new code). Drop the
  pre/post `stage` field — a lane has one non-destructive chain applied on
  playback.
- **Per-input monitor subsystem.** A new `le_monitor_input[]` array (one slot
  per hardware input): `{ enabled, output mask, effect-chain config + DSP state
  }`. The monitored input is summed to the output through its own chain, live,
  never recorded. Replaces the global monitor-FX bus, the monitor masks model,
  and "monitor follows a track".
- **Lazy lane allocation.** Lane loop buffers / undo pools / delay rings
  allocate on first record into that lane (control thread), keeping idle memory
  flat despite the larger worst-case capacity.

### Capacity & memory

- `LE_MAX_LANES` per track = `LE_MAX_INPUTS` (hardware input ceiling; propose
  **8**, matching `LE_MAX_TRACKS`). Worst case `LE_MAX_TRACKS × LE_MAX_LANES =
  64` lanes, but **only recorded lanes allocate buffers** (lazy), so realistic
  memory ≈ today's (a handful of active lanes).
- Per allocated lane: `LE_UNDO_SLOTS (8) × max_loop_frames × 4 bytes` pool +
  delay rings (`LE_FX_MAX` × 1 s) when delay effects are used.
- `le_monitor_input[LE_MAX_INPUTS]` is fixed-size, tiny except delay rings
  (lazy, per the existing pattern).

## Technical Approach

### Architecture

**New engine data model** (`packages/loopy_engine/src/engine.c`):

> **Review-applied simplifications (vs. first draft):** undo/redo stacks and the
> shared `record_pos` move to `le_track` (one undo span / one phase-locked write
> head across lanes — lanes own only `pool[]` + `a_live`); `lane_count` is a
> plain control-thread int (like `track_count`), not an atomic and not a ring
> command; per-lane `a_viz` is dropped (YAGNI until the UI phase confirms a
> per-lane-waveform need — track-level viz stays).

```c
// A single recordable input lane (the old "track" collapses into this).
// Lanes own only their audio content + routing + effects; the TRACK owns
// transport, the shared write head, and the undo span (see le_track).
typedef struct le_lane {
  _Atomic int32_t  a_input_channel;     // hw input this lane records (-1 = none)
  _Atomic uint32_t a_output_mask;       // per-lane playback destinations
  _Atomic uint32_t a_vol_bits;          // per-lane volume (float bits)
  _Atomic int32_t  a_muted;             // per-lane mute
  float* pool[LE_UNDO_SLOTS];           // lazily allocated loop buffers
  _Atomic int32_t  a_live;              // live pool index
  _Atomic int32_t  a_len;               // recorded length (per-lane content)
  // record-route effects (non-destructive, on playback) — relocated le_fx_state
  _Atomic int32_t  a_fx_count;
  _Atomic int32_t  a_fx_type[LE_FX_MAX];
  _Atomic uint32_t a_fx_param[LE_FX_MAX][LE_FX_PARAMS];
  le_fx_state      fx;
} le_lane;

typedef struct le_track {
  le_lane lanes[LE_MAX_LANES];
  int32_t lane_count;                   // active lanes (control-thread plain int)
  // shared transport / clock (owned by the track, drives all active lanes)
  _Atomic int32_t a_state;              // transport state (shared)
  _Atomic int32_t a_multiple;           // loop length in base loops
  _Atomic int32_t a_pending;            // quantized-arm published state
  int32_t pending_record, pending_trigger;
  int32_t record_pos;                   // ONE shared, phase-locked write head
  uint64_t start_iter;
  int32_t track_quantize;               // -1 inherit
  int32_t target_multiple;              // 0 inherit
  // one undo span across all lanes (drives each lane's pool[] in lockstep)
  int32_t undo_stack[LE_UNDO_SLOTS]; int undo_count;
  int32_t redo_stack[LE_UNDO_SLOTS]; int redo_count;
  // (no per-track buffer/mask/vol/mute/fx anymore — those live on lanes)
} le_track;

// Per-input live monitor (engine-level), replacing the global monitor-FX bus.
// NOTE: no volume/mute field yet — deliberate YAGNI; if the UI phase needs
// monitor gain, add a_vol_bits/a_muted + a setter then (documented follow-up).
typedef struct le_monitor_input {
  _Atomic int32_t  a_enabled;
  _Atomic uint32_t a_output_mask;
  _Atomic int32_t  a_fx_count;
  _Atomic int32_t  a_fx_type[LE_FX_MAX];
  _Atomic uint32_t a_fx_param[LE_FX_MAX][LE_FX_PARAMS];
  le_fx_state      fx;
} le_monitor_input;
// engine adds: le_monitor_input monitors[LE_MAX_INPUTS];
```

**Process loop** (`le_engine_process`):
- For each track: if transport is recording/overdubbing, **every active lane**
  captures its `a_input_channel` sample **clean** at the track's *one* shared,
  latency-compensated write head (`le_track.record_pos` — reuse today's
  offset/phase-lock math, applied per lane; no new compensation logic).
- Playback: each active lane reads its buffer → its own `fx` chain → summed into
  the outputs its `a_output_mask` selects, scaled by per-lane vol, gated by
  per-lane mute. Lanes are **never** averaged.
- Monitor: for each hardware input `c`, if `monitors[c].a_enabled`, take the
  live input sample → `monitors[c].fx` chain → summed into `monitors[c]`'s output
  mask. Independent of all track state.

**Commands.** Lane *count* is a control-thread plain int (set before the first
record into the new lane, like `track_quantize`/`target_multiple`), **not** a
ring command. RT-concurrent lane edits go through new ring codes (from 26):
`SET_LANE_INPUT`, `SET_LANE_OUTPUT`, `SET_LANE_VOLUME`, `SET_LANE_MUTE`,
`SET_LANE_FX`, `SET_LANE_FX_COUNT`; and `SET_MONITOR_INPUT` (enable+output),
`SET_MONITOR_INPUT_FX`, `SET_MONITOR_INPUT_FX_COUNT`. Transport commands
(`RECORD`/`STOP`/`PLAY`/`CLEAR`/`UNDO`) stay **track-addressed** and fan out to
active lanes. **Remove** `SET_MONITOR_FX`, `SET_MONITOR_FX_COUNT`,
`SET_MONITOR_FX_TRACK`, `SET_MONITOR_INPUT_MASK`, `SET_MONITOR_OUTPUT_MASK`.

**Snapshot / projection (do not skip this layer).** The engine snapshot and the
Dart projection currently expose per-track `inputMask`/`outputMask`/`volume`/
`muted`/`undoDepth`. These become **per-lane**: the published snapshot struct +
`EngineSnapshot`/`TrackSnapshot` (`engine_snapshot.dart`) gain a `lanes` array,
and `LooperRepository._project()` maps per-lane snapshot → `Lane` models. Decide
`readTrackVisual(channel)`: add a per-lane variant or define documented
lane-summed semantics. Undo depth is per-track (shared span).

**Persistence keys** (`settings_repository.dart`). New per-lane / per-input key
functions mirroring `_trackEffectsKey(channel)`:
`lane_effects.$channel.$lane`, `lane_input.$channel.$lane`,
`lane_output.$channel.$lane`, `lane_vol.$channel.$lane`,
`lane_mute.$channel.$lane`, `lane_count.$channel`; and per input:
`monitor_input.$input` (enabled+output) + `monitor_input_fx.$input`. **Drop**
the removed singletons `monitor.fx`, `monitor.mode`, `monitor.input_mask`,
`monitor.output_mask`, and the per-track `track_input_mask.$channel`/
`track_output_mask.$channel`/`track_effects.$channel`. Pre-release ⇒
drop-and-default (tolerate/ignore stale keys, like `loadUiMode` does); no
data migration.

### Implementation Phases

> **Phase boundaries revised after technical review.** The engine work splits
> into two PRs at the FFI break (transport core vs. FX-relocation+monitor), and —
> critically — **each engine PR regenerates `loopy_engine_bindings.dart` and
> stubs the new `NativeAudioEngine` setters as `throw UnimplementedError()`** so
> `flutter test` stays green at every step. The original "update Dart only enough
> to compile in Phase 3" left the engine PRs not actually green; this fixes that.

#### PR 1: Engine multi-lane transport core — `feat/multilane-engine-core`

Files: `packages/loopy_engine/src/engine.c`, `loopy_engine_api.h`,
`src/test/test_engine_core.c`, regenerated `loopy_engine_bindings.dart`,
`native_audio_engine.dart` (stubs), the three fakes (compile-only).

- Introduce `le_lane` with the **full target struct** (incl. `le_fx_state fx`
  fields, even though dispatch stays track-addressed until PR 2); rewrite
  `le_track` to `lanes[LE_MAX_LANES]` + plain `lane_count` + shared transport,
  shared `record_pos`, and the one undo span. Add `LE_MAX_LANES`/`LE_MAX_INPUTS`
  (=8).
- Transport fans out to all active lanes; per-lane clean capture (no average);
  playback sums each lane (through its `fx`, which is empty this PR); one undo
  span drives every lane's `pool[]` in lockstep; lazy per-lane buffer/undo-pool
  allocation on first record.
- Lane routing commands + FFI: `SET_LANE_INPUT/OUTPUT/VOLUME/MUTE` (+
  `le_engine_set_lane_*`). `lane_count` is set by `le_engine_set_lane_count`
  (control-thread: writes the plain int and lazily allocates the new lane's
  buffers), **not** a ring command.
- Regenerate bindings + `dart format`; stub the new lane setters in
  `NativeAudioEngine` (`throw UnimplementedError()`); adjust the three fakes only
  enough to compile (they aren't exercised yet).
- **Native tests:** two inputs → two un-merged lanes both play; per-lane vol/mute;
  undo across lanes (one undo removes the last pass on every lane); lazy-alloc
  keeps idle memory flat; per-lane phase-lock matches the single-buffer baseline
  sample-for-sample; **audio thread never reads an unallocated `pool[]`** when
  `lane_count` and lazy-alloc disagree (RT null-guard).
- **Gate:** `ALL PASSED` native; `flutter test` green (stubs uncalled).

#### PR 2: Per-lane FX relocation + per-input monitor — `feat/multilane-fx-monitor`

Files: same engine + tests + bindings/stubs.

- Relocate the effect chain from track to lane: rename `SET_FX`→`SET_LANE_FX`,
  `SET_FX_COUNT`→`SET_LANE_FX_COUNT`; **drop `a_fx_stage`** (one non-destructive
  chain); update `fx_apply_chain` call sites; `le_engine_set_track_fx*` →
  `le_engine_set_lane_fx*`.
- Add `le_monitor_input monitors[LE_MAX_INPUTS]`; rewrite the process-loop
  monitor block to per-input enable + chain + output. **Remove** the global
  monitor-FX bus (`a_monitor_fx_*`, `SET_MONITOR_FX*`), the monitor-follow
  (`a_monitor_fx_track`), and the global monitor masks.
- New FFI: `le_engine_set_monitor_input(enabled,output)`, `…_fx`, `…_fx_count`,
  `…_param`; remove `le_engine_set_monitor_fx*`/`_track`/`_input_mask`/
  `_output_mask`.
- Regenerate bindings + `dart format`; replace old monitor-fx stubs, add
  monitor-input stubs in `NativeAudioEngine`; keep the fakes compiling.
- **Native tests:** per-lane FX colors only its lane; monitoring an input routes
  it live through its chain, never recorded, independent of track playback; two
  inputs monitored with different chains don't interfere; disabling stops it.
- **Gate:** `ALL PASSED` native; `flutter test` green.

#### PR 3: Dart engine layer — `feat/multilane-dart-engine`

Files: `packages/loopy_engine/lib/src/audio_engine.dart`,
`native_audio_engine.dart` (fill in the real bodies, remove the stubs),
`engine_snapshot.dart` (per-lane `lanes` array on `TrackSnapshot`),
`track_effect.dart` (drop `stage` — model-wide: constructor/`toJson`/`==`/
`hashCode`/`copyWith`; old persisted chains still decode, the extra `stage` key
is ignored, **no migration needed**), and the **three divergent fakes**:
- `packages/looper_repository/test/helpers/fake_audio_engine.dart` — add
  call-recording maps (`laneFx`, `laneInput`, `laneOutput`, `laneVol`,
  `laneMute`, `laneCount`, `monitorInput`, `monitorInputFx`, …) mirroring the
  existing `trackFx`/`monitorFx` maps, so PR-4 repo tests have an assertion
  surface; remove the now-dead `monitorFx`/`monitorFxParam`/`lastMonitorFxTrack`.
- `test/helpers/fake_audio_engine.dart` (app-level) — own impl + `last…` fields.
- `packages/session_repository/test/helpers/fake_session_engine.dart` — terse
  `=> EngineResult.ok` stubs.
- Interface: `setLaneInput/Output/Volume/Mute/Fx/FxCount/FxParam`, `setLaneCount`,
  `setMonitorInput/…Fx/…FxCount/…FxParam`; remove `setMonitorFx*` and `stage`.
- **Gate:** bindings diff is regeneration-only and `dart format`-clean.

#### PR 4: Dart repository + blocs + persistence — `feat/multilane-domain`

Files: `packages/looper_repository/lib` (incl. `_project()`),
`packages/settings_repository/lib`, `packages/session_repository/lib`,
`lib/looper` + `lib/audio_setup` blocs/cubits.

- Models: `Track { List<Lane> lanes; transport/loop/quantize/undoDepth }`,
  `Lane { inputChannel, outputMask, volume, muted, List<TrackEffect> effects }`;
  `InputMonitor { enabled, outputMask, List<TrackEffect> effects }` — named
  `InputMonitor` (not `MonitorInput`) to avoid colliding with the existing
  `StoredAudioConfig.monitorInput` boolean.
- **Projection:** `LooperRepository._project()` maps the per-lane snapshot into
  `Track.lanes`; per-lane meters/undo via the new snapshot fields. Add a repo
  test asserting per-lane snapshot → `Lane` mapping.
- `LooperRepository`: remember/reapply lanes + input monitors on (re)start;
  per-lane and per-input effect apply (reuse the existing apply pattern); delete
  the dead `_applyMonitor`/`setMonitorFollowTrack`/`_monitorFollowChannel`
  machinery.
- Persistence: implement the new key functions and drop the removed keys (see
  the *Persistence keys* note above); tolerate stale keys (drop-and-default).
- `session_repository`: per-lane export ripples through `exportTrack`/
  `SessionTrack`. **Decision:** for this pass, keep session export **lane-0 only**
  with a documented limitation (full multi-lane stems are a follow-up task),
  rather than expanding the session format now.
- Blocs/cubits: extend `LooperBloc` events for lanes; rework `MonitorCubit` into
  a per-input list — **delete `MonitorMode`** (custom-vs-follow distinction is
  gone) and the `MonitorFxEditor`-backing state.

#### PR 5: UI rework — `feat/multilane-ui`

Files: `lib/looper/view` (routing view), `lib/audio_setup/view`.

- Routing view: a track shows its **lanes** (per-lane input assignment, effect
  chain via the reused card editor, output, vol/mute) and supports add/remove
  lane. A separate **per-input monitor** section (enable, output, effect chain).
- Remove the pre/post stage UI and `MonitorFxEditor`/global-bus UI.
- Widget + golden tests; regenerate goldens.
- **Note:** the lane-assignment + dual-route view is a real redesign; do a short
  mock-first design pass **before** coding (see Risk R4). If per-lane waveform
  thumbnails are wanted, add per-lane viz to the engine snapshot **here** (it was
  intentionally deferred from PR 1).

## Alternative Approaches Considered

- **Group-of-mono-tracks (Impl B).** Treat today's mono track *as* the lane and
  add a track-group transport binding; reuses ~all the engine. **Rejected** in
  refine-approach in favor of a single clean `track`-owns-`lanes` data model,
  accepting the larger rewrite.
- **Keep the global monitor-FX bus as a master layer atop per-input.** Rejected
  (YAGNI — two monitor-FX concepts to learn).
- **Per-track (whole-track) effects instead of per-lane.** Rejected — the worked
  example requires `in1`'s lane wet while `in2`'s lane is dry.

## Acceptance Criteria

### Functional Requirements

- [ ] Two inputs assigned to one track record as **two separate clean lanes**;
      both play back; neither is merged.
- [ ] Recording a track captures **all its active lanes at once** (shared
      transport), phase-locked to the master loop.
- [ ] Each lane has its **own** non-destructive effect chain; changing/removing a
      lane's effect never alters the recorded buffer and doesn't affect sibling
      lanes.
- [ ] Per-lane output routing, volume, mute behave independently.
- [ ] Any input can be **monitored live** to chosen outputs through its **own**
      effect chain; that signal is **never recorded** and works whether or not a
      track is recorded/playing.
- [ ] The pre/post `stage`, the global monitor-FX bus, and "monitor follows a
      track" are fully removed.
- [ ] Undo on a track removes the last pass across all its lanes consistently.

### Non-Functional Requirements

- [ ] Real-time safety preserved: no malloc/lock/syscall in `process()`; all lane
      buffers/rings allocated on the control thread before audio reads them.
- [ ] Idle memory stays flat (lazy lane allocation); document the worst-case
      budget.
- [ ] No averaging regressions in single-lane (one-input) tracks vs. today.

### Quality Gates

- [ ] Native C tests pass for each engine PR (`ALL PASSED`).
- [ ] `dart analyze` clean across all touched packages; `flutter test` green at
      **every** PR — including the engine PRs (via bindings regen + stubs) —
      excluding the pre-existing foreign `big_picture_view_test` WIP failure.
- [ ] Regenerated `loopy_engine_bindings.dart` is `dart format`-clean; its diff
      is regeneration-only (no hand edits).
- [ ] Golden tests updated for the reworked routing view (PR 5).
- [ ] Each of the 5 PRs is independently-mergeable and green, in dependency order.

## Success Metrics

- Worked example reproduces: `in1`+`in2` → track 1, `in1` lane wet (2 FX), `in2`
  lane dry, both play; `in2` (or any input) also monitorable live with its own
  delay that never records.
- Engine memory with N idle lanes ≈ today's idle footprint (lazy alloc verified).

## Dependencies & Prerequisites

- **Merge PR #11 first**, then branch fresh off `master` (keeps the
  dry-recording fix + DSP substrate; makes the replacements read as deliberate).
- Native toolchain for C tests (clang + CoreAudio/AudioToolbox frameworks, per
  the existing build line in `test_engine_core.c`).
- ffigen for binding regeneration (+ `dart format` for the known short-style
  drift).

## Risk Analysis & Mitigation

- **R1 — RT safety during the rewrite.** Larger struct + per-lane loops in
  `process()`. *Mitigation:* keep all allocation on the control thread (lazy lane
  alloc mirrors today's `pool[]`); audit `process()` for allocation; native tests
  assert behavior.
- **R2 — Latency/phase-lock regressions across lanes.** *Mitigation:* lanes share
  one transport/offset; add a native test asserting per-lane write heads match
  the single-buffer baseline sample-for-sample.
- **R3 — Session export/import format change** (mono-per-track → per-lane).
  *Mitigation:* PR 4 keeps session export **lane-0 only** with a documented
  limitation; full multi-lane stems are a follow-up task. No migration (pre-release
  drop-and-default).
- **R4 — UI scope creep.** The dual-route, multi-lane routing view is a real
  redesign. *Mitigation:* a short mock-first design pass before PR 5; reuse the
  existing card chain-editor; keep the monitor section separate from the track
  graph.
- **R5 — Capacity blow-up** if lazy alloc is missed. *Mitigation:* explicit caps
  (`LE_MAX_LANES=8`), lazy-alloc + RT null-guard native tests, documented budget.
- **R6 — Engine PR leaving the Dart build red.** The FFI surface breaks when
  `le_engine_set_track_fx`/the monitor-bus symbols change. *Mitigation:* **each
  engine PR (PR 1, PR 2) regenerates `loopy_engine_bindings.dart` and stubs the
  new `NativeAudioEngine` setters as `throw UnimplementedError()`**, with the
  fakes kept compiling, so `flutter test` is green at every step; PR 3 fills in
  the real bodies and removes the stubs.

## Resource Requirements

Solo, multi-session. Order: PR 1 (largest — engine transport core), PR 2 (FX
relocation + monitor), PR 3 (Dart engine), PR 4 (domain), PR 5 (UI) — each its
own independently-green PR, in dependency order.

## Future Considerations

- VST3 host (task #38) slots in as another effect "type" usable by lane and
  monitor chains alike — unchanged by this rework.
- Per-lane undo could later become independent if a real need appears.
- A track-summed master effect chain could be added atop lane chains later.

## Documentation Plan

- Update `docs/PROGRESS.md` with the new routing/monitoring model.
- Refresh effect/stage docs (the `stage` concept is gone) in `track_effect.dart`
  and the engine header comments.
- Add a short "audio routing model" note describing lanes vs. monitor routes.

## References & Research

### Internal References

- Track struct + transport: `packages/loopy_engine/src/engine.c:80` (`le_track`),
  `:108` (`record_pos`), `:128` (`le_fx_state fx/mon_fx`).
- Process loop (record/playback/monitor): `packages/loopy_engine/src/engine.c`
  (`le_engine_process`, monitor block ~`:1132`).
- Effect DSP + chain: `engine.c` (`fx_apply_chain`, `fx_delay`, `fx_filter`,
  `fx_tremolo`); model `packages/loopy_engine/lib/src/track_effect.dart`.
- Caps: `loopy_engine_api.h` — `LE_MAX_TRACKS=8`, `LE_FX_MAX=8`,
  `LE_FX_PARAMS=3`, `LE_VIZ_POINTS=512`; `engine.c` — `LE_UNDO_SLOTS=8`,
  command codes 0–25 (next free 26).
- Repository apply/remember: `packages/looper_repository/lib/src/looper_repository.dart`.
- Monitor cubit/UI to replace: `lib/audio_setup/cubit/monitor_cubit.dart`,
  `lib/audio_setup/view/monitor_fx_editor.dart`.
- Routing view to rework: `lib/looper/view/track_signal_flow_view.dart`,
  `track_routing_dialog.dart`.

### Related Work

- Previous PRs: #11 (dry-recording fix + per-track FX + global monitor bus — the
  substrate this reworks).
- Institutional memory: ffigen short-style drift (fix: `dart format` after
  regen); FFI plugin hand-authored; macOS mic entitlement + loopback feedback
  caveats.
