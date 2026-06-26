---
title: "feat: RPi console — Part 7: foot-only audio recovery + fault surfacing"
type: feat
date: 2026-06-26
---

## feat: RPi console — Part 7: foot-only audio recovery + fault surfacing - Standard

> Part 7 of 8. Umbrella plan: [`2026-06-26-feat-raspberry-pi-floor-console-plan.md`](2026-06-26-feat-raspberry-pi-floor-console-plan.md).

## Dependencies

- **Part 6** (builds on the supervised/persisted appliance) and **Part 4** (fault surfacing uses the LED health channel).

## Overview

Close the appliance-grade UX gaps so the unit recovers from audio device loss without a pointer, auto-starts on boot, and surfaces the failure modes that actually block a performance. The engine already detects USB-interface loss (`device_present` flips, `isConnected` derived in Dart); today recovery requires **tapping** the touch-only `_AudioNotRunningBanner` ([`big_picture_view.dart:438`](../../lib/looper/view/big_picture_view.dart)). This part adds automatic recovery and non-pointer fault signals.

## Problem Statement

On a console mid-set, kicking the USB cable strands the unit with no foot path back to running audio. On first boot with no prior selection there is nothing to auto-select. And most failure modes (no GPIO mapping, LED driver dead, second window failed, device loss) only surface through touch-driven banners — wrong for a foot-only instrument.

> **Scope notes (per review):** (1) the **foot-only long-press retry combo is dropped** — it would need a long-press concept the press-only pipeline lacks; auto-restart-on-reconnect covers the common case, and a touch tap on the existing banner covers the rest. (2) **Thermal-throttle warning is deferred to Future Considerations** — the Part-8 soak gate validates throttle doesn't occur; an in-app warning for a must-not-occur condition is a follow-up. Fault surfacing here is scoped to the **performance-blocking** modes.

## Technical Approach

### Architecture guardrail

Recovery logic (auto-reselect/restart reacting to `device_present`) lives in a **bloc/cubit**, not the widget. `_AudioNotRunningBanner` / [`big_picture_view.dart`](../../lib/looper/view/big_picture_view.dart) only render state and dispatch events. New visual states use `LooperTheme` ThemeExtension tokens and extracted widget classes (not `_build` methods), per VGV standards.

### Tasks

- [ ] **Audio auto-restart:** on USB-interface reconnect (known device reappears), auto-reselect + restart the engine — no pointer. Driven by a cubit reacting to the engine's `device_present` / `isConnected` state.
- [ ] **Auto-select on boot:** persist the selected device; if present at boot, auto-start the engine (no banner/tap).
- [ ] **Non-pointer fault surfacing (scoped):** performance-blocking modes get an operator-visible signal (screen + LED pattern via Part 4's channel): (a) audio device not present at boot, (b) engine stopped unexpectedly, (c) LED driver absent, (d) no GPIO mapping configured, (e) second window failed (from Part 5).

### Mock files

- `lib/looper/cubit/` audio-recovery cubit (new — auto-reselect/restart logic)
- `lib/looper/view/big_picture_view.dart` (modified — render recovery state, dispatch only)
- Persisted-device load/save via the existing `SettingsRepository` (modified)
- Corresponding `*_test.dart` for the recovery cubit (bloc_test + mocktail)

## Acceptance Criteria

### Functional

- [ ] Kick the USB cable mid-set → visible state + **automatic recovery** when the known device reappears, no touch.
- [ ] Boot with the known device present → audio runs with zero interaction.
- [ ] Each scoped failure mode shows a non-pointer (screen + LED) operator signal.

### Quality Gates

- [ ] Recovery cubit unit-tested (success/failure/reconnect paths) — CI 90% gate.
- [ ] No business logic in the widget (VGV architecture review passes); ThemeExtension tokens for new visual states.

## References

- Device-loss banner (touch-only today): [`big_picture_view.dart:438`](../../lib/looper/view/big_picture_view.dart)
- Engine device-present detection: `packages/loopy_engine/src/core/engine_miniaudio.c` (`device_present`)
- LED fault channel: Part 4
- VGV standards: ThemeExtension `LooperTheme`, extracted widget classes, no logic in UI
