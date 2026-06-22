---
title: "refactor: make data packages transitive (V2)"
type: refactor
date: 2026-06-19
---

## PR 3 (V2) — Make `loopy_engine` + `midi_client` transitive

> Part 4 of 4. Parent plan:
> [2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md](2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md).
> Source finding: [docs/code-review/architecture-review.md](../code-review/architecture-review.md) (V2).

## Overview

With the data-layer leaks cleared (Parts 1–3), this PR removes the root app's direct
dependencies on `loopy_engine` and `midi_client`. The remaining blocker is engine
**construction + start branching** in the composition root, which moves behind a repository
factory and a dedicated mock-flavor entrypoint. Behavior-preserving. Smallest PR in the chain.

## Problem Statement

`pubspec.yaml:25-28` declares direct `path` deps on data packages `loopy_engine` +
`midi_client`. VGV forbids this — data packages must be transitive via repositories. The hold
-out is `lib/app/run_loopy.dart:15`, which imports `loopy_engine` to construct
`NativeAudioEngine()` (`:41`), branch on `engine is MockAudioEngine` and read
`engine.defaultConfig` (`:69`), and name `AudioEngine`/`AudioDevice` (`:24`/`:68`).

## Technical Approach

- **Native path:** add `LooperRepository.native()` that constructs `NativeAudioEngine`
  internally, so shared `run_loopy.dart` never names the engine type.
- **Mock flavor (decided):** move the mock-engine composition into a new
  **`lib/main_mock.dart`** flavor entrypoint that *is* allowed to import `loopy_engine`
  (matching VGV's `main_<flavor>.dart` convention). It builds the mock engine + default config
  and calls the shared `runLoopy`. The shared `runLoopy` loses its
  `createEngine` / `is MockAudioEngine` / `defaultConfig` branch (the current `createEngine`
  injection is unused by production flavors and tests — a clean removal).
- After Part 3, `AudioDevice` in `run_loopy.dart` is the domain type; no `lib/` file imports
  `midi_client`.

## Tasks

- [ ] Add `LooperRepository.native()` factory in `packages/looper_repository/lib/src/looper_repository.dart`
      (constructs `NativeAudioEngine` internally). Decide how the mock flavor obtains its
      engine/default-config seam without the shared app importing `loopy_engine`.
- [ ] Create `lib/main_mock.dart` flavor entrypoint that constructs the mock engine + default
      config and calls `runLoopy`; it may import `loopy_engine`.
- [ ] Simplify `lib/app/run_loopy.dart`: drop the `createEngine` param + `is MockAudioEngine` /
      `defaultConfig` branch; use `LooperRepository.native()`; use the domain `AudioDevice`;
      remove the `package:loopy_engine` import.
- [ ] Remove `loopy_engine` and `midi_client` from the root `pubspec.yaml` dependencies; run
      `flutter pub get`; confirm they resolve transitively via the repositories.
- [ ] Update any mock-flavor wiring / launch configs / docs that referenced the old
      `createEngine` injection point.
- [ ] **Tests:** confirm the mock-flavor entrypoint still launches; full suite green.

## Acceptance Criteria

- [ ] `grep -r "package:loopy_engine\|package:midi_client" lib/` returns zero matches **except**
      `lib/main_mock.dart`.
- [ ] `pubspec.yaml` no longer lists `loopy_engine` or `midi_client` as direct dependencies.
- [ ] All flavors (native + mock) build, launch, and auto-start the engine exactly as before.
- [ ] `flutter analyze` clean; full suite green.

## Dependencies

- **Requires Parts 1, 2a, and 2b all merged.** The `pubspec` removals are only safe once every
  `lib/` import of `midi_client` (Parts 1 + 2b) and `loopy_engine` (Parts 2a + 2b) is gone.

## References

- Composition root: [lib/app/run_loopy.dart:15,24,41,68,69](../../lib/app/run_loopy.dart)
- Root manifest: [pubspec.yaml:25-28](../../pubspec.yaml)
- Repository: [packages/looper_repository/lib/src/looper_repository.dart](../../packages/looper_repository/lib/src/looper_repository.dart)
