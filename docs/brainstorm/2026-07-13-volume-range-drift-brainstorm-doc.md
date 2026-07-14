---
date: 2026-07-13
topic: volume-range-drift
---

# Volume Range Drift — Lane/Track/Monitor Volume 0..1 vs 0..LE_MAX_GAIN

## What We're Building

A docs-and-test-fidelity fix, not a behavior change to the native engine. The
native engine (`packages/loopy_engine/src/core/engine_process.c`) has always
clamped track volume (`LE_CMD_SET_VOLUME`), lane volume
(`LE_CMD_SET_LANE_VOLUME`), and monitor-input volume
(`LE_CMD_SET_MONITOR_INPUT_VOLUME`) to `0..LE_MAX_GAIN` (2.0, +6.02 dB) — this
is intentional headroom, confirmed by the comment on `LE_MAX_GAIN` itself
("so the UI can boost a quiet take/input up to +6 dB"). Three places in the
Dart/C layer never caught up with that reality:

1. `MockAudioEngine.setLaneVolume` clamps to `0..1` (`volume.clamp(0, 1)`),
   so the test double silently diverges from `NativeAudioEngine`: setting
   1.5 reads back 1.0 from the mock but 1.5 from the real engine.
2. Dart-side doc comments (`audio_engine.dart`, `engine_snapshot.dart`) claim
   `0..1` for lane/track volume.
3. The C header itself (`loopy_engine_api.h`) is internally inconsistent —
   some comments correctly reference `LE_MAX_GAIN`, others near the
   lane-volume and monitor-volume setters/enum entries still say `0..1`.

The fix corrects the mock's clamp and every stale doc comment so all three
layers agree with what the engine actually does, and adds a regression test
that would have caught the mock/native divergence.

## Why This Approach

There is only one reasonable approach here: match the docs and the mock to
the native engine's real, intentional behavior (`0..LE_MAX_GAIN`). The
alternative — clamping the native engine down to `0..1` — would remove a
shipped, documented +6 dB boost feature and is explicitly out of scope (this
is a docs/mock-fidelity bug, not a request to change engine behavior).

Investigation narrowed the blast radius further than the issue's file list
suggested:

- **Master gain and limiter ceiling are genuinely `0..1`/`(0,1]`.**
  `LE_CMD_SET_MASTER_GAIN` in `engine_process.c` clamps to `0.0f..1.0f`, not
  `LE_MAX_GAIN`. Their doc comments (`MasterBusControl.setMasterGain`,
  `EngineSnapshot.masterGain`, `le_engine_set_master_gain`,
  `le_engine_set_limiter`) are correct as-is and must **not** be touched —
  changing them would introduce the exact kind of drift this fix is
  removing.
- **FX param clamps (`0..1`) are unrelated.** `le_engine_set_lane_fx_param`'s
  "clamped to 0..1" comment describes normalized effect parameters, not
  volume/gain — out of scope.
- **`MonitorControl.setMonitorInputVolume` in `MockAudioEngine` is a bare
  stub** (`=> _requireRunning();`) — it never stores or clamps a volume
  value at all today. There is no clamp bug to fix in the mock for monitor
  volume, only a stale doc comment. Adding full monitor-volume state
  tracking to the mock (so a parity test could exercise it) would be a
  larger behavioral addition beyond this issue's scope, so it is
  deliberately not done here.
- **`le_engine_set_track_volume`** has no adjacent doc comment quoting a
  range (it sits under a generic "looper control" block comment), so
  nothing needs correcting there beyond the enum comment for
  `LE_CMD_SET_VOLUME` (`arg_f = 0..1` at line 94 of the header).
- A Dart-side constant for the ceiling already exists and needs no new
  definition: `LE_MAX_GAIN` is emitted by ffigen into
  `packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart`
  (`const double LE_MAX_GAIN = 2.0;`), and `mock_audio_engine.dart` already
  imports that generated file and already references a sibling constant
  (`LE_MAX_TRACKS`) directly from it. Using `LE_MAX_GAIN` the same way is
  the smallest, most consistent fix — no new constant, no re-export needed.

## Key Decisions

- **Fix the mock's clamp, not the engine.** `MockAudioEngine.setLaneVolume`
  changes from `volume.clamp(0, 1)` to `volume.clamp(0, LE_MAX_GAIN)`,
  referencing the existing generated constant already imported in that file.
- **Leave `MonitorControl`/`MockAudioEngine.setMonitorInputVolume` mock
  behavior untouched.** It's a stateless stub with no clamp to fix; only its
  doc comment changes. Adding stateful monitor-volume tracking to the mock
  is a separate, larger change and is out of scope.
- **Leave master gain, limiter ceiling, and FX param doc comments alone.**
  These are genuinely `0..1`/`(0,1]`/normalized and are already accurate.
  Touching them would be scope creep and would risk introducing new drift.
- **Doc comments to correct** (say `0..LE_MAX_GAIN (2.0, +6dB)` or similar
  instead of `0..1`):
  - `packages/loopy_engine/lib/src/audio_engine.dart`:
    `EngineRouting.setLaneVolume` (~line 214),
    `MonitorControl.setMonitorInputVolume` (~line 332).
  - `packages/loopy_engine/lib/src/engine_snapshot.dart`:
    `LaneSnapshot.volume` (~line 114), `TrackSnapshot.volume` (~line 226).
  - `packages/loopy_engine/src/core/loopy_engine_api.h`:
    `LE_CMD_SET_VOLUME` enum comment (~line 94),
    `LE_CMD_SET_LANE_VOLUME` enum comment (~lines 124-126),
    `LE_CMD_SET_MONITOR_INPUT_VOLUME` enum comment (~lines 151-152),
    `le_lane_snapshot.volume` struct comment (~line 325),
    `le_track_snapshot.volume` struct comment (~line 341),
    `le_engine_set_lane_volume` function comment (~line 825),
    `le_engine_set_monitor_input_volume` function comment (~lines 948-949).
- **Add a regression test** in
  `packages/loopy_engine/test/mock_audio_engine_test.dart`, mirroring the
  existing "master gain defaults to unity, clamps, and surfaces in the
  snapshot" test's style/literal-value convention (that test uses literal
  numbers, not a named constant, so the new test follows suit): verify
  `setLaneVolume` accepts a boost above 1.0 (e.g. 1.5 reads back 1.5, not
  clamped to 1.0) and still clamps at the true ceiling (2.0) and floor (0),
  for both the track-level (channel/lane defaults) and explicit-lane
  addressing paths.
- **No behavior change to `NativeAudioEngine`, `engine_process.c`, or any
  application/UI/repository code.** This is strictly a mock-parity + doc
  fix confined to the four files named in the issue.

## Open Questions

None blocking — this is a narrowly-scoped, low-ambiguity fix. One judgment
call made autonomously (no interactive user in this run): the exact wording
of corrected doc comments (`0..LE_MAX_GAIN (2.0, +6dB)`) is left to the
planning/implementation phase to match each file's existing comment style,
as long as the numeric ceiling and its +6 dB rationale are stated.
