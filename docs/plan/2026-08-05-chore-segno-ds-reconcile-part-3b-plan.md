---
title: "feat(visualizer): colour the waveform by transport state"
type: feat
date: 2026-08-05
issue: 499
parent-plan: 2026-08-05-chore-segno-ds-reconcile-plan.md
---

> **Session setup:** Opus at medium effort · `autonomy:merge-gate` — this is the most visible single change in the reskin, so "the tests pass" is not the bar. Read the parent plan's stage list before starting.

## Overview

The waveform is drawn in one fixed cyan regardless of what the track is
doing. The design system draws it in the transport-state colours the rest of
the stage already uses — so the waveform stops being decoration and becomes
part of the same legend as the track block, the meter and the pedal LEDs.

This is slice **3b** of stage 3, and the one item in the parent plan's
reconciliation table that was flagged as an explicit human veto point. The
veto was resolved in favour of the design system: state-coloured wins.

It is first in the stage because it is the only slice with no open direction
call and no overlap with epic #442.

## Dependencies

- Stages 0–2 of the parent plan: merged (#501, #502, #503).
- No dependency on any #442 part, and none of them on this. Confirm that is
  still true before starting — #442's status table moves.

## Context

`LooperTheme` carries `waveformColor` as a single colour with a
high-contrast counterpart. That is the shape that has to change: one colour
becomes a per-state lookup, the way the meter and indicator tables in
`app_theme.dart` already work. Those tables are the precedent to copy —
including how they handle the muted case, which overlays every other state.

The state vocabulary already exists and should not be re-invented; find it
rather than inventing a parallel enum. The stage colours themselves are
already tokens and are already agreed between the design and the code — this
slice changes *which* colour is chosen, not what the colours are.

Scope is small and worth confirming early: the theme fields have effectively
one widget consuming them. If your survey finds materially more than that,
stop and re-scope — it means something changed since this was written.

`waveformBackground` is a neutral that re-tints with the ramp, not a state
colour. Leave its role alone.

## Tasks

1. Establish the current shape: who defines the waveform colours, who reads
   them, and which existing state enum the visualizer can key off.
2. Change the `LooperTheme` contract from a single colour to per-state
   colouring, with a high-contrast counterpart for each state. Follow the
   existing meter/indicator table precedent rather than a new mechanism.
3. Update the consumer(s) to resolve colour from the track's state.
4. Extend `test/theme/` with the relational floors for the new colours. That
   file is deliberately hex-literal-free — keep it that way; assert contrast
   relationships, not values.
5. Regenerate and eyeball the affected goldens.

## Testing

- Standard verify loop from `CLAUDE.md`.
- The theme tests must cover every new state colour in both variants. The
  high-contrast set encodes legibility decisions, not hue preference — a new
  state colour that only passes in the dark variant is not done.
- Goldens: at least the tracks and settings-tracks views render a waveform.
  The screenshot suite self-skips off an absolute path and rots silently, so
  regenerate deliberately and look at the images — a diff that changes
  *layout* is a bug, not a reskin.

## Exit criteria

- No caller can ask for "the waveform colour" without saying for what state.
- Both theme variants complete; no state falls back to a default colour.
- Golden diffs are colour-only and were eyeballed, not rubber-stamped.
- `dart analyze` clean; full suite and native tests green.

## Non-goals

- No change to the stage colour values themselves — they are already agreed.
- No FX rack or parameter work; that is 3a, and it collides with #442 part 4.
- No layout or IA change of any kind. If this slice starts moving a widget
  rather than recolouring one, it has crossed into #442 and should stop.
- `waveformBackground` keeps its role as a neutral.
