---
title: "feat: RPi console — Part 3: rotary encoder (config-only)"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 3: rotary encoder (config-only) - Standard

> Part 3 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 2** (`gpio_client` package). This extends that package. Can proceed **in parallel with Part 4** (LED firmware) once Part 2 merges.

## Overview

Add rotary-encoder support to `gpio_client`: software quadrature decode of the A/B pins plus the push-switch (SW). Ship **option A (config-only)**: the encoder *press* maps to a normal `gpio` press in `gpioDefaults()`; rotation is decoded but **reserved/unused in v1**. This keeps the press-only control pipeline untouched and lets the 16″ touchscreen handle all configuration.

## Problem Statement

A rotary encoder produces relative +1/−1 detents, but [`ControllerMapping.resolve()`](../../packages/controller_repository/lib/src/controller_mapping.dart:67) returns `null` for anything that isn't a press (`value > 0`) and [`RawControllerInput`](../../packages/controller_repository/lib/src/controller_input.dart) has no signed/relative value. Footswitches and the encoder *push-switch* fit the press model; encoder *rotation* does not. Extending the pipeline for relative input (option B) is real work for no v1 payoff given the touchscreen — so rotation is decoded but reserved.

## Technical Approach

### Tasks

- [ ] Encoder A/B reading with software quadrature decode in `gpio_client` (fine at human turn speed; the Pi has no hardware decoder).
- [ ] Encoder SW (push) emits a normal `RawControllerInput(kind: gpio, id: <sw-pin>, value: 0|1)` — just another `gpio` pin/id, **no new concept**.
- [ ] Add the encoder push-switch pin to `ControllerMapping.gpioDefaults()`.
- [ ] **Spurious-edge sanity gate**: ignore implausibly fast repeated edges (guards GPIO miswire / ESD transients firing phantom transport actions).
- [ ] Decode rotation into a relative delta internally, but **do not** route it through `resolve()` in v1 (reserved). File option B (first-class relative/scroll input extending `RawControllerInput`/`LooperAction`) as a follow-up plan item.

### Mock files

- `packages/gpio_client/lib/src/gpio_controller_source.dart` (modified — quadrature + SW + sanity gate)
- `packages/gpio_client/test/gpio_encoder_test.dart` (new — quadrature decode + sanity gate)
- `packages/controller_repository/lib/src/controller_mapping.dart` (modified — encoder SW in `gpioDefaults()`)

## Acceptance Criteria

### Functional

- [ ] Encoder press maps to its action end-to-end on the Pi.
- [ ] Quadrature direction decoded correctly (CW vs CCW) under test.
- [ ] A floating/bouncing pin does not produce phantom transport actions (sanity gate verified in a soak/fuzz test).
- [ ] Rotation is decoded but has no performance side-effect in v1 (documented as reserved).

### Quality Gates

- [ ] `gpio_client` stays ≥90% coverage; quadrature + sanity-gate tests run headless via `FakeGpioBindings`.
- [ ] Option-B follow-up recorded (not implemented).

## References

- resolve() press-only: [`controller_mapping.dart:67`](../../packages/controller_repository/lib/src/controller_mapping.dart)
- RawControllerInput: [`controller_input.dart`](../../packages/controller_repository/lib/src/controller_input.dart)
- Package: `packages/gpio_client` (from Part 2)
