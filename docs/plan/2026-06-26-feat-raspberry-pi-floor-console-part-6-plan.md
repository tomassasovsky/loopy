---
title: "feat: RPi console — Part 6: app supervision + power-cut resilience"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 6: app supervision + power-cut resilience - Extensive

> Part 6 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 5** (the kiosk launcher must exist before it can be supervised; rootfs design interacts with the boot config).

## Overview

The survivability half of the original Phase 4: keep the appliance alive and the SD card intact when someone yanks the power mid-set. App supervision/respawn on crash, a read-only rootfs (or overlayfs) + safe-shutdown, and an SD-integrity check on boot. These are OS-level concerns that split cleanly from the display work in Part 5.

> **Scope note (per review):** session checkpoint-and-restore of the *live loop* is **deferred to a separate plan** — it contradicts the "BLoCs unchanged" invariant and is a product-wide persistence concern, not Pi-specific. This PR's durability target is **"no SD corruption"** (read-only root), not "≤N s session loss." Read-only root protects the OS, not unsaved musical work; the loop-durability feature is tracked separately.

## Problem Statement

A stompable performance unit will get its power cut mid-session. Today the OS is a normal read-write rootfs (SD-corruption risk on power-cut) and the app has no supervisor (a crash leaves a black console with no recovery on a keyboard-less unit). An app respawn could also leave an orphaned waveform window on the 7″.

## Technical Approach

### Tasks

- [ ] **App supervision:** systemd watchdog/respawn on crash within a defined time budget. On respawn, clean orphan waveform windows via the existing [`closeOrphanWindows()`](../../lib/visualizer/waveform_window_service.dart:36).
- [ ] **Read-only rootfs / overlayfs:** make the root filesystem resilient to hard power-cut; writable state confined to a clearly-scoped partition/overlay.
- [ ] **Safe-shutdown story:** define the power-down path (power button / shutdown handling) consistent with the read-only root.
- [ ] **SD integrity check on boot:** detect a corrupted writable partition and boot to a visible "needs attention" screen rather than failing into a black display.

### Mock files

- `deploy/rpi/loopy-kiosk.service` (modified — watchdog/respawn directives)
- `deploy/rpi/overlayfs/` (new — read-only root / overlay config)
- `deploy/rpi/boot-integrity-check.sh` (new — SD integrity check + "needs attention" fallback)
- `docs/RUNNING_ON_RPI.md` (modified — resilience/rootfs/shutdown)

## Acceptance Criteria

### Functional

- [ ] Killing the app → it respawns cleanly within the defined budget; no orphan waveform window remains.
- [ ] A corrupted writable partition → unit boots to a visible "needs attention" screen, not a black display.

### Non-Functional

- [ ] **Hard power-cut ×20 mid-session → no SD-card corruption** (read-only rootfs/overlayfs + boot integrity check).
- [ ] Safe-shutdown path documented and reproducible.

### Quality Gates

- [ ] Power-cut stress run (≥20 cycles) documented with results in `docs/RUNNING_ON_RPI.md`.
- [ ] Respawn behavior verified on-device (glue files are coverage-excluded; on-hardware check is the gate).

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| SD corruption on power-cut | High | Read-only rootfs/overlayfs + boot integrity check. |
| Crash leaves a dead console | High | systemd watchdog/respawn + orphan-window cleanup. |
| Scope creep into loop-persistence | Medium | Explicitly deferred to a separate plan; target is "no SD corruption." |

## References

- Orphan-window cleanup: [`waveform_window_service.dart:36`](../../lib/visualizer/waveform_window_service.dart)
- Kiosk launcher: from Part 5 (`deploy/rpi/loopy-kiosk.service`)
