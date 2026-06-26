---
title: "feat: RPi console — Part 8: hardware — enclosure, protection, power, BOM"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 8: hardware — enclosure, protection, power, BOM - Extensive

> Part 8 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Soft dependency only — runs in parallel throughout.** Enclosure design, BOM, and the protection circuit can start day one. The on-hardware **latency** and **soak** gates require a bootable ARM64 bundle (**Part 1** minimum) and ideally the kiosk launcher (**Part 5**) for realistic load.

## Overview

All hardware deliverables for the floor console: a tilted enclosure mounting the 16″ touchscreen + 7″ waveform display up top and a stompable footswitch/encoder panel on the front edge; GPIO input protection; a power/thermal budget; the 7″ HDMI-vs-DSI display spike; the BOM/shopping list; and the on-hardware latency + thermal-soak gates that qualify the unit.

## Problem Statement

The two heaviest non-app chunks are the enclosure and the boot integration; this PR owns the enclosure. Pi GPIO is **3.3 V and not 5 V-tolerant**, so footswitch/encoder lines (longer internal runs, ESD, contact bounce) need protection or a miswire/transient can kill a pin. A single supply must power the Pi 5 + two screens + USB interface + LED driver without throttling, and the ≤10 ms latency target must be re-validated on the real interface + Pi 5 + PipeWire quantum.

## Technical Approach

### Tasks

- [ ] **Enclosure:** tilted unit mounting the 16″ touchscreen + 7″ waveform + a stompable footswitch/encoder panel; ruggedization; **active cooling** for the Pi 5 (runs warm in a closed enclosure under sustained audio + GPU load).
- [ ] **GPIO input protection:** series resistors / clamping on footswitch + encoder lines (3.3 V discipline) so a miswire/transient can't kill a Pi pin.
- [ ] **Power & thermals:** single-supply budget for Pi 5 + two screens + USB interface + LED driver; confirm active cooling prevents throttle under sustained load.
- [ ] **Display spike:** 7″ HDMI vs official DSI (HDMI = uniform bus + clean second-window mapping but uses the 2nd micro-HDMI; DSI frees an HDMI port but is 800×480 + needs DSI compositor mapping; resolution matters little for a waveform). Feeds Part 5's per-display scale.
- [ ] **BOM + shopping list:** new `hardware/loopy_console_shopping_list.md` mirroring [`hardware/loopy_pedal_shopping_list.md`](../../hardware/loopy_pedal_shopping_list.md) (Argentina-sourced): 16″ touchscreen, 7″ display, Pi 5 + active cooler, USB interface (Scarlett-class), footswitches, EC11 encoder, WS2812 ring + strip, LED-driver MCU, protection passives, PSU, enclosure materials.
- [ ] **On-hardware gates:** re-run the **≤10 ms round-trip latency** target on the chosen USB interface + Pi 5 + PipeWire quantum (run at 48 kHz / Pro Audio profile per [`docs/RUNNING_ON_LINUX.md`](../../docs/RUNNING_ON_LINUX.md)); **≥2 h thermal soak** under audio + dual-display + GPU load in the closed enclosure.

### Mock files

- `hardware/loopy_console_shopping_list.md` (new — BOM)
- `hardware/console/` (new — enclosure design + fab files + protection circuit)
- `docs/RUNNING_ON_RPI.md` (modified — latency + soak results, display-spike outcome)

## Acceptance Criteria

### Functional

- [ ] Assembled unit: 16″ + 7″ mounted, footswitch panel stompable, all controls wired through protected GPIO.
- [ ] BOM complete and sourceable; 7″ display interface decided (HDMI vs DSI).

### Non-Functional

- [ ] **≤10 ms round-trip audio latency** on the chosen USB interface + Pi 5 + PipeWire quantum (re-measured on hardware).
- [ ] **≥2 h soak** (audio + dual-display + GPU, closed enclosure) with no thermal throttle and no xrun-rate regression.
- [ ] Miswire test does not damage a Pi GPIO pin (protection verified).
- [ ] Stompable panel survives stage-abuse testing.

### Quality Gates

- [ ] Latency + soak reports documented in `docs/RUNNING_ON_RPI.md`.
- [ ] Protection circuit reviewed; power budget documented.

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| GPIO pin killed by miswire/ESD | High | Series R / clamping; 3.3 V discipline; miswire test. |
| Thermal throttle in closed enclosure | Medium | Active cooling; 2 h soak gate. |
| Latency misses ≤10 ms on chosen interface | Medium | Re-measure on hardware; tune PipeWire quantum before committing to the model. |
| Underpowered single supply | Medium | Budget for all loads; headroom margin. |

## References

- Pedal BOM template: [`hardware/loopy_pedal_shopping_list.md`](../../hardware/loopy_pedal_shopping_list.md)
- Audio setup (48 kHz / Pro Audio / PIPEWIRE_QUANTUM): [`docs/RUNNING_ON_LINUX.md`](../../docs/RUNNING_ON_LINUX.md)
- Latency gate context: [umbrella plan](2026-06-26-feat-raspberry-pi-floor-console-plan.md)
