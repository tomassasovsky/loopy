---
title: "feat(console): Loop domain — Tempo, Click and Mode under one rail entry"
type: feat
date: 2026-08-06
issue: 518
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #522"
---

> **Retrofit note.** This document was written after the work landed, from
> [#518](https://github.com/tomassasovsky/segno/issues/518), the merged
> [PR #522](https://github.com/tomassasovsky/segno/pull/522) (`ebfdf702c`)
> and the shipped code. It records the intent and the decisions; it did not
> predict them. The pipeline in `docs/TRACKING.md` wants a plan artifact
> between `stage:plan` and `stage:build`, and this slice went from issue to
> branch without one — so the sections below reconstruct what a plan would
> have said, and the "What the build discovered" section records what only
> running it on the device could have told anyone.

## Overview

The reorganized console IA (#498) gives every domain one rail entry, two to
four tabs deep, in place of the twelve-group Settings scroll. This is the
**Loop** slice: everything that governs the loop grid — what the tempo is,
what the click does about it, and which looper mode the tracks obey —
becomes three tabs of one destination.

Built to `segno-ui.pen`'s `LOOP / loop`, `loop-tempo`, `loop-click` and
`loop-mode` screens. Content lifts out of the Settings scroll:
`SettingsSection.tempo` (tempo, signature, quantize, count-in, sync),
`SettingsSection.mode` (the looper-mode section and its change
confirmation), plus the click controls.

Third slice, after Network (#515) and Control (#516 / #517, shipped as
#521). `autonomy:merge-gate` — the direction is settled by #498, but this is
broad-blast-radius console UI and a human merges it.

## Dependencies

- The Control slice, which moved the shared row/card/expansion vocabulary
  into `lib/common/console_surface.dart` and established `PillTabs`. This
  slice reuses both rather than growing a parallel set; it extends
  `console_surface.dart` only where the Loop faces needed something the
  vocabulary did not yet have.
- Stacked on #517 until it landed.
- No engine, repository or protocol dependency. Every value on these faces
  is already owned by something: `TempoCubit` (tempo, signature, quantize,
  count-in, sync, click mode/output/volume), `RecordOptionsCubit` (the loop
  length multiple), `ControlCubit` (the boot default mode), and `LooperBloc`
  for what the rig is actually running.

## Context

The Loop domain is **presentation, not new state**. That is the whole
premise of the slice, and it is what keeps it mergeable on its own: nothing
below the view layer changes.

Two things already existed and must not be re-implemented:

- **The live/configured split.** `TempoCubit` holds *explicitly configured
  intent* — `0` until someone types a tempo, and it does not move when one
  is tapped or derived from the first loop. `LooperBloc`'s `TransportState`
  holds what the rig is running on. `TempoSettingsSection` already
  documented that rule; the new faces have to obey the same one.
- **The looper-mode change rule (D4).** Switching mode with content in the
  session means clear first, wait for the bloc to *report* cleared, then
  dispatch — the clear only posts an engine command, and dispatching before
  the next poll tick races the content lock into a silent no-op.
  `LooperModeSection` owned the only implementation.

Settings stays reachable for now. It can only be deleted once Tracks, Audio
and System have taken the rest of its content, so any rule this slice needs
must be *shared* with the Settings section rather than copied into the tray.

## The shape

1. **Three tabs, not four.** `LoopTrayPanel` carries Tempo, Click and Mode
   over a `PillTabs` strip, with the domain naming itself *above* the strip
   — the same call the Control face made, for the same reason: neither face
   carries a per-tab control that would need a title row to hang on. #518
   read the design's quantize screen as a fourth tab; the build reads it as
   what it actually draws — the console's **pick-one chip dialog**. Quantize
   is a row on Tempo that opens that dialog, and the dialog is now the
   shared control every short-option row on these faces uses.
2. **Two pick-one controls, chosen by the options, not the caller.**
   `showConsoleChipDialog` when the options are few and their names say what
   they are (signature, quantize, count-in, loop length, click when/where);
   `showConsolePickerSheet` when an option needs a line of explanation or
   the list is long (`LOOP / loop-mode-pick`). A chip applies and closes —
   Cancel is the only button, because a dialog with OK would imply the
   choice was not already made.
3. **Live values from the transport, mutations through the cubits.** Every
   value the Loop faces show is read from `LooperBloc`'s `TransportState`;
   every change goes out through `TempoCubit`, `RecordOptionsCubit` or
   `ControlCubit`. The two directions are not interchangeable and the faces
   say so in their doc comments.
4. **Loop length is a multiple, not a bar count.** The mockups draw "Loop
   length · first take sets it · 8 bars"; the app has no bars figure behind
   that setting. What it has is a multiple of the base loop the first take
   defines (Auto / x1 / x2 / x3). The row shows the multiple and keeps
   "first take sets it" as the subtitle only while it reads Auto.
5. **The tempo sheet is the mockups' own** (`LOOP / loop-tempo`): a
   calculator-order pad with Tap and Set on the last row. Tapping goes
   straight to the engine rather than into the field, because a tapped tempo
   is runtime state with nothing to submit — so the sheet reports each tap
   and then mirrors what the engine made of it, which is the only feedback a
   tap pad has. The first keypress replaces the shown tempo rather than
   appending to it. Being a modal route, the sheet is built by the navigator
   and sees nothing the caller's subtree provides, so the bloc is handed
   across explicitly.
6. **The click bar spans the whole gain stage.** `kMaxClickGain` (2.0, the
   engine's `LE_MAX_GAIN`, +6.02 dB above unity) stops being a private
   constant in `tempo_settings_section.dart` and moves onto `tempo_cubit.dart`
   so every click control maps its `0..1` travel onto the same range. The
   readout stays percent-of-unity like the rest of the app, which puts a
   normal click at half the bar and keeps the headroom reachable from the
   console instead of only from the old Settings slider.
7. **Two rules move out of `LooperModeSection` instead of being copied.**
   `requestLooperModeChange` (the D4 sequence, its bounded wait, and the
   timeout SnackBar) and `looperModeLabels` (the name-and-one-liner table)
   land in `lib/looper/view/loop/looper_mode_change.dart`; the Settings
   section now calls them. A second copy of that sequence in the tray would
   be a second chance to get a silent no-op subtly wrong, and two copies of
   the naming table are two chances for the two surfaces to describe the
   same mode differently.
8. **Fix the mockup before building from it.** Two design defects went into
   `segno-ui.pen` first: `LOOP / loop` was drawing the Click tab's cards
   under the Tempo tab's with no caption, and Tempo was the only tab without
   a group caption while Click and Mode had theirs. Building from a wrong
   mockup propagates it.

## Tasks

1. Add `LoopTab` (`lib/looper/loop_tab.dart`) — Flutter-free, like
   `NetworkTab` and `ControlTab`, since the tray cubit stores it and must
   not import a widget library to name a value it holds. Add
   `SettingsTrayDestination.loop`, the `loopTab` field on
   `SettingsTrayState` (kept across navigation, like the others), and
   `showLoopTab` on the cubit.
2. Build `LoopTrayPanel` plus the three faces: `TempoLoopTab`,
   `ClickLoopTab`, `ModeLoopTab`. Route the destination in
   `tray_panel.dart`; give the rail its Loop glyph (a repeat arrow) and
   label.
3. Extract `requestLooperModeChange` and `looperModeLabels`; make
   `LooperModeSection` a caller.
4. Grow `console_surface.dart` only where the faces need it:
   `ConsolePickerOption.subtitle`, and `ConsoleValueBar.resetValue`.
5. Localize everything new in `app_en.arb` and `app_es.arb`.
6. Widget tests per face, goldens for the three faces, and a regeneration
   pass over the control-center goldens the rail change re-baselines.

## What the build discovered

Four defects that no test in this repo would have caught, because each one
was a face that rendered, passed analysis, and was wrong on the hardware.
They are recorded with their root causes because each root cause is
reusable.

**1. Tap tempo looked dead.** The Tempo face read `TempoCubit`'s state. That
cubit holds the *explicitly configured* tempo: `0` until someone types one,
and it never moves for a tapped or loop-derived tempo. So the taps landed,
the engine converged, and the face went on showing the intent. Every live
value now comes off `LooperBloc`'s `TransportState`, and the tempo sheet
mirrors the engine's answer while tapping. The rule was already written down
on `TempoSettingsSection`; the new face simply did not follow it. **Lesson:
a settings cubit in this app is intent, not state — reading one to display
"the current value" is a bug that only shows up for the inputs the user
cannot type.**

**2. The click volume bar drew no fill.** `ConsoleValueBar` put a
`FractionallySizedBox` inside an `Align`, wrapping a childless
`DecoratedBox`. An `Align` hands its child *loose* constraints, and a
childless `DecoratedBox` given a loose height takes zero of it — the fill
was the right width and invisible. The fix drops the `Align` and lets
`FractionallySizedBox` set `widthFactor` **and** `heightFactor: 1`, with a
key on the fill so the geometry can be asserted. **Lesson: the same widget
serves the MIDI mapping editor's LO / HI / THRESH bars, so those were
invisible too. A layout bug in a shared console component is never local —
find the other call sites before deciding on the blast radius.**

**3. `onDoubleTap` would have taxed every single tap.** The bar wants
double-tap-to-default: a bar has no numbers to aim at, so getting back to
unity by dragging is luck. Handing `GestureDetector.onDoubleTap` the job
makes *every* tap wait out the double-tap window before the bar moves — a
third of a second of nothing on a control people drag. So the gesture is
hand-rolled: the first tap applies immediately and opens a
`Timer(kDoubleTapTimeout)`; a second tap while that timer is live cancels
it, fires a selection haptic and overrides with `resetValue`. Drags bypass
the window entirely. The MIDI bars took resets on the same mechanism (LO to
0, HI to 1, THRESH to 64/127). **Lesson: a disambiguating gesture recognizer
charges its latency to the common path, not the rare one.**

**4. The one-shot switch read ON for an empty session.** The rig-wide switch
is "every track is one-shot", and `every` on an empty list returns true — so
a session with nothing in it showed the switch on. Guarded with
`tracks.isNotEmpty &&`. The same row was also captioned with a group label
rather than its own title, and got one. **Lesson: any `every`/`all` driving
a UI affordance needs its empty case decided explicitly, because the
vacuous-truth answer is almost never the one the surface means.**

A fifth thing was not a defect but read as one: the looper-mode picker
listed five bare names. "Multi" and "Band" are labels for what the looper does, and a
picker of five of them asks the user to already know the answer. Hence
`ConsolePickerOption.subtitle`, carrying the same one-liner the face shows
under the current value.

## Scope this slice absorbed

The navigation rail was rebuilt to the mockups' geometry inside this PR: a
180px spine (was 165), 46px pills at 11px radius (was a 24px-radius shape
sized by padding), 22px glyphs (was 20), 17px captions (was 14, and now
semibold when selected), an item pitch of 5px inside a 10/19/11 inset, a
full-strength `line` border instead of one at alpha 0.4, and — the change
that matters most — an **accent-surface fill** on the selected entry instead
of the accent at alpha 0.18, which read as a hover state rather than "this
is the panel you are on". The cross-face `AnimatedSwitcher` in
`tray_panel.dart` was dropped in the same commit, with no note in the issue
or the PR body.

None of that is Loop work. It is rail work, it applies to every domain, it
invalidated eight existing control-center goldens that have nothing to do
with this face, and it made the Loop diff larger than the Loop faces. It
belongs to the rail's own slice — the last one in #498, which already owns
the tray home face and the "Controls" versus "Control" label clash.

**This is exactly what a `stage:plan-review` pass exists to catch**, and it
went uncaught because this slice never had one. The cost was not a bug; it
was a review surface that mixes "did the Loop faces come out right" with
"is the rail geometry right for all eight domains", and a golden diff that
cannot be read as one question. Record it as the reason the pipeline has
that stage, not as a thing to undo.

## Testing

- The standard verify loop from `CLAUDE.md`: `flutter test` (absolute path),
  `dart analyze` clean, and the native engine suite. Firmware untouched, so
  the pedal gate does not apply. PR #522 reports 1517 tests passing, analysis
  clean and the native suite `ALL PASSED`.
- `test/looper/view/loop/loop_faces_test.dart` covers each fix with an
  assertion that fails when the fix is reverted: the live engine tempo
  rather than the persisted intent; the fill's width *and* height against
  the bar's; a drag at the right edge mapping onto the full gain range; a
  double tap snapping the click back to unity; the chip dialog applying and
  closing; the tempo sheet showing what the engine made of a tap, and typing
  winning the field back from it; the mode picker carrying a subtitle per
  option.
- That suite pumps at 1920x1080. The console face is drawn for that surface
  and the default 800x600 test view pushes rows below the fold, where a tap
  lands on nothing.
- Goldens: three new control-center faces (Loop tempo / click / mode), plus
  every control-center golden the rail change invalidates, regenerated and
  eyeballed. The screenshot suite self-skips off an absolute font path, so
  this is a deliberate author-machine step and never CI.

## Exit criteria

- Loop is a rail destination with three working tabs, and the tab survives
  navigating away and back.
- No Loop face displays a value read from a settings cubit.
- One implementation of the mode-change rule and one mode naming table,
  called by both the Settings section and the console face.
- Every value bar in the app draws a visible fill, including the MIDI ones.
- `dart analyze` clean; Dart and native suites green; goldens regenerated
  and looked at.

## Non-goals

- **No new state, engine or protocol work.** Every face is a
  re-presentation of state something already owned.
- **Settings is not deleted.** It stays reachable until Tracks, Audio and
  System have taken the rest of its content.
- **The tray home face stays**, and so does the "Controls" versus "Control"
  rail-label clash — both resolve in the last #498 slice, where the mockups
  drop the home face entirely and brightness becomes its own rail entry.
- **The mockups' Signal / Tracks / Audio / System rail entries and the
  bottom-pinned Bright control are not built here.** A rail entry is never empty;
  each arrives with its own slice.
- No pedal plate or faceplate work, and no restyle of anything outside the
  Loop faces and the rail.
