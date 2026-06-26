---
title: "feat: RPi console — Part 1: ARM64 CI + kiosk-target/compositor spike"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 1: ARM64 CI + kiosk-target/compositor spike - Standard

> Part 1 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md). Source brainstorm: [`docs/brainstorm/2026-06-26-raspberry-pi-console-brainstorm-doc.md`](../brainstorm/2026-06-26-raspberry-pi-console-brainstorm-doc.md).

## Dependencies

- **None — this PR must merge first.** Its kiosk-target/compositor decision is a precondition for Parts 5–7 (dual-display) and informs how Part 2's wiring is validated on-device.

## Overview

Add an ARM64 Linux build guard to CI and resolve the single highest-risk question of the whole effort **before any other code is written**: which kiosk rendering target + Wayland compositor the console uses. The waveform second-window design ([`WaveformWindowService`](../../lib/visualizer/waveform_window_service.dart:29) via `desktop_multi_window`) assumes a desktop GTK environment; if `flutter-pi` (lighter/faster) breaks the second window, GTK-on-Wayland wins. The compositor must also expose `wlr-output-management` for the deterministic display pinning Part 5 depends on — Pi OS's default compositor (Wayfire) is **not** wlr-based, so the compositor must be selected here, not assumed.

## Problem Statement

The repo builds Linux x86_64 (compile-only) but has **no ARM64 job** ([`.github/workflows/main.yaml`](../../.github/workflows/main.yaml) `build-linux`). There's also no validated answer to the kiosk-target fork or the compositor choice, both of which can invalidate the dual-display product design. Bundling these into a later PR risks redoing display work after panels arrive.

## Technical Approach

### Tasks

- [ ] Add a `build-linux-arm64` job to [`.github/workflows/main.yaml`](../../.github/workflows/main.yaml) mirroring `build-linux` (GTK deps: `ninja-build libgtk-3-dev libglib2.0-dev libpango1.0-dev libasound2-dev clang cmake pkg-config`). Use `FLUTTER_TARGET_PLATFORM_SYSROOT` (the root [`linux/CMakeLists.txt:20`](../../linux/CMakeLists.txt) already honors it) or an ARM runner. Compile-only (no audio in CI), `--target lib/main_development.dart`.
- [ ] **On-device bring-up spike:** boot Pi OS on a Pi 5, run a hand-built ARM64 Loopy bundle, confirm the Skia renderer path ([`linux/runner/main.cc:15`](../../linux/runner/main.cc)) renders Material icons correctly (not "tofu").
- [ ] **Kiosk-target spike:** GTK-on-Wayland vs `flutter-pi`. Confirm whether `desktop_multi_window` + `window_manager` open and control the waveform second window under the candidate target. Record the decision.
- [ ] **Compositor selection:** pick a concrete compositor (e.g. `labwc` or `sway`, both wlr-based) and confirm it exposes `wlr-output-management` / `wlr-randr` for Part 5's output-name pinning. Record the choice.
- [ ] Create `docs/RUNNING_ON_RPI.md` with the bring-up steps + the recorded kiosk-target and compositor decisions.

### Mock files

- `.github/workflows/main.yaml` (modified — new `build-linux-arm64` job)
- `docs/RUNNING_ON_RPI.md` (new)

## Acceptance Criteria

### Functional

- [ ] `build-linux-arm64` CI job is green (ARM64 bundle compiles).
- [ ] An ARM64 Loopy bundle launches full-screen on a Pi 5 with correct Material icons.
- [ ] The waveform second window opens and is controllable on the chosen kiosk target.
- [ ] The chosen compositor exposes `wlr-output-management` (verified with `wlr-randr`).

### Quality Gates

- [ ] `docs/RUNNING_ON_RPI.md` records the kiosk-target and compositor decisions with rationale.
- [ ] Existing CI jobs remain green (additive change).

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| `flutter-pi` breaks `desktop_multi_window` | High | Default to GTK-on-Wayland unless the spike proves flutter-pi works. |
| Chosen compositor lacks `wlr-output-management` | High | Select labwc/sway (wlr-based) rather than Pi OS default Wayfire. |
| ARM64 cross-build toolchain gaps | Medium | Use `FLUTTER_TARGET_PLATFORM_SYSROOT`; fall back to ARM native runner. |

## References

- CI: [`.github/workflows/main.yaml`](../../.github/workflows/main.yaml) (`build-linux` job to mirror)
- Cross-build sysroot: [`linux/CMakeLists.txt:20`](../../linux/CMakeLists.txt)
- Skia force: [`linux/runner/main.cc:15`](../../linux/runner/main.cc)
- Second window: [`lib/visualizer/waveform_window_service.dart:29`](../../lib/visualizer/waveform_window_service.dart)
- Audio setup: [`docs/RUNNING_ON_LINUX.md`](../../docs/RUNNING_ON_LINUX.md)
