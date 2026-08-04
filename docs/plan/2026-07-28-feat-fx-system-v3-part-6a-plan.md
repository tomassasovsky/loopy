---
title: "refactor(pedal): extract presentational pedal plate widget"
type: refactor
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Sonnet at medium effort · `autonomy:auto` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Extract the pedal plate presentation out of `lib/pedal/view/pedal_faceplate.dart`
into a pure presentational widget, per the parent plan's Part 6 "faceplate
extraction first" decision [R22]. Today `PedalFaceplate` fuses the simulator
transport wiring with the plate rendering (`_TopPlate`, `_Footswitch`, LEDs,
mm-to-px layout); Part 6 proper (binding/assignment UI) needs the plate as a
reusable, frame-driven widget. This part is a behavior-identical refactor —
no new features, no wire or state changes.

## Dependencies

None — this part merges first; Part 6 proper
(`2026-07-28-feat-fx-system-v3-part-6-plan.md`, pedal remap + momentary)
builds on it.

## Context

- `lib/pedal/view/pedal_faceplate.dart` — the whole surface lives in one file:
  - `PedalFaceplate` (line 58): stateful wrapper; grabs
    `SimulatorPedalTransport` in `didChangeDependencies` (line 84), calls
    `_sim.releaseAll()` on `deactivate()` (line 89), and gates rendering on
    `PedalCubit.state.boundOutputId == kSimulatorOutputId` (lines 99–102) —
    otherwise it renders `mainScreen ?? TracksView` full-screen.
  - `_TopPlate` (line 132): mm-to-px layout via `LayoutBuilder` scale against
    the Segno faceplate constants (`_fpW`/`_fpV` etc., lines 25–48); takes
    `sim`, `frame`, `l10n`, `mainScreen`, `waveformScreen`.
  - `_Footswitch` (line 603): already takes `onPress` (wired to `sim.press`),
    `led`, `channel` — the natural presentational seam.
  - Supporting presentation: `_Led`, `_BlinkingLed`, `_Encoder`,
    `_LedRingPainter`, `_SilkLabel`/`_SilkLabelPainter`, `_ScreenBezel`,
    `_ScreenWaveform`.
- Parent-plan bullet lifted verbatim (Part 6, [R22]): extract the plate
  presentation (`_TopPlate` + `_Footswitch` + LEDs + mm-to-px layout) into a
  presentational widget taking an injected `PedalStateFrame`, `onPress`
  callback, and per-button selection state — **API free of pixel params
  (mm-to-px stays internal)** [VGV]; the simulator wrapper keeps the
  transport wiring. Simulator screenshot goldens regen + eyeball.
- [VGV] constraints: extract real widget classes (no `_build` methods), no
  pixel/geometry params in the public API, theme via `LooperTheme`/
  `SurfaceTheme` tokens only.
- Existing tests: `test/pedal/view/pedal_faceplate_test.dart` (plus
  `test/pedal/cubit`, `test/pedal/helpers`) must keep passing unchanged.
- Screenshot goldens live in `test/screenshots/` (author-machine-only
  runner); no pedal-plate-specific golden exists today — see Tasks.

## Tasks

- [ ] Create the presentational widget (suggested: `PedalPlate` in
      `lib/pedal/view/pedal_plate.dart`) rendering the full plate from
      injected inputs only:
  - [ ] `PedalStateFrame frame` (LEDs, ring, bank — everything `_TopPlate`
        reads from the frame today)
  - [ ] `onPress` callback with the same signature `_Footswitch` dispatches
        today (`sim.press`), covering press and release
  - [ ] per-button selection state (e.g. a `Set<PedalButton>`-shaped
        highlight input; empty = today's rendering) — consumed by Part 6's
        assignment screen, passed empty by the simulator wrapper
  - [ ] screen-aperture children (`mainScreen`, `waveformScreen`) as plain
        widget params
  - [ ] **no pixel params in the API** — the mm constants and
        `LayoutBuilder` mm-to-px scaling move inside as private
        implementation [VGV]
- [ ] Move `_TopPlate`, `_Footswitch`, `_Led`, `_BlinkingLed`, `_Encoder`,
      `_LedRingPainter`, `_SilkLabel`/`_SilkLabelPainter`, `_ScreenBezel`
      (and the mm geometry constants) behind the new widget; they must not
      reference `SimulatorPedalTransport`, `PedalCubit`, or `ControlCubit`
- [ ] Reduce `PedalFaceplate` to the simulator wrapper: keep the
      `boundOutputId == kSimulatorOutputId` gate, the
      `SimulatorPedalTransport` lookup, `releaseAll()` on deactivate, the
      `ValueListenableBuilder` on `_sim.frame`, and the
      `LooperScreenTheme`/`SafeArea` chrome — delegating rendering to the
      new widget with `onPress: sim.press` and empty selection
- [ ] Keep `_ScreenWaveform` (live-output dependency) on the wrapper side as
      the default `waveformScreen`
- [ ] Tests: existing `test/pedal/view/pedal_faceplate_test.dart` passes
      unchanged (behavior-identical proof); add direct widget tests for the
      new widget — frame drives LED rendering, `onPress` fires with the
      pressed button, selection state renders, no transport/bloc providers
      required to pump it
- [ ] Screenshot goldens (author-machine-only): run the `test/screenshots`
      suite, regen + eyeball — expected pixel-identical. No pedal-plate
      golden exists today; do not add one here (Part 6 may)

## Success Criteria

```success-criteria
GOAL: The pedal plate renders from injected state alone; the simulator wrapper is a thin shell; zero behavior change.

SUCCESS CRITERIA:
- Presentational widget pumps standalone (frame + onPress + selection; no transport/cubit providers, no pixel params in its API) with direct widget tests | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal
- Existing faceplate/simulator behavior identical: bound-output gate, releaseAll on deactivate, press dispatch — pre-existing pedal tests pass unmodified | verify: /Users/Tomas/development/flutter/bin/flutter test test/pedal

NON-GOALS:
- Binding model, assignment screen, momentary behavior, stomp/LED chips (Part 6 proper)
- InteractionMode.fx, protocol v3, on-pedal mode indicator (Part 5)
- Any visual redesign or new golden coverage of the plate

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/pedal
```

## Notes

- **Goldens are author-machine-only** (`test/screenshots` skips elsewhere —
  fonts); regen + eyeball locally, expect no diffs from this refactor.
- **Before opening the PR:** check the cspell dictionary (faceplate/silk/
  footswitch vocabulary is already in it; anything new must be added) and
  the semantic PR title (`refactor(pedal): ...`).
- **Stacked-PR squash landmines:** this part has no parent, but Part 6
  stacks on it — squash-merge breaks child merge-refs (CI silently absent)
  and API branch-delete closes children; rebase the child onto master after
  this lands.
- No native surface touched — ffigen regen + `dart format` not applicable.
- The test-runner gotcha applies: use the absolute flutter path
  (`/Users/Tomas/development/flutter/bin/flutter`); the very_good MCP test
  runner is broken in this repo.
