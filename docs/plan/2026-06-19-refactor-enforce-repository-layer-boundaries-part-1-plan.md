---
title: "refactor: introduce midi_device_repository (V1)"
type: refactor
date: 2026-06-19
---

## PR 1 (V1) — Introduce `midi_device_repository`

> Part 1 of 4. Parent plan:
> [2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md](2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md).
> Source finding: [docs/code-review/architecture-review.md](../code-review/architecture-review.md) (V1).

## Overview

`MidiSetupCubit` (business logic) drives the data-layer `MidiControllerSource` directly,
bypassing the repository layer. This PR introduces a new repository package
`midi_device_repository` that owns the MIDI **input** (controller) device lifecycle, and
rewrites `MidiSetupCubit` as a thin projector over it — mirroring the existing
`AudioSetupCubit` → `LooperRepository` → `loopy_engine` pattern. Behavior-preserving.

**Scope note:** this covers only the MIDI **input** path. The pedal's **output**-device
`MidiDevice` leak is a separate path (via `pedal_repository`) handled in Part 3.

## Problem Statement

`lib/audio_setup/cubit/midi_setup_cubit.dart` imports `package:midi_client/midi_client.dart`
and operates `MidiControllerSource` directly: `_source.enumerate()` (`:42`, `:71`, `:166`),
`_source.open(id)` (`:92`, `:127`, `:187`), `_source.close()` (`:145`),
`_source.activity.listen(...)` (`:39`). Device enumeration, open/close, persistence
reconciliation, and hotplug lost/restored detection are repository-layer orchestration. VGV:
a Cubit calls a repository, never a data client.

## Technical Approach

Create `packages/midi_device_repository` that wraps the borrowed `MidiControllerSource`,
owns the lifecycle + hotplug supervision + persistence, and exposes a `Stream<MidiDeviceState>`
plus imperative commands. `MidiSetupCubit` subscribes and forwards.

- **Disposal contract:** the repository **borrows** the source — `ControllerRepository` still
  owns disposal (`controller_repository.dart:92-98`). The repository must NOT dispose it.
- **New-package decision (confirmed by review):** a dedicated package, not folded into
  `controller_repository` (whose single responsibility is input→action mapping + MIDI-learn).
- Pure Dart where feasible (no Flutter SDK); join the per-package VGV workflow (analyze +
  test + 90% coverage gate).

## Tasks

- [ ] Scaffold `packages/midi_device_repository` (`pubspec.yaml` `publish_to: none`,
      `analysis_options.yaml`, barrel `lib/midi_device_repository.dart`, `src/`, `test/`).
      Depends on `midi_client` (data) + `settings_repository`.
- [ ] Define domain models in `src/models/`: `MidiDevice` (id, name) and `MidiDeviceState`
      (devices, status, connectivity, activity tick) — immutable `Equatable`.
- [ ] Implement `MidiDeviceRepository` in `src/midi_device_repository.dart`: move
      enumerate / open / close / hotplug-poll supervision / persistence out of
      `MidiSetupCubit` (its `_hydrate`, `refresh`, `select`, `selectNone`, `_onActivity`
      logic). Expose `Stream<MidiDeviceState>` + commands `select(id)`, `selectNone()`,
      `refresh()`. Preserve the exact poll cadence and lost/restored transition semantics.
- [ ] Rewrite `lib/audio_setup/cubit/midi_setup_cubit.dart` as a thin projector: subscribe to
      the repository stream, forward commands, delete the `midi_client` import.
- [ ] Wire the repository in `lib/app/run_loopy.dart` (construct once) and provide via
      `RepositoryProvider` in `lib/app/view/app.dart`; pass to `MidiSetupCubit`.
- [ ] **Tests:** port `test/audio_setup/cubit/midi_setup_cubit_test.dart`'s 11 scenarios into
      `packages/midi_device_repository/test/midi_device_repository_test.dart` (enumerate, null
      source, activity tick, select/switch/failed-open/selectNone, launch auto-reconnect,
      hotplug lost→restored + first-observation-no-transition, audio independence). Add a test
      asserting the repository does **not** dispose the borrowed `MidiControllerSource`.
- [ ] **Tests:** shrink `midi_setup_cubit_test.dart` to a thin projection/command-forwarding
      contract test (verify it mirrors the stream + forwards each command).

## Acceptance Criteria

- [ ] `MidiSetupCubit` imports no data package (no `package:midi_client`).
- [ ] MIDI input device selection, persistence, failed-open recovery, and hotplug
      lost/restored banners behave exactly as before.
- [ ] Switching/losing a MIDI device never restarts audio (engine independence preserved).
- [ ] `flutter analyze` + `bloc_lint` clean (app + new package).
- [ ] Full suite green; `midi_device_repository` ≥90% coverage (CI gate).

## Dependencies

None — this PR stands alone and must land **first** in the V1 → D2a → D2b → V2 chain.

## References

- Target file: [lib/audio_setup/cubit/midi_setup_cubit.dart](../../lib/audio_setup/cubit/midi_setup_cubit.dart)
- Pattern to mirror: [lib/audio_setup/cubit/audio_setup_cubit.dart](../../lib/audio_setup/cubit/audio_setup_cubit.dart)
- Disposal owner: [packages/controller_repository/lib/src/controller_repository.dart](../../packages/controller_repository/lib/controller_repository.dart)
- Wiring: [lib/app/run_loopy.dart](../../lib/app/run_loopy.dart), [lib/app/view/app.dart](../../lib/app/view/app.dart)
