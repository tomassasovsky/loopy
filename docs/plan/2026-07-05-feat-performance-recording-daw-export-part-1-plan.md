---
title: "feat: performance recording — part 1: capture rings + audio-thread taps"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 1: capture rings + audio-thread taps — Standard

> **Split note:** part 1 of 12 of the performance-recording & DAW-export plan
> (umbrella: `2026-07-05-feat-performance-recording-daw-export-plan.md` — see
> it for all D-* decisions). This part is the **RT-critical engine surface
> only**: a new float audio ring type, the master/monitor capture taps, the
> arm/disarm command path, and the Dart capability interface. No file I/O and
> no drain thread (part 2). Reviewable with an RT-safety focus.

## Overview

While armed, the audio thread must emit two kinds of streams into pre-published
lock-free rings: the post-limiter master output (after `master_bus_frame`,
[engine_process.c:974–1017](../../packages/loopy_engine/src/core/engine_process.c))
and each monitor input active at arm (post-monitor-FX, pre-route, inside
`mix_monitors_frame`, :1289–1310). Rings are **allocated control-side at arm**
(≥2 s of audio at device rate each) and published to the audio thread with the
arm command — the same control-allocates/publish pattern as `le_post_dub_shadows`
and the FX delay lines. On overflow the audio thread drops and increments an
atomic overrun counter; it never blocks or allocates (umbrella D-FAIL, D-ARM,
D-MASTER, D-INPUT).

## Context / findings

- The existing `le_ring` is a 256-slot fixed-POD command ring
  ([lockfree_ring.h:30–69](../../packages/loopy_engine/src/core/lockfree_ring.h))
  — wrong shape for audio; this part adds a float SPSC ring type
  (`le_audio_ring`).
- Armed state, captured-frame count, and overrun count are published as
  snapshot atomics read on the existing snapshot poll — **no** separate
  `le_perf_status` ABI (single status surface).
- Master capture is stereo from the first enabled output pair at arm (mono
  device → mono). Monitor capture set is **frozen at arm** (inputs enabled
  later are logged, not tapped).
- Dart engine boundary: new `EnginePerformanceCapture` capability interface
  composed into `AudioEngine`
  ([audio_engine.dart](../../packages/loopy_engine/lib/src/audio_engine.dart),
  precedent `EnginePluginHosting`), implemented by `NativeAudioEngine` and
  `MockAudioEngine`.

## Acceptance Criteria

- [ ] `le_audio_ring`: float SPSC ring; push/pop with acquire/release
      semantics; capacity ≥ 2 s at device rate; drop-on-full returns a count.
- [ ] `LE_CMD_PERF_ARM` publishes the ring set + capture config to the audio
      thread; `LE_CMD_PERF_DISARM` unpublishes; rings freed control-side only
      after a quiescent handshake (audio thread stopped writing).
- [ ] While armed, the master ring contents are **bit-identical** to the
      processed output (post-master-gain, post-limiter) for the same input;
      each monitor ring matches the monitor mix contribution (native test).
- [ ] Overflow increments the atomic overrun counter and drops; the audio
      callback path has **no** malloc/lock/syscall while armed (native
      assertion/test).
- [ ] Snapshot exposes `perf_armed`, `perf_frames`, `perf_overruns` atomics.
- [ ] `EnginePerformanceCapture` (`perfArm/perfDisarm` + status via
      `EngineSnapshot`) on `AudioEngine`; `NativeAudioEngine` binds the ABI;
      `MockAudioEngine` has deterministic fakes.
- [ ] ffigen regenerated + `dart format` stable; `flutter analyze` clean;
      native suite "ALL PASSED".

## Tasks

- [ ] `packages/loopy_engine/src/core/audio_ring.{h,c}` — `le_audio_ring`
      (float SPSC, power-of-two capacity, cached head/tail).
- [ ] `packages/loopy_engine/src/core/loopy_engine_api.h` — `le_perf_arm`
      / `le_perf_disarm` ABI (+ capture-config struct: out pair, input mask),
      `LE_CMD_PERF_ARM/DISARM` codes.
- [ ] `packages/loopy_engine/src/core/engine_process.c` — arm/disarm command
      handling (publish/unpublish ring pointers); master tap after
      `master_bus_frame`; per-monitor tap in `mix_monitors_frame`; frame +
      overrun atomics.
- [ ] `packages/loopy_engine/src/core/engine_commands.c` — control-side
      alloc/publish/free + quiescent handshake.
- [ ] `packages/loopy_engine/src/core/engine_snapshot.c` — perf atomics into
      the snapshot struct.
- [ ] Dart: `EnginePerformanceCapture` interface in
      `packages/loopy_engine/lib/src/audio_engine.dart`; `NativeAudioEngine` +
      `MockAudioEngine` implementations; snapshot model fields; regenerate
      ffigen bindings + `dart format`.
- [ ] Native tests in `packages/loopy_engine/src/test/test_engine_core.c`:
      tap bit-parity, overflow counting, arm/disarm handshake, RT-safety
      assertions.
- [ ] Dart tests: mock fakes + snapshot field mapping.

## Files touched (primary)

`packages/loopy_engine/src/core/{audio_ring.h,audio_ring.c,loopy_engine_api.h,engine_process.c,engine_commands.c,engine_snapshot.c,engine_private.h}`,
`packages/loopy_engine/lib/src/{audio_engine.dart,native_audio_engine.dart,mock_audio_engine.dart,engine_snapshot.dart}`,
`packages/loopy_engine/lib/src/generated/*` (regenerated),
`packages/loopy_engine/src/test/test_engine_core.c`.
Keep `run_native_tests.sh`'s source globs valid (new `audio_ring.c` matches
`src/core/engine*.c`? No — add it to the glob list or name it accordingly).

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
3. `flutter test packages/loopy_engine`.

## Dependencies

- None. First part of the stack.
