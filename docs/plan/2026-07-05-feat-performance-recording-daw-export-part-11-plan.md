---
title: "feat: performance recording — part 11: recorder UI + app state"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 11: recorder UI + app state — Standard

> **Split note:** part 11 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). The full
> user-facing flow from UI + keyboard. Pedal firmware parity is part 12 —
> everything here ships without the firmware coupling.

## Overview

New `lib/performance/` feature: a `PerformanceRecorderCubit` that **observes**
`PerformanceRepository` state (stream + snapshot-mirrored atomics), and the
UI surfaces — `PerfRecordButton` in `TracksToolbar`, a persistent
`ArmedIndicator` with elapsed time, and a `PerformanceCompletionSheet`
(platform-aware reveal + rename). This part also wires the `.als` generation
step (manifest → `DawProject` mapping → `daw_export`) into the post-render
pipeline, and the load-while-armed orchestration into `SessionCubit`.

## Context / findings

- **State (sealed, Equatable):** `idle → armed(elapsed, overrun) →
  finalizing → rendering(percent) → completed(result)` where result carries
  done(path) / partial / stopped-early(reason: diskFull | deviceChanged),
  plus `recoveryAvailable`. Short-capture auto-discard surfaces via a
  `BlocListener` on the transition (no ephemeral state). Arm is **disabled
  while rendering** (umbrella — no queue).
- **Layering (umbrella, explicit):** cubits never call cubits. The cubit
  observes the repository; intents go UI → cubit → repository.
  `SessionCubit` gains a `PerformanceRepository` dependency and awaits
  `disarmAndFinalize()` before applying a session load. (`ControlCubit`'s
  pedal intent + D-CLEAR orchestration land in part 12 with the pedal
  surface; the keyboard key here routes through `TracksCommands` → the same
  repository call.)
- **Providers:** `RepositoryProvider<PerformanceRepository>` + **eager**
  (`lazy: false`) `BlocProvider<PerformanceRecorderCubit>` in
  `lib/app/view/app.dart`, boot-time salvage via `unawaited(cubit.load())`
  (precedent: `AudioRecoveryCubit`).
- **Widgets are extracted classes** (user rule — never build-methods):
  `PerfRecordButton`, `ArmedIndicator`, `PerformanceCompletionSheet`, themed
  via existing `ThemeExtension` tokens. Button placement: `TracksToolbar`
  ([tracks_chrome.dart:19](../../lib/looper/view/tracks_chrome.dart)) between
  the mode/bank cluster and the global transport.
- **Guards:** disarm ignored within 1 s of arm; captures < 2 s with zero
  logged events auto-discarded with a notice (constants).
- **Free-space warning** at arm (non-blocking, D-FAIL).
- **l10n:** all strings in `app_en.arb` + `app_es.arb` **with `@`-metadata**:
  `perfArm`, `perfDisarm`, `perfArmedElapsed`, `perfFinalizing`,
  `perfRendering`, `perfDone`, `perfReveal` (platform-aware label),
  `perfPartial`, `perfStoppedDiskFull`, `perfStoppedDeviceChange`,
  `perfCaptureGlitch`, `perfDiscarded`, `perfLowDisk`, `perfRecoveryFound`
  (+ recover/discard pair), `perfArmDisabledRendering`.

## Acceptance Criteria

- [ ] Arm → perform → disarm from the toolbar produces a complete bundle
      (master, inputs, stems, loops, `project.als`, `fx-chains.txt`) with
      states progressing idle → armed → finalizing → rendering → completed.
- [ ] `ArmedIndicator` shows elapsed time and an overrun/glitch flag; the
      completion sheet reveals the bundle (platform-aware) and renames the
      slug (never-overwrite preserved).
- [ ] Arm attempted while rendering is refused with `perfArmDisabledRendering`.
- [ ] Render failure lands in `completed(partial)` with captures delivered.
- [ ] Boot with an unfinalized capture dir → `recoveryAvailable`; recover
      finalizes + renders; discard removes the dir (bloc + widget tests).
- [ ] Session load while armed auto-disarms + finalizes first (`SessionCubit`
      orchestration test).
- [ ] Double-press guard + auto-discard behaviors covered by `bloc_test`.
- [ ] Keyboard key toggles arm via `TracksCommands`.
- [ ] All strings in both ARBs with `@`-metadata; no hardcoded user-facing
      text.
- [ ] `flutter analyze` clean; format stable; `test/performance` +
      `test/session` + `test/looper` suites green; coverage ≥ 90 on new code.

## Tasks

- [ ] `lib/performance/cubit/performance_recorder_cubit.dart` (+ sealed
      state file) — observes repository, drives render + `.als` generation
      (manifest → `DawProject` mapping lives here, keeping `daw_export`
      pure).
- [ ] `lib/performance/view/{perf_record_button,armed_indicator,performance_completion_sheet}.dart`.
- [ ] `lib/app/view/app.dart` — providers (eager cubit + boot salvage).
- [ ] `lib/looper/view/tracks_chrome.dart` — toolbar placement;
      `lib/looper/view/tracks_commands.dart` — keyboard key + SnackBar-style
      outcome listener reuse.
- [ ] `lib/session/cubit/session_cubit.dart` — `PerformanceRepository` dep +
      load-while-armed orchestration.
- [ ] `lib/l10n/arb/app_en.arb` + `app_es.arb` — keys with `@`-metadata;
      regenerate l10n.
- [ ] Tests: `bloc_test` for every transition + orchestration ordering;
      widget tests for the three new widgets; salvage boot test.

## Files touched (primary)

`lib/performance/*` (new), `lib/app/view/app.dart`,
`lib/looper/view/{tracks_chrome.dart,tracks_commands.dart}`,
`lib/session/cubit/session_cubit.dart`, `lib/l10n/arb/*`,
`test/performance/*` (new), `test/session/*`, `test/looper/*`,
root `pubspec.yaml` (new package deps).

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
2. `flutter test test/performance test/session test/looper` — green.
3. Manual: full arm → disarm → open `project.als` in Live 12; crash-salvage
   flow (kill -9 while armed, relaunch, recover).

## Dependencies

- **Part 6** (repository), **Part 7** (render progress), **Part 10** (`.als`
  + fx-chains for the completed bundle; the UI can land against parts 6–7
  with `.als` generation feature-gated if 10 is still in flight).
