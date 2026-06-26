---
title: "feat: RPi console — Part 4: WS2812 LED driver firmware + Pi LED channel"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 4: WS2812 LED driver firmware + Pi LED channel - Extensive

> Part 4 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 2** (`gpio_client`/console wiring path established for deriving state). Independent of Part 3 — **Parts 3 and 4 can run in parallel** once Part 2 merges (encoder is pure Dart; LED firmware is a separate MCU codebase).

## Overview

Offload the one hard-real-time piece — WS2812 timing — to a small dedicated driver MCU, and add a Pi-side LED-output channel that derives LED state from `LooperState` and pushes compact frames over SPI/UART. WS2812 needs microsecond-precise timing the Pi handles awkwardly (SPI/PWM+DMA, root config, 3.3→5 V shift, Pi-5 driver quirks); a dedicated MCU running FastLED-grade timing isolates it from the Pi and the audio path. A boot-time health handshake makes a missing/unflashed driver a **visible fault**, not silent dark LEDs.

## Problem Statement

The console needs an LED ring + indicator strip reflecting transport state in real time. Driving WS2812 directly from the Pi is the finicky part the hybrid-controls decision exists to avoid. There is no LED output path today, and no spec for the wire format or the driver health check — without those, the Pi-side and firmware developers can mismatch the interface.

## Technical Approach

### Architecture

```
LooperState → Pi LED-output channel → [wire frame] → SPI/UART → driver MCU → WS2812 ring + strip
                                          ↑
                              boot-time health handshake (ping/ack)
```

- **Driver chip + protocol decision (spike):** RP2040/QT-Py (clean, cheap, USB-flashable, PIO-perfect for WS2812) vs reusing the already-designed 32U4 (zero new firmware if its LED path is kept). Transport: SPI vs UART vs minimal USB-serial.
- **Wire format (define in this PR — prevents integration rework):** a compact fixed frame, e.g. `[0xA5 sync][frame-type][payload…][checksum]`. Specify byte layout, channel/LED count, framing byte(s), and the checksum decision in one paragraph in the firmware README before either side is written.
- **Health handshake:** simplest possible — a one-byte ping → ack with a short timeout (e.g. 2 s with no ack → show a banner). Do **not** spec a stateful protocol.
- **Pi-side channel:** derive LED state from `LooperState`; push frames at the transport-state cadence (not audio-rate). Boot-time health check → visible error state if the driver is missing/unflashed.

### Tasks

- [ ] Spike + decide driver chip (RP2040 vs 32U4) and Pi↔driver protocol (SPI/UART/USB-serial).
- [ ] Define the LED wire format (one-paragraph spec in the firmware README) before coding either side.
- [ ] Firmware: receive frames, drive WS2812 ring + indicator strip (FastLED-grade timing), expose the ping/ack health handshake.
- [ ] Pi-side LED-output channel: map `LooperState` → LED state → frames; push over the chosen transport.
- [ ] Boot-time health check → visible fault state if no ack (not silent dark LEDs).
- [ ] Define + measure an **LED-vs-audio skew budget** (separate from the ≤10 ms audio gate — the LED path latency differs from the action latency).
- [ ] Firmware README in `hardware/` or `firmware/` (wire format + flashing + protocol).

### Mock files

- `firmware/led_driver/` (new — MCU firmware + README with wire format)
- Pi-side LED channel source (location per console wiring; e.g. `packages/gpio_client/lib/src/led_output.dart` or a small dedicated module) + its test with a fake transport.

## Acceptance Criteria

### Functional

- [ ] LEDs reflect transport state (rec/play/stop/track/bank) in real time within the skew budget.
- [ ] A missing/unflashed driver produces a visible fault at boot, not silent dark LEDs.
- [ ] WS2812 timing is stable (no flicker/corruption) under sustained operation.

### Non-Functional

- [ ] Measured LED-vs-audio skew is within the defined budget.
- [ ] LED timing runs entirely on the driver MCU — no hard-real-time work on the Pi or audio thread.

### Quality Gates

- [ ] Pi-side LED channel is unit-tested via a fake transport (≥90% on the Dart portion; CI 90% gate).
- [ ] Wire format documented before integration; firmware README complete.

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| Pi↔driver interface mismatch | Medium | Define wire format up front in README. |
| Silent dark LEDs on driver failure | Medium | Boot-time ping/ack health check + visible fault. |
| LED-vs-audio skew distracting on stage | Low | Define + measure a skew budget. |

## References

- Hybrid-controls rationale: [umbrella plan](2026-06-26-feat-raspberry-pi-floor-console-plan.md) + [brainstorm](../brainstorm/2026-06-26-raspberry-pi-console-brainstorm-doc.md)
- Existing 32U4 pedal (LED path candidate to reuse): PR [#85](https://github.com/tomassasovsky/loopy/pull/85)
- Footswitch debounce / leading-edge note: see umbrella plan
