---
title: "feat: RPi console — Part 2: gpio_client package + footswitches + GPIO default mapping"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 2: gpio_client package + footswitches + GPIO default mapping - Extensive

> Part 2 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 1** (ARM64 CI + kiosk-target decision). The ARM64 job validates the package compiles; the on-device decision affects how wiring is exercised on hardware.

## Overview

The single new native binding. Create the `packages/gpio_client` package (libgpiod FFI) implementing the existing [`ControllerSource`](../../packages/controller_repository/lib/src/controller_source.dart:7) seam for footswitches, add a `ControllerMapping.gpioDefaults()` factory, **and wire the mapping in** so the console has working footswitches on first boot with zero config. Footswitch input flows through the unchanged `ControllerRepository → ControllerMapping.resolve() → ControllerEvent → LooperBloc` pipeline.

## Problem Statement

`ControllerSourceKind.gpio` already exists ([`controller_input.dart:12`](../../packages/controller_repository/lib/src/controller_input.dart)) and the pipeline is unit-tested with a fake GPIO source ([`controller_repository_test.dart`](../../packages/controller_repository/test/controller_repository_test.dart)), but there is **no native GPIO driver** and **no GPIO mapping**. Critically:

- `ControllerRepository`'s constructor falls back to `ControllerMapping.defaults()` — which is **MIDI-CC only** ([`controller_mapping.dart:35`](../../packages/controller_repository/lib/src/controller_mapping.dart)) — when no `mapping:` is passed, and [`run_loopy.dart:69`](../../lib/app/run_loopy.dart) passes none. So a `gpioDefaults()` factory alone is **dead code** unless something selects it on the Pi build.
- There is **no mapping persistence layer** today; `withBinding`/`setMapping` only mutate in-memory state. Remapping via the touchscreen would not survive reboot.

## Technical Approach

### Architecture

`GpioControllerSource implements ControllerSource` mirrors [`MidiControllerSource`](../../packages/midi_client/lib/src/midi_controller_source.dart) exactly:

- Owns a broadcast `StreamController<RawControllerInput> _inputs`; exposes `Stream<RawControllerInput> get inputs` and `Future<void> dispose()`.
- Footswitch lines = one GPIO each, **pull-up + leading-edge per-trigger debounce** (map of `(kind,id) → last emit µs`; emit only if `now - last >= debounceUs`). Leading-edge per the deferred footswitch-debounce decision.
- Emits `RawControllerInput(kind: ControllerSourceKind.gpio, id: pin, value: 0|1)`.
- **All native calls sit behind a hand-authored `GpioBindings` interface** (FFI plugins in this repo are hand-authored, not ffigen'd) so the source is 100% testable headless via a `FakeGpioBindings` + `pushForTest()` — **required**: CI runs a 90% coverage gate ([`.github/workflows/main.yaml:20-28`](../../.github/workflows/main.yaml), `very_good_workflows/flutter_package.yml@v1`) and there is no GPIO hardware in CI.

**Factory + wiring (mirrors the real MIDI precedent):** `createNativeGpioSource()` lives in a repository-layer file — mirror [`packages/midi_device_repository/lib/src/native_midi_source.dart`](../../packages/midi_device_repository/lib/src/native_midi_source.dart) exactly: wrap construction in `try/catch`, report via `FlutterError.reportError`, `return null` on any platform without the backend. **Off-Pi detection** must be explicit (e.g. `File('/dev/gpiochip0').existsSync()`), so the factory returns `null` on Linux CI runners and desktop. `run_loopy.dart` only *calls* it.

**Mapping selection (the wiring fix):** pass the GPIO map to `ControllerRepository`. In the source-wiring block ([`run_loopy.dart:65`](../../lib/app/run_loopy.dart)):

```dart
final gpioSource = createNativeGpioSource(); // null off-Pi
final controllerRepository = ControllerRepository(
  sources: [?midiSource, ?gpioSource],
  // Merge GPIO + MIDI defaults so both sources coexist on the console.
  mapping: gpioSource != null
      ? ControllerMapping.gpioDefaults() // or merged MIDI+GPIO defaults
      : null,
);
```

> **Decision required in this PR:** merge vs replace MIDI defaults (both sources can coexist), and whether mapping **persistence** is in scope. Recommendation: scope persistence to load/save a single `ControllerMapping` via the existing `SettingsRepository` (matching how MIDI device selection is already persisted), so touchscreen remaps survive reboot. If persistence is deferred, say so explicitly and seed `gpioDefaults()` at construction.

### Tasks

- [ ] Scaffold `packages/gpio_client` mirroring [`packages/midi_client`](../../packages/midi_client): barrel export, `lib/src/`, `test/helpers/`. pubspec: `name: gpio_client`, `publish_to: none`, `version: 0.1.0`, matching SDK constraints (`^3.11.0` / Flutter `^3.41.0`), deps `controller_repository`, `ffi`, `flutter`, `meta`; dev dep `very_good_analysis: ^10.2.0`. (Note: unlike `midi_client`, **no `loopy_engine` dep** — libgpiod is its own native lib.)
- [ ] Define the hand-authored `GpioBindings` abstraction (the actual hard part of "mirror midi_client") — the libgpiod FFI surface behind an interface.
- [ ] Implement `GpioControllerSource implements ControllerSource` (footswitch lines, pull-up, leading-edge debounce, `pushForTest()` `@visibleForTesting`).
- [ ] Add `ControllerMapping.gpioDefaults()` in [`controller_mapping.dart`](../../packages/controller_repository/lib/src/controller_mapping.dart) (footswitch pins → `LooperAction`s).
- [ ] Add `createNativeGpioSource()` in a repository file mirroring `native_midi_source.dart` (try/catch + `FlutterError.reportError` + null; explicit off-Pi detection).
- [ ] Wire source + mapping into [`run_loopy.dart`](../../lib/app/run_loopy.dart) (merge-vs-replace decision; persistence decision).
- [ ] (Optional, cheap-now/painful-later) expose an `activity` stream mirror like [`MidiControllerSource.activity`](../../packages/midi_client/lib/src/midi_controller_source.dart) for a touchscreen input-activity indicator.
- [ ] Tests (see below).

### Mock files

- `packages/gpio_client/lib/gpio_client.dart` (barrel)
- `packages/gpio_client/lib/src/gpio_controller_source.dart`
- `packages/gpio_client/lib/src/gpio_bindings.dart` (hand-authored FFI interface)
- `packages/gpio_client/lib/src/native_gpio_source.dart` (`createNativeGpioSource()`)
- `packages/gpio_client/pubspec.yaml`
- `packages/gpio_client/test/gpio_controller_source_test.dart`
- `packages/gpio_client/test/helpers/fake_gpio_bindings.dart`
- `packages/controller_repository/lib/src/controller_mapping.dart` (modified — `gpioDefaults()`)
- `packages/controller_repository/test/controller_mapping_test.dart` (modified — `gpioDefaults()` test)
- `lib/app/run_loopy.dart` (modified — wiring)

## Acceptance Criteria

### Functional

- [ ] On the Pi, stomping a mapped footswitch triggers the correct transport action end-to-end (rec/play/stop/track/bank).
- [ ] **First boot has working footswitches with zero config** (`gpioDefaults()` actually selected by `ControllerRepository`).
- [ ] `createNativeGpioSource()` returns `null` off-Pi (desktop, CI) without throwing.
- [ ] Leading-edge debounce swallows contact bounce but preserves intentional taps.
- [ ] MIDI + GPIO sources coexist (if merge chosen) — laptop-pedal users unaffected.

### Quality Gates

- [ ] `gpio_client` ≥90% coverage; all native calls behind `GpioBindings` so tests run headless. Package discovered by the `very_good_workflows` `build` job.
- [ ] `gpioDefaults()` mapping test + debounce test + stream-emission test (via `pushForTest()`) pass.
- [ ] VGV review passes: factory in repository layer (not entrypoint logic), package structure matches `midi_client`.

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| FFI library load crashes the package import under `flutter test` | High | Lazy/guarded load behind `GpioBindings`; fake bindings in tests. |
| `gpioDefaults()` left unwired (dead code) | High | Explicit wiring task + first-boot acceptance criterion. |
| Touchscreen remaps lost on reboot | Medium | Scope mapping persistence to `SettingsRepository` (or explicitly defer). |

## References

- ControllerSource: [`controller_source.dart:7`](../../packages/controller_repository/lib/src/controller_source.dart)
- GPIO enum: [`controller_input.dart:12`](../../packages/controller_repository/lib/src/controller_input.dart)
- MIDI source template: [`midi_controller_source.dart`](../../packages/midi_client/lib/src/midi_controller_source.dart)
- Mapping (MIDI-CC default): [`controller_mapping.dart:35`](../../packages/controller_repository/lib/src/controller_mapping.dart); resolve press-only: [`controller_mapping.dart:67`](../../packages/controller_repository/lib/src/controller_mapping.dart)
- Repository-layer factory precedent: [`native_midi_source.dart`](../../packages/midi_device_repository/lib/src/native_midi_source.dart)
- Wiring point: [`run_loopy.dart:65`](../../lib/app/run_loopy.dart)
- Pipeline → bloc: [`controller_repository.dart:49`](../../packages/controller_repository/lib/src/controller_repository.dart), [`looper_bloc.dart:370`](../../lib/looper/bloc/looper_bloc.dart)
- CI 90% gate: [`.github/workflows/main.yaml:20`](../../.github/workflows/main.yaml)
