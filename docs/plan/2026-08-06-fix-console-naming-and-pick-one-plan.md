---
title: "fix(console): name things by their name, and draw pick-one the way it was drawn"
type: fix
date: 2026-08-06
issue: 526
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #531 (carries both #526 and #527; replaces #524)"
---

> **Retrofit note.** This document was written after the work merged, from
> [#526](https://github.com/tomassasovsky/segno/issues/526),
> [#527](https://github.com/tomassasovsky/segno/issues/527), the merged PR and
> the shipped code. It records the intent and the decisions; it did not predict
> them. Nothing here is a forecast — where it reads like a plan, that is the
> house format, not a claim that the plan existed first. The one thing it is
> genuinely for is the rule in "The rule that follows", which later console
> slices are expected to obey.

## Overview

Two corrections that were not domain-shaped. The console IA
([#498](https://github.com/tomassasovsky/segno/issues/498)) is being landed one
rail entry at a time — Control, Loop, Tracks, Audio, System — and each of those
slices owns one face. These two owned none of them: they cut across every face,
and both were found while building Tracks.

- **[#526](https://github.com/tomassasovsky/segno/issues/526) — a track is
  called what it is called.** A rig named `drums / bass / rhythm / lead` read
  `Track 1 … Track 4` the moment you left the stage: in the pedal-assignment
  target list, in the MIDI-learn targets, in the FX editor's bus title, in the
  rename dialog, in the pedal plate's accessible labels, and in the console's own
  per-track routing panel. The fix is one resolver on the l10n extension,
  threaded into the label functions that were formatting ordinals by hand.
- **[#527](https://github.com/tomassasovsky/segno/issues/527) — pick-one is a
  chip dialog.** The console's pick-one control had already been drawn, in
  `LOOP / loop-quantise`. A different control — a bottom sheet of rows — was
  built instead, from the row vocabulary, without anyone reading that screen, and
  it had reached twelve call sites before the mismatch was noticed. Also here:
  the empty and undrawn states the mockups omitted and the faces needed anyway.

Both carried `area:console`, `priority:P1`, `autonomy:merge-gate`.

## How it shipped

Both landed inside the Tracks domain branch and merged to `master` as
**PR [#531](https://github.com/tomassasovsky/segno/pull/531)**, squashed into
`f08c54b5` on 2026-08-06. Its body closes `#523`, `#526` and `#527` together.

Two wrinkles worth recording, because the numbering is confusing from the
outside:

- **#531 replaces [#524](https://github.com/tomassasovsky/segno/pull/524).** The
  same commits were first opened as #524, stacked on the Loop branch; GitHub
  recorded #524 as merged when it landed into that already-merged base rather
  than into `master`, and a merged PR cannot be reopened. #531 is the same work
  rebased onto `master`. The Audio slice hit the same trap immediately after
  (#529 → [#534](https://github.com/tomassasovsky/segno/pull/534)).
- **The two fixes are separate commits on that branch**, and reading them is the
  fastest way to see what each one actually did:
  `65b1b1d4` *fix(ui): name tracks by their name, not their number* and
  `3b9c0006` *fix(console): pick-one is a chip dialog, and the states nobody
  drew*. Neither is an ancestor of `master` — the branch was squashed — so
  `git show` them by hash rather than looking for them in the trunk history.

## #526 — name things by their name

### What was wrong

`AppLocalizations.displayTrackName(name, channel)` already existed and was
already correct. It had three consumers: the Signal page, the stage tiles and the
meters. Two of those files carried their own copy of the same private wrapper
around it:

```dart
String _trackLabel(AppLocalizations l10n, int track) =>
    track < trackNames.length
    ? l10n.displayTrackName(trackNames[track], track)
    : l10n.trackNumberLabel(track + 1);
```

— identical in `signal_panes.dart` and `signal_row_views.dart`. Every other
surface skipped the whole question and formatted an ordinal into an ARB string:
`trackSettingsTitle`, `renameTrackTitle`, `fxEditorTrackTitle`,
`midiLearnTargetVolume`, `pedalAssignStageTrack`, `pedalSimTrackSemantics`.

Buried in that: the pedal-assignment and MIDI-learn labels passed the **raw
channel** into a `Track {n}` string, so a binding on the rig's second track read
"Track 1" while every other surface called the same track TRACK 2. The
off-by-one was not the reported bug; it fell out of threading the resolver
through, and the tests that had encoded it were corrected.

### What shipped

One resolver, in [`lib/l10n/localized.dart`](../../lib/l10n/localized.dart):

```dart
String trackName(List<String> names, int channel) =>
    channel >= 0 && channel < names.length
    ? displayTrackName(names[channel], channel)
    : trackNumberLabel(channel + 1);
```

and every surface that identifies a track now goes through it. The duplicated
private wrappers collapse to a one-line delegation. Six ARB strings that
formatted an ordinal are replaced by six that take a name —
`trackSettingsNamedTitle`, `renameTrackNamedTitle`, `fxEditorTrackNamedTitle`,
`trackVolumeNamedTarget`, `trackLaneNamedTarget`, `trackStateNamedSemantics` —
in both `app_en.arb` and `app_es.arb`. Three of the ordinal-only keys they
replace — `trackSettingsTitle`, `trackSettingsDialogTitle` and
`trackRoutingSubtitle` — were deleted rather than left as a second way to say
the same thing. The other five (`renameTrackTitle`, `fxEditorTrackTitle`,
`midiLearnTargetVolume`, `pedalAssignStageTrack`, `pedalSimTrackSemantics`) lost
their last consumer but are still in both ARB files; on `master` today nothing
under `lib/` reads them.

The label functions in
[`lib/control/binding/binding_labels.dart`](../../lib/control/binding/binding_labels.dart)
— `fxStageLabel`, `bindingTargetLabel`, `valueTargetLabel` — take
`List<String> trackNames = const []` as an optional named parameter. The default
is the old behaviour: a caller with no names to hand still gets the ordinal.
`FxScope.label` gained the same parameter, and the scopes that name an input or
a lane ignore it.

Three consequences that are easy to miss and were handled deliberately:

- **Naming is state, so the surfaces that name need the state.** Every surface
  that now shows a name reads `TracksCubit`. `showPedalAssignmentPage` re-provides
  it across the route it pushes, because a pushed route inherits nothing.
- **`read`, not `watch`, inside a `PopupMenuButton.itemBuilder`** — the builder
  runs outside `build`, and that is called out in a comment at both MIDI call
  sites rather than left to be rediscovered.
- **The routing panel keeps the ordinal, underneath.** The title is the name; the
  line below it is `track N`, which still says which pad on the pedal this is.
  The mockups were corrected to match, rather than the code being bent to a
  mockup that led with the number.

### What deliberately stayed positional

`pedalButtonTrack` — the footswitch labels. Those name the physical switch under
your foot, and which track it drives depends on the bank. A name there would be
wrong half the time.

## The resolvers — why this belongs in l10n

The alternative was the status quo: each call site formats its own label. That is
exactly what produced the bug, and it produced it three different ways at once —
a surface that never consulted the names at all, a surface that consulted them
through its own private copy of the lookup, and a surface that consulted the
wrong number. Three call sites, three answers to one question.

A resolver on the l10n extension fixes the shape rather than the instances:

- **The bounds check and the fallback exist once.** "Channel outside the names
  list" is the case every hand-rolled wrapper had to get right; now nobody writes
  it. The off-by-one could not have survived this shape, because there is no
  place left to pass a raw channel into a `Track {n}` string.
- **It is the natural home.** The answer is localized — the fallback is
  `defaultTrackName`, an ARB string — so the resolver has to sit where the
  localizations are, and `EngineLocalizations` is already the extension that
  turns engine values into words (`trackStateLabel`, `effectTypeLabel`,
  `loopbackKindLabel`). It is one more of those.
- **It makes the rule enforceable.** "Every surface that identifies a track goes
  through here" is a sentence you can check by grep. "Every surface formats its
  label correctly" is not.

### `inputName`, and what "lane index is identity" means

**Correction to the brief:** `l10n.inputName(names, input)` is *not* part of
#526. It arrived later, in the Audio slice
(PR [#534](https://github.com/tomassasovsky/segno/pull/534), closing #528), which
added the capability of naming hardware inputs at all — an `input_name.$i` key, a
small `InputsCubit`, and the resolver. It is included here because it is the same
decision applied a second time, and that is the evidence the shape was right: the
input-side twin was written as a resolver without anyone re-arguing it, and the
Tracks routing summary and per-track lane list picked it up immediately, so a
lane reads `mic` rather than `In 2`.

`inputName` resolves a **socket**, not a row:

```dart
String inputName(List<String> names, int input) {
  final given = input >= 0 && input < names.length ? names[input] : '';
  return given.isEmpty ? inputChannelLabel(input + 1) : given;
}
```

That matters because of the routing model #531 landed underneath it. A track
records any set of inputs, one dry lane each: checking an input gives the track a
lane for it, unchecking frees that lane, and **lane index is identity** — nothing
renumbers. Dropping an input sets its own lane to record nothing and leaves it
there; adding one reuses a freed lane before growing the track. Rebuilding the
list as "sorted inputs, one per index" would move a take from one source to
another whenever an input was added in the middle.

The naming has to obey the same rule. The name is keyed on the input's own index
and kept per socket up to the engine's ceiling, so it stays attached to the
socket across a lane being freed and refilled, and across swapping interfaces and
back. A name resolved from a row's position in a list would follow the position,
not the source — the display equivalent of the renumbering the lane model exists
to prevent.

## #527 — pick-one was already drawn

### What happened

`LOOP / loop-quantise` had specified the console's pick-one control before any of
it was built: a centred 744px dialog, a title, one line of explanation, a row of
equal-width chips with the current one in the accent surface, and a right-aligned
Cancel. Tapping a chip applies and closes.

`showConsolePickerSheet` was built instead — a bottom sheet of the console's 70px
rows — reasoned from the row vocabulary that the rest of the tray uses. It is a
defensible control; it is not the control that was drawn. By the time anyone
compared it to the screen, it was behind twelve call sites across the Control,
Loop and Tracks faces.

This is the single best argument in the whole console IA for the plan stage, and
worth stating plainly rather than dramatically. Nothing here was carelessness:
the sheet was built from a real convention, it worked, its tests passed, and it
reviewed clean. The mistake was upstream of all of that — the screen that already
answered the question was never opened. And the cost is asymmetric in a way that
is specific to shared controls: a wrong control does not stay one file. Unwinding
it changed the option type at every call site (`ConsolePickerOption` →
`ConsoleSegment`), required a new explanation string per call site, and moved
every widget test key from `console_picker_*` to `console_chip_*`. One reading,
before the first call site, would have cost nothing.

### The rule that follows

**Read the screens for a control before building the control.** Concretely, for
every later console slice:

1. Before adding a shared control to
   [`lib/common/console_surface.dart`](../../lib/common/console_surface.dart),
   find the `.pen` screen that already draws that interaction — search by what
   the control *does* ("pick one of a few"), not by the name of the face you are
   currently building. The screen that specifies it will usually belong to a
   different domain, which is exactly why it gets missed.
2. If a screen draws it, that drawing is the spec, including the parts that look
   incidental. The chip dialog's "Cancel is the only button" is a design decision
   with a reason (a chip applies and closes, so an OK would imply the choice was
   not already made), not a missing button.
3. If **no** screen draws it, that is the signal to draw one — not to derive the
   control from a neighbouring one. Both halves of this fix ended in a new
   mockup for exactly that reason.

### The two controls

The chip dialog only holds short sets, so the outcome is two controls, and both
are now on record in `segno-ui.pen`.

- **`showConsoleChipDialog`** (`LOOP / loop-quantise`) — the console's ordinary
  pick-one. Eight pickers moved onto it: quantize division, count-in, click mode,
  click output, loop length, time signature, default mode, and the track length
  preset. `explanation` is a **required** parameter, so every migrated call site
  had to supply the line the mockup shows; there is no way to open this dialog
  without saying what it is choosing.
- **`showConsolePickerSheet`** — kept for the two lists it exists for: the looper
  modes, whose per-option descriptions are what make them choosable, and the MIDI
  target lists, which are long. It got its own mockup, `LOOP / loop-mode-pick`,
  so the surviving control is drawn rather than merely tolerated. Both functions
  now carry a doc comment pointing at the other and at the screen each is drawn
  to.

`_ChipGrid` is the part that made "always four across" survive contact with the
real option sets: four per row, wrapping, widths computed from the incoming
constraints so the cells stay equal and nothing shifts when the selection moves.
The mockup draws four chips of 166 on a 744 dialog; eight length presets in a
single non-wrapping row would have squeezed to unreadable slivers.

### The states nobody drew

The same audit found states the mockups never covered and the faces needed
anyway:

- **The console rename sheet** (`TRACKS / track-rename`), keys included. The
  stage keeps its own dialog — `STAGE / track-rename` is that one, over the stage
  view. The console sheet had borrowed the shape of `NETWORK / wifi-password`,
  which is drawn; the Tracks state was not.
- **No tracks at all** (`TRACKS / tracks-empty`). A stopped engine reports zero
  tracks, and all three Tracks tabs were rendering a `ConsoleCard` with no
  children: a 2px sliver above the footnote. This was a bug as much as a missing
  screen. All three now render `ConsoleEmptyCard` with
  `tracksEmptyMessage` — "No tracks — the engine is not running." —
  which is the vocabulary the console already had for it.

### Recorded, not fixed — and how it was settled

#527 also recorded a question it deliberately did not answer: every mockup rig
has four tracks, the real one has eight across two banks, and nothing said
whether the Tracks face should carry a bank toggle the way the Control face does.

It was settled in the issue afterwards, and the answer needed no app change:
**the Tracks face lists every track, not the showing bank.** Naming, length and
routing are setup rather than performance, so a config list has no reason to be
bank-scoped, and the ordinals already say which pad each track is. Following the
mockups' four rows would also have hidden half the rig with no way to reach the
rest, because the tray covers the chrome — the stage's `A | B` pill is behind the
tray while the face is open. The face already iterates the tracks the engine
reports, with a test pinning it; the design was the side that disagreed, so
`TRACKS / tracks`, `tracks-lengths`, `tracks-routing` and `track-rename` were
redrawn with eight rows (four named, four on their `TRACK N` fallback) and
`c/tracks` records the rule.

## Verification (as recorded on #531)

- `flutter test` — 1528 passing.
- `dart analyze` clean; native suite `ALL PASSED`.
- New tests specific to these two fixes: the chip dialog picking a quantize
  division and closing (asserting the explanation, the chips, and that Cancel is
  the only button); the empty rig saying why there is nothing to show; and the
  binding-label tests rewritten around the corrected channel, now also asserting
  that a named rig gets its names.
- Two new goldens for this half — `control_center_chip_dialog.png` and
  `control_center_tracks_empty.png` — the second driven by a `tracks` count
  parameter added to the screenshot driver's `pumpTracks`, so a zero-track face
  can be pinned deliberately. The routing-sheet golden changed because its title
  became a name. The screenshot suite only runs on the author's machine, so these
  were regenerated and eyeballed locally, not in CI.

## What this did not change

- **Footswitch labels stay positional.** They name hardware, not tracks.
- **The stage keeps its own rename dialog.** The console sheet is the console's;
  neither replaces the other.
- **The MIDI target lists stay on the row sheet.** They are long, which is the
  case the sheet survives for.
- **No engine, repository or protocol change** in either fix. Both are label and
  presentation work over state that already existed.
- **No bank toggle on the Tracks face**, per the resolution above.

## Carried forward

- The resolver pattern is now the repo's answer for "what do we call this?" —
  `trackName` and `inputName` are its two instances, and a third should be
  written the same way rather than as a private wrapper in the file that needs
  it.
- The chip dialog is the default pick-one for the remaining console faces, and it
  has already been adopted beyond the slice that introduced it: on `master` it is
  behind ten call sites, including the Audio face's default loop length and the
  System face's display setting, while the row sheet is down to three. Neither of
  those later slices had to re-argue which control to use, which is the outcome
  #527 was for.
