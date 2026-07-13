---
title: Volume range drift — mock clamp + doc comments vs LE_MAX_GAIN
type: fix
date: 2026-07-13
---

## Volume range drift — mock clamp + doc comments vs LE_MAX_GAIN

The native engine intentionally clamps track/lane/monitor-input volume to
`0..LE_MAX_GAIN` (2.0, +6.02 dB headroom) at three call sites in
`packages/loopy_engine/src/core/engine_process.c` (`LE_CMD_SET_VOLUME`,
`LE_CMD_SET_LANE_VOLUME`, `LE_CMD_SET_MONITOR_INPUT_VOLUME`). The Dart layer
never caught up: `MockAudioEngine.setLaneVolume` clamps to `0..1`, so the test
double behaviorally diverges from `NativeAudioEngine` (setting 1.5 reads back
1.0 from the mock, 1.5 from the real engine), and doc comments in
`audio_engine.dart`, `engine_snapshot.dart`, and `loopy_engine_api.h` still
claim `0..1` for these same values. See
`docs/brainstorm/2026-07-13-volume-range-drift-brainstorm-doc.md` for full
investigation notes.

## Success Criteria

```success-criteria
GOAL: MockAudioEngine's lane/track volume clamp matches NativeAudioEngine's
LE_MAX_GAIN ceiling, and every doc comment describing lane/track/monitor
volume range (Dart + C header) states the real 0..LE_MAX_GAIN (2.0, +6dB)
range instead of the stale 0..1.

SUCCESS CRITERIA:
- MockAudioEngine.setLaneVolume clamps to 0..LE_MAX_GAIN (2.0), not 0..1 | verify: manual confirm packages/loopy_engine/lib/src/mock_audio_engine.dart's setLaneVolume uses `volume.clamp(0, LE_MAX_GAIN)` (or equivalent referencing the generated LE_MAX_GAIN constant)
- New/updated test proves the mock accepts a >1.0 boost and still clamps at the true ceiling/floor | verify: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test/mock_audio_engine_test.dart
- No stale "0..1" doc comment remains for setLaneVolume/setMonitorInputVolume in the Dart layer | verify: ! grep -n "playback gain, clamped to \`0\.\.1\`" packages/loopy_engine/lib/src/audio_engine.dart && ! grep -n "output gain (\[volume\], clamped to \`0\.\.1\`)" packages/loopy_engine/lib/src/audio_engine.dart && ! grep -n "Playback gain in \`0\.\.1\`" packages/loopy_engine/lib/src/engine_snapshot.dart
- Master gain / limiter ceiling / overdub feedback / FX-param doc comments are untouched (still correctly 0..1 / (0,1]) | verify: manual diff review — grep the same files for "master_gain\|limiter\|overdub_feedback\|fx_param" comments and confirm wording is unchanged
- loopy_engine_api.h's lane-volume and monitor-input-volume comments (enum entries + function comments) state LE_MAX_GAIN, not 0..1 | verify: manual confirm packages/loopy_engine/src/core/loopy_engine_api.h lines for LE_CMD_SET_VOLUME, LE_CMD_SET_LANE_VOLUME, LE_CMD_SET_MONITOR_INPUT_VOLUME, le_lane_snapshot.volume, le_track_snapshot.volume, le_engine_set_lane_volume, le_engine_set_monitor_input_volume no longer say "0..1"
- Existing loopy_engine test suite still passes (no regression from the clamp change) | verify: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test
- Dependent packages (looper_repository) still pass with the wider mock clamp | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test
- Touched Dart files are correctly formatted | verify: /Users/Tomas/development/flutter/bin/dart format --set-exit-if-changed packages/loopy_engine/lib/src/audio_engine.dart packages/loopy_engine/lib/src/engine_snapshot.dart packages/loopy_engine/lib/src/mock_audio_engine.dart packages/loopy_engine/test/mock_audio_engine_test.dart
- Touched Dart files pass static analysis | verify: /Users/Tomas/development/flutter/bin/flutter analyze packages/loopy_engine

NON-GOALS:
- Changing native engine clamp behavior (engine_process.c) — LE_MAX_GAIN is
  the correct, intentional, shipped ceiling; this fix brings docs/mock in
  line with it, not the other way around.
- Changing MasterBusControl.setMasterGain / EngineSnapshot.masterGain /
  le_engine_set_master_gain / le_engine_set_limiter doc comments — these are
  genuinely 0..1 / (0,1] (confirmed: LE_CMD_SET_MASTER_GAIN clamps to
  0.0f..1.0f in engine_process.c, not LE_MAX_GAIN) and must stay as-is.
- Changing FX-param clamp comments (le_engine_set_lane_fx_param, "clamped to
  0..1") — these describe normalized effect parameters, unrelated to volume.
- Adding stateful monitor-volume tracking to MockAudioEngine.
  setMonitorInputVolume is currently a stateless stub
  (`=> _requireRunning();`) with no value to clamp; only its doc comment
  changes here. Making it stateful is a separate, larger change.
- Any change to native_audio_engine.dart, UI/repository/bloc code, or any
  file outside packages/loopy_engine/lib, packages/loopy_engine/src/core,
  and packages/loopy_engine/test.

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/loopy_engine/test && /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test && /Users/Tomas/development/flutter/bin/dart format --set-exit-if-changed packages/loopy_engine/lib/src/audio_engine.dart packages/loopy_engine/lib/src/engine_snapshot.dart packages/loopy_engine/lib/src/mock_audio_engine.dart packages/loopy_engine/test/mock_audio_engine_test.dart && /Users/Tomas/development/flutter/bin/flutter analyze packages/loopy_engine
```

## Context

Confirmed by direct file inspection during brainstorming (commit `f3f5b76`
area, current worktree HEAD):

- **Native clamp sites** (`packages/loopy_engine/src/core/engine_process.c`):
  - `LE_CMD_SET_VOLUME` (line 753-761, track volume → lane 0): clamps
    `v > LE_MAX_GAIN → LE_MAX_GAIN` (line 758).
  - `LE_CMD_SET_LANE_VOLUME` (line 884-894): clamps to `LE_MAX_GAIN`
    (line 891).
  - `LE_CMD_SET_MONITOR_INPUT_VOLUME` (line 955-964): clamps to
    `LE_MAX_GAIN` (line 961).
  - By contrast `LE_CMD_SET_MASTER_GAIN` (line 770-777) clamps to real
    `0.0f..1.0f` — **do not touch its docs**.
  - `LE_MAX_GAIN` is `#define`d as `2.0f` at
    `packages/loopy_engine/src/core/loopy_engine_api.h:311`, with the comment
    "Ceiling for a per-lane / per-monitor channel volume. 2.0 is +6.02 dB...".

- **Dart-side generated constant already exists** — no new constant needed:
  `packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart:3643`:
  `const double LE_MAX_GAIN = 2.0;`. `mock_audio_engine.dart` already imports
  this generated file (`import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';`)
  and already references a sibling constant directly
  (`LE_MAX_TRACKS`, used at line 70). Use `LE_MAX_GAIN` the same way.

- **Mock clamp bug**: `packages/loopy_engine/lib/src/mock_audio_engine.dart:370`
  (inside `setLaneVolume`): `_tracks[channel].laneAt(lane).volume = volume.clamp(0, 1);`

- **Stale Dart doc comments** (`0..1` → should describe `0..LE_MAX_GAIN`):
  - `packages/loopy_engine/lib/src/audio_engine.dart:214`
    (`EngineRouting.setLaneVolume`, "clamped to `0..1`").
  - `packages/loopy_engine/lib/src/audio_engine.dart:332`
    (`MonitorControl.setMonitorInputVolume`, "clamped to `0..1`").
  - `packages/loopy_engine/lib/src/engine_snapshot.dart:114`
    (`LaneSnapshot.volume`, "Playback gain in `0..1`").
  - `packages/loopy_engine/lib/src/engine_snapshot.dart:226`
    (`TrackSnapshot.volume`, "Playback gain in `0..1`").
  - Leave `engine_snapshot.dart:484` (`EngineSnapshot.masterGain`, "Global
    master output gain in `0..1`") **unchanged** — genuinely correct.

- **Stale C header doc comments** (`packages/loopy_engine/src/core/loopy_engine_api.h`):
  - Line 94: `LE_CMD_SET_VOLUME = 7,/* arg_f = 0..1 */`.
  - Lines 124-126: `LE_CMD_SET_LANE_VOLUME = 28, /* lane playback gain. ... arg_f = 0..1. */`.
  - Lines 151-152: `LE_CMD_SET_MONITOR_INPUT_VOLUME = 34, /* input monitor gain. arg_i = input, arg_f = 0..1. */`.
  - Line 325: `float volume; /* 0..1 */` (inside `le_lane_snapshot`).
  - Line 341: `float volume; /* lane 0 volume, 0..1 */` (inside `le_track_snapshot`).
  - Line 825: `/* Sets lane [lane] of track [channel]'s playback gain, clamped to 0..1. */` above `le_engine_set_lane_volume`.
  - Lines 948-949: `/* Sets hardware input [input]'s monitor output gain to [volume] (clamped to 0..1). The default is 1.0 (unity). */` above `le_engine_set_monitor_input_volume`.
  - Leave line 155 (`LE_CMD_SET_MASTER_GAIN`), lines 875-878
    (`le_engine_set_master_gain`), lines 881-885 (`le_engine_set_limiter`),
    lines 889-894 (`le_engine_set_overdub_feedback`), and lines 918-920 /
    971-973 (FX-param clamps) **unchanged**.

- **Test convention to follow**: `packages/loopy_engine/test/mock_audio_engine_test.dart:68-83`
  has an existing `'master gain defaults to unity, clamps, and surfaces in
  the snapshot'` test using literal numeric values (not a named constant) to
  assert `setMasterGain` clamps to `0..1`. Mirror this style for the new lane
  volume test, using the literal `2.0` ceiling (consistent with how that test
  already hardcodes `-1`/`0`/`1`/`2` rather than importing constants).

- **`test/helpers/fake_audio_engine.dart` and
  `packages/looper_repository/test/helpers/fake_audio_engine.dart`**: these
  are hand-rolled test doubles (not `MockAudioEngine`) that just record calls
  (`calls.add('setLaneVolume')`) without clamping — no change needed there;
  they don't assert a range.

## Tasks

- [ ] `packages/loopy_engine/lib/src/mock_audio_engine.dart:370` — change
      `volume.clamp(0, 1)` to `volume.clamp(0, LE_MAX_GAIN)` in
      `setLaneVolume`.
- [ ] `packages/loopy_engine/lib/src/audio_engine.dart` — fix the two stale
      `0..1` doc comments (`EngineRouting.setLaneVolume`,
      `MonitorControl.setMonitorInputVolume`) to state
      `0..LE_MAX_GAIN (2.0, +6dB)` or equivalent wording consistent with the
      surrounding comment style.
- [ ] `packages/loopy_engine/lib/src/engine_snapshot.dart` — fix the two
      stale `0..1` doc comments (`LaneSnapshot.volume`, `TrackSnapshot.volume`).
      Leave `EngineSnapshot.masterGain`'s comment untouched.
- [ ] `packages/loopy_engine/src/core/loopy_engine_api.h` — fix the seven
      stale `0..1` references listed above (enum comments for
      `LE_CMD_SET_VOLUME`/`LE_CMD_SET_LANE_VOLUME`/`LE_CMD_SET_MONITOR_INPUT_VOLUME`,
      struct comments for `le_lane_snapshot.volume`/`le_track_snapshot.volume`,
      function comments for `le_engine_set_lane_volume`/
      `le_engine_set_monitor_input_volume`). Leave master-gain/limiter/
      overdub-feedback/FX-param comments untouched.
- [ ] `packages/loopy_engine/test/mock_audio_engine_test.dart` — add a test
      (mirroring the existing master-gain clamp test) asserting
      `setLaneVolume`: (a) a value like `1.5` is *not* clamped down to `1.0`
      (reads back `1.5`), for both the default track-level addressing
      (`channel: 0, lane: 0`) and an explicit non-zero channel/lane; (b) a
      value above `2.0` (e.g. `2.5`) clamps to `2.0`; (c) a negative value
      clamps to `0`.
- [ ] Run the verification command block above; fix any regressions.

## Out of scope

- Native engine behavior (`engine_process.c`) — unchanged, already correct.
- `MasterBusControl`/master-gain/limiter/overdub-feedback doc comments —
  already correct, must not be touched.
- FX parameter clamp doc comments — unrelated normalized-parameter range.
- Adding real state tracking to `MockAudioEngine.setMonitorInputVolume` (it
  stays a stub; only its doc comment changes).
- Any UI, repository, or bloc code that calls `setLaneVolume`/
  `setMonitorInputVolume` — no behavior for callers changes since the native
  engine's real range was always `0..LE_MAX_GAIN`; this fix only aligns the
  mock and the docs with that existing reality.

## References

- Brainstorm: `docs/brainstorm/2026-07-13-volume-range-drift-brainstorm-doc.md`
- Issue file list: `packages/loopy_engine/lib/src/mock_audio_engine.dart`,
  `packages/loopy_engine/lib/src/audio_engine.dart`,
  `packages/loopy_engine/lib/src/engine_snapshot.dart`,
  `packages/loopy_engine/src/core/loopy_engine_api.h`
