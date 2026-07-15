---
title: "feat: performance recording — part 6: wav_codec extraction + performance_repository"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 6: wav_codec extraction + performance_repository — Standard

> **Split note:** part 6 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). The Dart data
> layer: a new `performance_repository` package that owns the capture
> lifecycle end-to-end, plus the mechanical `WavCodec` extraction it needs
> (D-WAV — repositories never import each other, and `WavCodec` currently
> lives in `session_repository`). This part also **pins the
> `performance.json` manifest schema**, unblocking the parallel `daw_export`
> track (part 9).

## Overview

`performance_repository` composes the `AudioEngine` boundary (never
`NativeAudioEngine`): `arm()` (free-space check, capture dir, arm-time
snapshot, engine arm), `disarm()` (engine disarm, disarm-time snapshot,
finalize raw PCM → WAV via `wav_codec`, bundle assembly), `persistLiveLanes()`
(D-CLEAR support for `ControlCubit`), `disarmAndFinalize()` (load-while-armed
support for `SessionCubit`), salvage detection, and a state stream the part
11 cubit observes.

## Context / findings

- **Snapshots (umbrella D-SNAP):** at arm — clock position, master loop
  length, per-track state/volume/mute/multiple, all **settled** lane dry
  buffers via `exportTrackLane` (part 4) + FX chains with current params,
  monitor config, master gain + limiter, latency offset; mid-overdub lanes
  marked deferred (retire path covers them, part 5). At **disarm** — a second
  settled-lane pass (covers tracks recorded fresh while armed; retires are
  overdub-only, nothing else persists their PCM).
- **`persistLiveLanes()` skips capturing tracks** — a mid-dub buffer is being
  written by the audio thread and would tear; the retire path covers those
  (umbrella D-CLEAR).
- **Bundle assembly:** temp capture dir → `{documents}/exports/<slug>/` with
  `master.wav`, `live-input-<n>.wav`, `loops/track<t>-lane<l>.wav` (all
  lanes, via part 4), `performance.json` (`finalized: true`). `stems/` and
  `project.als` arrive in parts 7–10. Slug: `perf-YYYYMMDD-HHMMSS`
  (D-NAME, never overwrite).
- **Salvage:** `findUnfinalized()` scans for capture dirs whose sidecar lacks
  `finalized` (D-SALVAGE); recovery = finalize path re-run.
- **`wav_codec` extraction:** move
  [wav.dart](../../packages/session_repository/lib/src/wav.dart) to a new
  tiny pure-Dart `packages/wav_codec/` package; `session_repository` depends
  on it and re-exports nothing; existing session tests are the regression
  net.
- Manifest schema (`performance.json`) documented in
  `docs/design/performance-manifest-format.md` for `daw_export` fixtures.

## Acceptance Criteria

- [ ] `wav_codec` package extracted; `session_repository` green with the new
      dependency; no repository→repository import anywhere.
- [ ] `arm()` produces a complete arm snapshot (every settled lane's PCM +
      FX + track/monitor/master state) and marks mid-overdub lanes deferred;
      does **not** block on `_awaitLayersSettled`-style waits.
- [ ] `disarm()` runs the disarm-time lane pass, converts raw PCM → WAV
      (master stereo/mono per D-MASTER; inputs per D-INPUT), assembles the
      bundle with all-lane `loops/`, writes `finalized: true`.
- [ ] A track recorded fresh while armed has its PCM in the disarm snapshot
      (test).
- [ ] `persistLiveLanes()` persists playing/stopped lanes and skips capturing
      tracks (test).
- [ ] Slug collision-free; existing bundles never overwritten (test).
- [ ] `findUnfinalized()` detects a simulated crash dir; recovery finalizes
      it (test).
- [ ] Render failure posture: bundle with master + inputs still delivered
      when stem rendering (parts 7+) fails — the repository API models
      partial success now.
- [ ] Coverage ≥ 90 for `wav_codec` and `performance_repository`;
      `flutter analyze` clean; format stable.
- [ ] Manifest schema doc committed.

## Tasks

- [ ] `packages/wav_codec/` — package scaffold, move `wav.dart` + tests;
      update `session_repository` imports + pubspec.
- [ ] `packages/performance_repository/` — package scaffold (depends on
      `loopy_engine`, `wav_codec`); models (`PerformanceSnapshot`,
      `PerformanceManifest`, `PerformanceState` stream); `arm/disarm/
      persistLiveLanes/disarmAndFinalize/findUnfinalized`; bundle assembly;
      slug helper.
- [ ] `docs/design/performance-manifest-format.md` — schema for `daw_export`.
- [ ] Tests: snapshot completeness (settled/deferred/disarm pass), skip-
      capturing rule, finalize round-trip on temp dirs, slug, salvage,
      partial success. `MockAudioEngine` perf fakes exercised.

## Files touched (primary)

`packages/wav_codec/*` (new), `packages/performance_repository/*` (new),
`packages/session_repository/{pubspec.yaml,lib/src/session_repository.dart,lib/src/wav.dart (removed)}`,
`docs/design/performance-manifest-format.md`.

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
2. `flutter test packages/wav_codec packages/performance_repository packages/session_repository` — green, coverage ≥ 90 on the new packages.

## Dependencies

- **Part 3** (log format in the capture dir), **Part 4** (laned export for
  snapshots + loops), **Part 5** (layer files in the manifest).
