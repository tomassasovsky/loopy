---
title: "feat: performance recording — part 12: pedal firmware parity"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 12: pedal firmware parity — Standard

> **Split note:** part 12 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). The
> user-locked D-PEDAL scope: full Loopy-pedal parity via a **firmware
> wire-contract extension** — sequenced last so the rest of the stack never
> couples to a firmware release.

## Overview

Both pedal contracts are frozen firmware wire formats and both change here:
`PedalButton` gains a `perfRecord` value on the next free MIDI note
([pedal_button.dart:9](../../packages/pedal_repository/lib/src/pedal_button.dart)
— note == index today; the new entry appends), and `PedalStateFrame` gains an
armed-LED field so the performer gets eyes-free state. The armed indication
is **blinking red**, distinct from the looper's solid record red
(`GlobalColor.red` already means looper-recording). Failure auto-stops
(disk full, device change) must reach the LED, not just a SnackBar.

## Context / findings

- **Intent path:** `ControlCubit` gains a `PerformanceRepository` constructor
  dependency; `_onPress`
  ([control_cubit.dart:493](../../lib/control/cubit/control_cubit.dart))
  dispatches `PedalButton.perfRecord` → `togglePerformanceRecord()`, which
  calls the repository (cubits never call cubits; the part 11 cubit observes
  the same repository state).
- **D-CLEAR orchestration lands here too:** `ControlCubit` is the single
  clear path — when armed, `_onClear`/`clearAll` awaits
  `performanceRepository.persistLiveLanes()` before issuing the engine
  clear (skip-capturing rule inside the repository).
- **LED projection:** `projectFrame()`/`control_projection.dart` derives the
  blinking-red field from repository armed state; failure auto-stops drop the
  armed LED (and the state change is what the performer sees).
- **Codec + fixtures:** `PedalCodec` handles the new note + frame field;
  golden `.syx` fixtures regenerate
  (`packages/pedal_repository/test/pedal_codec_golden_test.dart` precedent).
- **Faceplate:** on-screen `PedalFaceplate` gains the footswitch
  ([pedal_faceplate.dart:280–325](../../lib/pedal/view/pedal_faceplate.dart)),
  so the simulator has parity before hardware ships.
- **Firmware:** the `firmware/` tree implements the new note + LED field;
  the wire-contract addendum is documented there. App-side degrades
  gracefully against old firmware (unknown frame field ignored; button
  simply absent).
- Double-press guard (1 s) applies to the pedal path identically (it lives
  in the repository arm/disarm, part 6/11 — verify, don't duplicate).

## Acceptance Criteria

- [ ] `PedalButton.perfRecord` on the next free note; codec decodes the
      press; `ControlCubit` toggles arm via the repository (`bloc_test`).
- [ ] `PedalStateFrame` carries the armed field; blinking red projected while
      armed; distinct from looper-record red; dropped on failure auto-stop
      (projection tests).
- [ ] Golden `.syx` fixtures updated and passing; old-firmware frames still
      decode (back-compat test).
- [ ] Clear-while-armed awaits `persistLiveLanes()` before the engine clear
      (ordering `bloc_test`).
- [ ] On-screen faceplate footswitch arms/disarms and shows the armed LED
      (widget test).
- [ ] Firmware addendum committed under `firmware/` docs; app degrades
      gracefully against old firmware.
- [ ] `flutter analyze` clean; format stable; `pedal_repository` + control
      suites green.
- [ ] Manual: arm via hardware/simulated pedal with the screen hidden,
      confirm LED, disarm, confirm bundle exists.

## Tasks

- [ ] `packages/pedal_repository/lib/src/{pedal_button.dart,pedal_codec.dart,pedal_state_frame.dart}` —
      new note + frame field; golden fixtures.
- [ ] `lib/control/cubit/control_cubit.dart` — repository dep,
      `togglePerformanceRecord()`, `_onPress` case, D-CLEAR ordering;
      `lib/control/control_projection.dart` — LED field.
- [ ] `lib/pedal/view/pedal_faceplate.dart` — footswitch + LED.
- [ ] `firmware/` — note + LED implementation + wire-contract addendum.
- [ ] Tests: codec goldens, projection, `bloc_test` (toggle + clear
      ordering), faceplate widget test, old-firmware back-compat.

## Files touched (primary)

`packages/pedal_repository/lib/src/*`, `packages/pedal_repository/test/*`,
`lib/control/cubit/control_cubit.dart`, `lib/control/control_projection.dart`,
`lib/pedal/view/pedal_faceplate.dart`, `test/control/*`, `test/pedal/*`,
`firmware/*`.

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.
2. `flutter test packages/pedal_repository test/control test/pedal` — green.
3. Manual: eyes-free pedal arm/disarm flow (checklist in PR).

## Dependencies

- **Part 11** (repository + cubit + UI in place; this part adds the pedal
  surface on top).
