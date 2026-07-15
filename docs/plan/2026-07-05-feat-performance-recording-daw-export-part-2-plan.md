---
title: "feat: performance recording — part 2: perf drain thread + raw PCM + sidecar"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 2: perf drain thread + raw PCM + sidecar — Standard

> **Split note:** part 2 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). This part is
> the **capture-to-disk subsystem**: a dedicated native drain thread that
> turns part 1's rings into crash-salvageable files. Concurrency/IO-focused
> review; no audio-thread changes beyond what part 1 landed.

## Overview

A dedicated native **perf drain thread** (lifecycle sibling of the plugin
scan thread in `plugin_scan.cpp`: spawned at arm, joined at disarm) drains
the capture rings to **raw PCM temp files** in the capture directory and
maintains the `performance.json` sidecar, flushing every ~250 ms. WAV headers
are written only at finalize (part 6) — a crash leaves raw PCM + sidecar, not
a truncated WAV (umbrella D-FMT, D-FAIL, D-SALVAGE).

## Context / findings

- Capture dir layout (temp, pre-finalize): `master.pcm`, `input-<n>.pcm`,
  `performance.json` (sidecar skeleton: slug, sample rate, channel layout,
  capture frames, overrun gaps, `finalized: false`).
- **Overrun handling:** when the drain thread observes a gap (overrun counter
  advanced), it writes silence for the missing span so files stay
  sample-consistent, and records the gap position in the sidecar (surfaced to
  the user in part 11).
- **Disk full:** a failed write stops capture cleanly — stop draining, mark
  the sidecar `stopped_early: disk_full`, request disarm; the looper itself
  keeps running (capture failure never touches the audio path).
- **Device/sample-rate change while armed:** engine reconfigure triggers an
  auto-stop hook — capture finalizes at the old rate, sidecar marked
  `stopped_early: device_changed`.
- The event-log file write (part 3) and retired-layer persistence (part 5)
  will ride this same thread; design its loop as "drain all sources, flush,
  sleep" from the start.

## Acceptance Criteria

- [ ] Arming produces a capture dir with growing `master.pcm` /
      `input-<n>.pcm` and a sidecar updated ≤ every 250 ms.
- [ ] Drained PCM is byte-identical to what was pushed into the rings
      (native test with a scripted producer).
- [ ] A simulated overrun yields silence-filled files of the correct length
      and a gap entry in the sidecar.
- [ ] A simulated write failure stops capture cleanly with
      `stopped_early: disk_full`; the engine keeps processing audio.
- [ ] Killing the process mid-capture leaves a parseable sidecar
      (`finalized: false`) + raw PCM readable up to the last flush (native
      crash-consistency test using abrupt thread kill / no-finalize path).
- [ ] Engine reconfigure while armed auto-stops capture and finalizes sidecar
      state at the old rate.
- [ ] No new Dart surface beyond wiring the capture-dir path into
      `le_perf_arm`; ffigen + `dart format` stable if the ABI grows.

## Tasks

- [ ] `packages/loopy_engine/src/core/perf_drain.{h,c}` — thread lifecycle
      (spawn at arm / join at disarm), drain loop, raw PCM writers, sidecar
      writer (JSON, atomic rename on each flush), silence-fill, disk-full
      stop.
- [ ] `le_perf_arm` gains the capture-directory path parameter (UTF-8 char
      buffer, existing ABI style).
- [ ] Reconfigure auto-stop hook in `engine.c` (configure path checks armed
      state).
- [ ] Native tests: drain correctness, overrun silence-fill, disk-full stop,
      crash consistency, reconfigure auto-stop.

## Files touched (primary)

`packages/loopy_engine/src/core/{perf_drain.h,perf_drain.c,loopy_engine_api.h,engine_commands.c,engine.c}`,
`packages/loopy_engine/lib/src/native_audio_engine.dart` (+ mock),
`packages/loopy_engine/lib/src/generated/*` (regenerated),
`packages/loopy_engine/src/test/test_engine_core.c`,
`packages/loopy_engine/src/test/run_native_tests.sh` (source list).

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
3. `flutter test packages/loopy_engine`.

## Dependencies

- **Part 1** (capture rings + arm/disarm ABI).
