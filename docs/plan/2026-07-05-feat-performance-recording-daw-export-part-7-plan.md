---
title: "feat: performance recording — part 7: offline renderer core (dry replay)"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 7: offline renderer core (dry replay) — Standard

> **Split note:** part 7 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). The replay
> engine, **dry stems only** — proving the timeline reconstruction is right
> before DSP parity enters (part 8 adds the wet pass + golden gate).

## Overview

New native entry points `le_perf_render_begin/poll/cancel`: a worker thread
(scan-thread lifecycle precedent) replays the event log against the capture
directory's snapshots + persisted layers, reusing the engine's track-mix math,
and writes **full-length dry per-track stems** with poll-based progress. The
renderer reads **only from the capture directory** — snapshots, layers, and
log are all files — so it has no live-engine dependency: the user can keep
looping during a render, and salvage renders are free (umbrella D-RENDER).

## Context / findings

- **Overdub-pass stitching is explicit renderer logic:** during a logged
  overdub pass, audibility switches from the pre-pass layer image to the
  post-pass retired layer along the pass's write trajectory (write-head
  position derived from the logged record offset + punch frames). Positions
  ahead of the latency-compensated write head play the pre-pass image;
  positions behind it play post-write content.
- **Deferred arm-time lanes** (mid-overdub at arm) reconstruct from their
  first retired layer + the log's pre-t=0 pass note.
- **Track recorded fresh while armed:** PCM comes from the disarm-time
  snapshot (part 6); its stem starts at the logged "record ended" frame.
- **Renders are serialized:** arm is disabled while rendering (umbrella —
  no queue); `le_perf_render_begin` returns busy if a render is active.
- **Partial success:** per-stem failure is recorded and skipped; the poll
  result carries per-track status so Dart can report partial delivery.
- Dart: `EnginePerformanceCapture` gains `renderBegin/renderPoll/
  renderCancel`; `performance_repository` drives the render after finalize
  and moves stems into `stems/dry/`.

## Acceptance Criteria

- [ ] A scripted log (record → play → mute → volume ride → stop) renders dry
      stems whose event boundaries land at the exact logged frames (native
      test, sample-accurate assertions).
- [ ] Overdub-pass stitching: a scripted pass with a known write trajectory
      renders the pre-pass image ahead of the write head and post-pass
      content behind it (native test).
- [ ] A track recorded fresh while armed renders a stem from the disarm
      snapshot (native test).
- [ ] Progress poll is monotonic 0–100; cancel stops within one work chunk
      and leaves no partial files in the bundle.
- [ ] Render runs while the live engine processes audio, with no interaction
      (native test: render mid-playback, live output unaffected).
- [ ] Per-stem failure yields partial success, not an aborted render.
- [ ] ffigen + `dart format` stable; `MockAudioEngine` render fakes; repo
      tests for `stems/dry/` assembly + partial status.
- [ ] Native suite "ALL PASSED"; `flutter analyze` clean; coverage held ≥ 90
      on `performance_repository`.

## Tasks

- [ ] `packages/loopy_engine/src/core/perf_render.{h,c}` — capture-dir
      loaders (sidecar, log, layers, lane PCM), replay state machine,
      stitching, per-track dry mixdown (track-mix math reuse), worker thread
      + progress/cancel atomics.
- [ ] `loopy_engine_api.h` — `le_perf_render_begin/poll/cancel` (+ per-track
      status struct).
- [ ] Dart: capability methods + mock fakes; `performance_repository` render
      orchestration → `stems/dry/`, partial-success mapping.
- [ ] Regenerate ffigen + `dart format`.
- [ ] Native tests: timeline accuracy, stitching, fresh-record stem,
      progress/cancel, live-engine independence, partial success.

## Files touched (primary)

`packages/loopy_engine/src/core/{perf_render.h,perf_render.c,loopy_engine_api.h}`,
`packages/loopy_engine/lib/src/{audio_engine.dart,native_audio_engine.dart,mock_audio_engine.dart}`,
`packages/loopy_engine/lib/src/generated/*`,
`packages/performance_repository/lib/src/*`,
`packages/loopy_engine/src/test/test_engine_core.c`,
`packages/loopy_engine/src/test/run_native_tests.sh` (source list).

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
3. `flutter test packages/loopy_engine packages/performance_repository`.

## Dependencies

- **Part 6** (capture-dir contents: manifest, snapshots, layers, log).
