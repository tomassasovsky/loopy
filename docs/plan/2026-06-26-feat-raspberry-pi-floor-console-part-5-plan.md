---
title: "feat: RPi console — Part 5: kiosk boot + dual-display launch"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 5: kiosk boot + dual-display launch - Extensive

> Part 5 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 1** (kiosk-target + compositor decision determines this entire approach). Independent of Parts 2–4 software work.

## Overview

Make the unit boot straight into the Loopy app full-screen across both displays: a systemd-launched kiosk session on the compositor chosen in Part 1, with the 16″ as the main UI ([`BigPictureView`](../../lib/looper/view/big_picture_view.dart:26)) and the 7″ as the waveform ([`WaveformWindowService`](../../lib/visualizer/waveform_window_service.dart:29)), pinned deterministically across boots. Includes per-display DPI/scale and a single-display fallback with a visible notice. This is the display/launch half of the original Phase 4.

## Problem Statement

The app is already chromeless on `BigPictureView` and opens a second waveform window, but there is no boot-to-kiosk story, no deterministic mapping of which window lands on which output, and the second-window open path **fails silently**: [`WaveformWindowService.open()`](../../lib/visualizer/waveform_window_service.dart:77) has a 10 s ready-timeout that no-ops. On a foot-only appliance, an output-naming race at boot (waveform on the 16″, UI on the 7″) has no recovery path, and the 16″ (~1080p) vs 7″ (800×480 if DSI) differ sharply in density.

## Technical Approach

### Tasks

- [ ] **Boot-to-kiosk:** systemd unit + compositor config (from Part 1) auto-launching the app full-screen at boot. App is already chromeless on `BigPictureView`.
- [ ] **Deterministic dual-display pinning:** map the waveform second window to the 7″ output reliably across boots using output-name pinning (`wlr-randr` / `wlr-output-management` on the Part-1 compositor). The main UI lands on the 16″.
- [ ] **Surface the silent second-window failure:** the 10 s ready-timeout ([`waveform_window_service.dart:77`](../../lib/visualizer/waveform_window_service.dart)) must produce an operator-visible indicator instead of degrading silently.
- [ ] **Single-display fallback:** if only one display is detected, degrade to single-display mode with a visible notice rather than a half-blank console.
- [ ] **Per-display DPI/scale:** set a usable Flutter logical-pixel scale per output via the compositor (`wlr-randr --scale` / `GDK_SCALE`, decided in Part 1) — specify whether scale is per-display or global. Verify on real panels (16″ ~1080p, 7″ 800×480/1080p depending on the Part-6 HDMI-vs-DSI spike).

### Mock files

- `deploy/rpi/loopy-kiosk.service` (new — systemd unit)
- `deploy/rpi/compositor/` (new — compositor config + output-name pinning)
- `lib/visualizer/waveform_window_service.dart` (modified — surface open failure; coverage-excluded glue)
- `docs/RUNNING_ON_RPI.md` (modified — kiosk/display setup)

## Acceptance Criteria

### Functional

- [ ] Cold boot → app full-screen, **16″ = main UI, 7″ = waveform**, deterministically across reboots, no keyboard/mouse.
- [ ] If the second window fails to open, an operator-visible indicator appears (no silent degrade).
- [ ] Only one display present → single-display mode with a visible notice.
- [ ] Both panels render at a usable scale (verified on real hardware).

### Quality Gates

- [ ] Display pinning verified across ≥5 reboots (no output-naming race).
- [ ] `docs/RUNNING_ON_RPI.md` documents the kiosk + display setup reproducibly.
- [ ] Note: `waveform_window_service.dart` / `run_loopy.dart` / `bootstrap.dart` are in CI `coverage_excludes` ([`.github/workflows/main.yaml:29`](../../.github/workflows/main.yaml)) — correctness here rests on the on-hardware checks, so the reboot/display verification is the real gate.

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| Output-naming race flips displays | High | Output-name pinning; verify across reboots; visible fallback. |
| Compositor lacks scale/pinning controls | High | Resolved in Part 1 (wlr-based compositor). |
| Over/under-scaling on the small panel | Medium | Per-display scale; verify on real panels (depends on Part-6 panel choice). |

## References

- Main UI: [`big_picture_view.dart:26`](../../lib/looper/view/big_picture_view.dart)
- Second window + silent timeout: [`waveform_window_service.dart:64`](../../lib/visualizer/waveform_window_service.dart), [`:77`](../../lib/visualizer/waveform_window_service.dart)
- Orphan-window cleanup (reused in Part 6): [`waveform_window_service.dart:36`](../../lib/visualizer/waveform_window_service.dart)
- Coverage excludes: [`.github/workflows/main.yaml:29`](../../.github/workflows/main.yaml)
