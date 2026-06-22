---
title: "refactor: domain models for audio-config + pedal output (D2b)"
type: refactor
date: 2026-06-19
---

## PR 2b (D2 — audio-config cluster + pedal output) — Domain models

> Part 3 of 4. Parent plan:
> [2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md](2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md).
> Source finding: [docs/code-review/architecture-review.md](../code-review/architecture-review.md) (D2 + corrected pedal-output leak).

## Overview

This PR finishes D2: it introduces repository-owned domain equivalents for the **audio-config
cluster** (the highest-friction types — they flow through the audio-setup, bootstrap, and app
wiring), folds `settings_repository`'s lone `AudioBackend` coupling, and — corrected after
technical review — adds a **pedal output-device** domain model in `pedal_repository` so the
pedal UI stops importing `midi_client`. Behavior-preserving. After this PR, no shared `lib/`
file imports `midi_client`, and `loopy_engine` survives only in `run_loopy.dart` (cleared in
Part 4).

## Problem Statement

- `looper_repository` re-exports `AudioBackend`, `AudioDevice`, `EngineConfig`,
  `LatencyState`, `LoopbackInfo`, `LoopbackKind`; these flow into `audio_setup_cubit/state`,
  `audio_bootstrap`, `audio_settings_section`, `audio_device_picker`, `app.dart`, `run_loopy`.
- `packages/settings_repository/lib/src/settings_repository.dart:7` imports `loopy_engine`
  solely for the `AudioBackend` enum.
- **Pedal output leak (corrected):** `pedal_cubit.dart:6` and `pedal_settings_section.dart:7`
  do `show MidiDevice` from `midi_client` because `PedalRepository.availableOutputs()`
  (`pedal_repository.dart:73`) returns raw `List<MidiDevice>` — the **output** path, distinct
  from Part 1's input path. This must be fixed inside `pedal_repository` (a domain output
  model), **not** by reusing Part 1's type (which would create a forbidden repo→repo dep).

## Technical Approach

Domain audio-config models in `looper_repository`; `settings_repository` gets its **own**
`AudioBackend`; `pedal_repository` gets its own output-device domain model.

## Tasks

- [ ] Define domain `AudioBackend`, `AudioDevice`, `EngineConfig`, `LatencyState`,
      `LoopbackInfo`, `LoopbackKind` in `packages/looper_repository/lib/src/models/`; map at
      the repository boundary.
- [ ] Update audio consumers to the domain types: `lib/audio_setup/cubit/audio_setup_cubit.dart`,
      `lib/audio_setup/cubit/audio_setup_state.dart`, `lib/app/audio_bootstrap.dart`,
      `lib/audio_setup/view/audio_settings_section.dart`,
      `lib/audio_setup/view/audio_device_picker.dart`, `lib/app/view/app.dart` (audio portions),
      `lib/app/run_loopy.dart` (the `AudioDevice` list now comes from the domain barrel),
      `lib/l10n/localized.dart` (audio-config portion).
- [ ] Give `packages/settings_repository` its **own** domain `AudioBackend` enum (round-trip
      persistence test); remove its `loopy_engine` import. Do **not** import
      `looper_repository` (no repo→repo dependency).
- [ ] **Pedal output (corrected scope):** add a domain output-device model in
      `packages/pedal_repository/lib/src/models/`; change
      `PedalRepository.availableOutputs()` and `bind(...)` to use it; update
      `lib/pedal/cubit/pedal_cubit.dart` and `lib/pedal/view/pedal_settings_section.dart` to
      drop their `show MidiDevice` imports. (`pedal_repository` continues to depend on
      `midi_client` internally — that's a legitimate repository→data edge.)
- [ ] Remove `AudioBackend`, `AudioDevice`, `EngineConfig`, `LatencyState`, `LoopbackInfo`,
      `LoopbackKind` from the `looper_repository` barrel; classify `EngineResult` (drop if no
      `lib/` reference, else keep as a documented exception). Keep the constant keepers.
- [ ] **Tests:** update audio-setup/bootstrap/pedal tests to domain types; add round-trip
      mapping tests at each boundary (engine↔domain config; `midi_client`↔domain output device).

## Acceptance Criteria

- [ ] No `lib/` file imports `loopy_engine` except `lib/app/run_loopy.dart` (cleared in Part 4).
- [ ] `pedal_cubit` and `pedal_settings_section` import no data package.
- [ ] `settings_repository` no longer imports `loopy_engine`; audio config persistence
      round-trips unchanged.
- [ ] ASIO/device pickers, loopback detection, latency display, and the pedal output dropdown
      behave exactly as before.
- [ ] `flutter analyze` + `bloc_lint` clean; full suite green; touched packages ≥90% coverage.

## Dependencies

- **Requires Part 2a (D2 effects) merged** — both edit the `looper_repository` barrel and the
  shared `localized.dart` / `app.dart` / `run_loopy.dart`; landing in sequence avoids a
  three-way merge.
- Blocks Part 4 (V2) — V2's `pubspec` removals are only safe once this PR clears the audio +
  pedal-output leaks.

## References

- Barrel: [packages/looper_repository/lib/looper_repository.dart:5-24](../../packages/looper_repository/lib/looper_repository.dart)
- Settings coupling: [packages/settings_repository/lib/src/settings_repository.dart:7](../../packages/settings_repository/lib/src/settings_repository.dart)
- Pedal output source: [packages/pedal_repository/lib/src/pedal_repository.dart:73](../../packages/pedal_repository/lib/src/pedal_repository.dart)
- Pedal consumers: [lib/pedal/cubit/pedal_cubit.dart](../../lib/pedal/cubit/pedal_cubit.dart), [lib/pedal/view/pedal_settings_section.dart](../../lib/pedal/view/pedal_settings_section.dart)
