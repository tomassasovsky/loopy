---
title: "feat: performance recording — part 4: laned export ABI"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 4: laned export ABI — Minimal

> **Split note:** part 4 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). Small,
> self-contained, **no dependencies** — a good first-contributor part. It
> must land before part 6 (the arm/disarm snapshots read lane PCM through
> it) and unblocks all-lane loop-cycle stems (D-STEMS).

## Overview

Today `le_engine_export_track`
([engine_session.c:22–35](../../packages/segno_engine/src/core/engine_session.c))
hardcodes `lanes[0]`. Add `le_engine_export_track_lane(engine, channel, lane,
out, max_frames)` with the same settled-buffer memcpy semantics, extend the
Dart `SessionIo` capability interface with `exportTrackLane`, and leave the
existing lane-0 method and every current call site untouched.

## Acceptance Criteria

- [ ] `le_engine_export_track_lane` returns lane `l`'s dry settled buffer for
      any valid `(channel, lane)`; invalid lane → `LE_ERR_INVALID`; empty
      lane → 0 frames.
- [ ] Existing `le_engine_export_track` behavior byte-identical (regression
      test); existing dry-export test still passes.
- [ ] `SessionIo` gains `exportTrackLane(int channel, int lane)`;
      `NativeAudioEngine` binds it; `MockAudioEngine` fake added same-PR.
- [ ] ffigen regenerated + `dart format` stable; `flutter analyze` clean;
      `session_repository` suite still green (no call-site changes needed).

## Tasks

- [ ] `packages/segno_engine/src/core/engine_session.c` +
      `segno_engine_api.h` — new export function.
- [ ] `packages/segno_engine/lib/src/audio_engine.dart` (`SessionIo`),
      `native_audio_engine.dart`, `mock_audio_engine.dart`.
- [ ] Regenerate ffigen bindings + `dart format`.
- [ ] Native test (multi-lane export, invalid lane) in `test_engine_core.c`;
      Dart test for the mock + binding.

## Files touched (primary)

`packages/segno_engine/src/core/{engine_session.c,segno_engine_api.h}`,
`packages/segno_engine/lib/src/{audio_engine.dart,native_audio_engine.dart,mock_audio_engine.dart}`,
`packages/segno_engine/lib/src/generated/*`,
`packages/segno_engine/src/test/test_engine_core.c`.

## Verification

1. `bash packages/segno_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
3. `flutter test packages/segno_engine packages/session_repository`.

## Dependencies

- None. Fully parallel; required by part 6.
