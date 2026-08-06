---
title: "feat(console): Tracks domain — Names, Lengths and Routing under one rail entry"
type: feat
date: 2026-08-06
issue: 523
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #531 (replaces #524)"
---

> **This document was written after the fact**, from issue
> [#523](https://github.com/tomassasovsky/segno/issues/523), the merged
> [PR #531](https://github.com/tomassasovsky/segno/pull/531) and the shipped
> code at `f08c54b5d`. It is the missing plan artifact for a slice that went
> straight from issue to build. It records the intent and the decisions this
> slice made; it did not predict them. Nothing here is a forecast — where it
> reads prescriptively, that is the decision as the code implements it, and
> the code is the fact.

> **Gates as labelled:** `area:console` · `priority:P1` ·
> `autonomy:merge-gate` — the direction was settled by #498; this is broad,
> visible UI, so a human merged it. The tests passing was never the bar.

## Overview

The console rail gains a **Tracks** destination: three tabs — Names, Lengths,
Routing — over settings that until now lived in the Settings page's `tracks`
section, on the Signal page, or nowhere at all. It is slice 4 of the console
IA reorganisation ([#498](https://github.com/tomassasovsky/segno/issues/498)),
after Control (#521) and Loop (#522), and it was built to the five
`TRACKS / *` screens in `segno-ui.pen` — `tracks`, `tracks-lengths`,
`tracks-routing`, `track-routing`, `track-unrouted`.

The face itself is the smaller half of the work. The larger half is the
routing model underneath it, which the first pass got wrong in exactly the way
the mockup did, and which is the reason this slice is worth a document at all.

## Dependencies

- **#498** — the IA decision. The rail table, the tab split and the "wider and
  shallower, not deeper" rule come from there and were not re-litigated here.
- **#521 (Control)** and **#522 (Loop)** — the face shape this slice copies:
  title above a `PillTabs` strip, no chrome bar, 70px rows in a card, a
  Flutter-free tab enum held by `SettingsTrayCubit`. This branch was stacked
  on the Loop branch, which is the origin of the process failure recorded
  below.
- The **multi-lane engine** work of 2026-06-10
  ([brainstorm](../brainstorm/2026-06-10-multi-lane-tracks-dual-route-monitoring-brainstorm-doc.md),
  [plan](2026-06-10-feat-multi-lane-tracks-dual-route-monitoring-plan.md)) —
  the model this face has to expose honestly. Its stated premise is
  "**not** one input = one track with UI grouping".

## Context — what already existed underneath

Every setting the face offers already existed end to end. Two had never had
any UI, and one could be written but not read:

| Setting | Write path | UI before this slice |
|---|---|---|
| Name | `TracksCubit.rename` | stage tile, Settings › Tracks |
| Length preset | `LooperTrackLengthPresetChanged` | Settings › Tracks |
| Recorded input | `LooperLaneInputChanged` | Signal page take badge |
| Outputs | `LooperLaneOutputChanged` | Signal page chips |
| Quantize override | `LooperTrackQuantizeChanged` | **none** |

Two rules follow from that, and both hold in the shipped code:

- **Writes go through `LooperBloc`.** It is the only place that pairs the
  engine call with the settings write, so a widget reaching for the repository
  directly would apply a change that the rig loses on relaunch.
- **The roster is the engine's, the names are the app's.** The rows are built
  from `LooperBloc.state.tracks`, not from a fixed count, so a rig with a
  different track count does not get rows for tracks it has not got.
  `TracksCubit` owns and persists the names on top of that roster.

One read gap had to close before the face could render its own state: the
per-track quantize override was **write-only** — nothing on `Track`, nothing
in the engine snapshot — so a surface offering follow / always / never could
not say which of the three was current. The repository already kept the map
(it re-applies it on every restart); it only needed a read path, and got one:

```dart
bool? trackQuantize(int channel) => _trackQuantize[channel];
```

(`packages/looper_repository/lib/src/looper_repository.dart`.) That is the
whole engine-side change in this slice. Everything else is view work.

## The face

One rail destination, three tabs, same shape as Control and Loop
(`lib/looper/view/tracks/tracks_tray_panel.dart`, tab enum in
`lib/looper/tracks_tab.dart`, held as `SettingsTrayState.tracksTab` so the
face returns to where it was left).

- **Names** (`TRACKS / tracks`) — a row per track: the name left, `track N`
  right. Tapping opens a **console rename sheet with the keys built in**, not
  the stage's dialog. The console has no physical keyboard, and the app-wide
  keyboard host is focus-driven, so a dialog would centre itself in what was
  left after the keyboard claimed the bottom of the screen. The stage keeps
  its dialog; this is the console's.
- **Lengths** (`TRACKS / tracks-lengths`) — `Auto` or a bar preset per track.
  The choice set is `SetupTrackLengthPresetRow.presets`, the same list
  Settings offers, **not a second copy of the same numbers** — two surfaces
  disagreeing about which lengths exist is a bug nobody finds until a rig is
  set up on one surface and played from the other.
- **Routing** (`TRACKS / tracks-routing`) — every track's inputs, outputs and
  quantize override at a glance (`bass / In 1 · In 2 · quantize on` →
  `Out 1 · Out 2`), each row opening that track's own panel
  (`TRACKS / track-routing`). A track that is routed nowhere is called out on
  the row, in the warning colour, and again inside the panel
  (`TRACKS / track-unrouted`).

Every tab carries a footnote in the mockups' muted tone (`TracksFooter`),
because all three settings reach beyond the tray — a name shows on the stage
and in the pedal targets, a length only takes effect on the next defining take
— and a list row has nowhere to say so.

## The routing rule — the heart of this slice

State it precisely, because a smaller-sounding version of it is wrong:

> **A track records any set of inputs — one dry lane each, sharing the track's
> transport and loop. Lane index is identity.**

Checking an input gives the track a lane for it; unchecking frees that lane.
The identity rule is what makes the editing safe, and it has two consequences
that the code implements literally (`_toggleInput` in
`lib/looper/view/tracks/track_routing_sheet.dart`):

- **Dropping an input sets its own lane to record nothing (`-1`) and leaves
  the lane where it is.** It does not compact the list.
- **Adding an input reuses such a freed lane before growing the track**, and
  only grows the lane count when there is no spare — growing first, so the
  engine has allocated the lane before it is routed.

The alternative — rebuild the lane list as "sorted inputs, one per index" —
is the obvious implementation and is the one to refuse. Lane 2 holds lane 2's
recorded audio. Renumbering would silently move a take from one source to
another whenever an input was added in the middle of the set: the panel would
look right and the loop would play the wrong thing.

Two more rules fall out of the same model:

- **Outputs belong to the lane, not the track.** A guitar lane going to the
  mains while its DI lane goes to the desk is one track with two destinations,
  which a single track-wide output group cannot express. So a checked input
  row *is* a lane row: it carries that lane's outputs as its value and opens
  in place onto that lane's chips. The Routing tab's summary shows the
  **union** of the lanes' outputs, so a track whose second lane goes elsewhere
  does not read as if only the first lane existed.
- **"This track is silent" is no longer the same statement as "this lane
  is."** The unrouted warning therefore sits inside the lane strip it
  describes, next to the chips that are all off.

Interaction, as shipped: the check gutter both shows and undoes the choice
(tapping the check un-checks the lane), the row body opens the lane, one lane
is open at a time like every other console list, and **every change applies as
it is tapped** — the Done button dismisses, it does not commit. A routing
panel with an OK button would imply the changes were not already audible.
`None (clean)` is a row of its own that stops every lane recording while each
lane keeps its audio.

The panel is a centred dialog rather than a bottom sheet, as the mockups draw
it: it is three grouped lists, and a sheet tall enough to hold them is the
whole screen anyway. It re-provides `LooperBloc`, `TracksCubit`,
`QuantizeCubit` and the repository explicitly, because a dialog route is built
by the navigator and inherits nothing from the caller's subtree.

## What the build discovered

### The first pass offered one input per track — and so did the mockup

The routing panel initially let a track record **one** input. That is not a
UI simplification; it is the **lane-0 convenience wrapper's view of the
world** mistaken for the rig's. The engine had been rewritten months earlier
precisely so that a track could record several inputs as separate dry lanes
under one transport, with the brainstorm saying so in as many words: *not*
"one input = one track with UI grouping".

The mockup's own footnote had encoded the same wrong premise, and issue #523's
"what's already wired underneath" table pointed at `LooperLaneInputChanged
(lane 0)` — plan and design agreed with each other, and both were wrong, for
the same reason: they were read off the compatibility wrapper rather than the
model. Both the footnote and the input list were corrected in `segno-ui.pen`
in this branch, along with the per-lane panels; the mockups now draw the lane
list with an open lane and their notes say what a lane is.

**This is the clearest example in the whole console IA of what a plan-review
pass exists to catch.** It is not a bug that testing finds — the one-input
panel worked, its tests passed, and it matched the design file. It is a
model-level error, and the only stage that could have caught it is the one
where someone checks the plan against the engine it is meant to expose. That
stage was skipped for this slice, and the cost was paying for the routing
panel twice: once as a single-input picker, then again as a lane list with
per-lane outputs, an in-place expansion and a relocated warning.

### Track rows had been labelled by number across the app

Reaching for the name on this face surfaced that most of the app did not use
it. A rig named `drums / bass / rhythm / lead` read `Track 1 … Track 4` the
moment you left the stage: the pedal-assignment target list, the MIDI-learn
targets, the FX editor's bus title, the rename dialog, the plate's accessible
labels and this panel all identified a track by its ordinal, while a resolver
already existed and only three surfaces used it — with two files duplicating
the same private wrapper around it.

Split out as [#526](https://github.com/tomassasovsky/segno/issues/526) and
fixed in this PR: one resolver, `l10n.trackName(names, channel)`, threaded
through every surface that names a track; the duplicates deleted. Footswitch
labels stay positional — those name the switch under your foot, whose track
depends on the bank. Threading the resolver through also fixed a pre-existing
off-by-one: the pedal and MIDI-learn labels printed the **raw** channel, so a
binding on the second track read "Track 1" while every other surface called it
TRACK 2. Surfaces that now display names take `TracksCubit`, and
`showPedalAssignmentPage` re-provides it across the route it pushes.

The routing panel leads with the name and keeps the ordinal underneath, where
it still says which pad on the pedal this is.

### A second audit, folded in: the pick-one control and two undrawn states

Recorded as [#527](https://github.com/tomassasovsky/segno/issues/527) and also
landed here. `LOOP / loop-quantise` already drew the console's pick-one
control — a centred dialog of equal-width chips with an explanation line and
Cancel as the only button, because a chip applies and closes — while
`showConsolePickerSheet` had been built from the row vocabulary without
checking, and had reached 12 call sites. The outcome is two controls, both
drawn: `showConsoleChipDialog` for the eight short pickers (the track length
preset among them), and the row-list sheet kept for the two cases it exists
for — looper modes, whose descriptions are what make them choosable, and the
MIDI target lists.

Two states the mockups never had were drawn and built in the same pass: the
console rename sheet (`TRACKS / track-rename`) and the no-tracks state
(`TRACKS / tracks-empty`). The second was a live bug as much as a missing
screen — a stopped engine reports zero tracks, and all three Tracks tabs were
rendering an empty card as a 2px sliver above the footnote.

Recorded, not fixed: every mockup rig has four tracks and the real one has
eight across two banks, and nothing says whether Tracks should carry a bank
toggle the way the Control face does.

### The stranded PR — a stacked-branch accident worth not repeating

The original pull request for this slice, **#524**, was opened with
`feat/console-ia-loop-domain` as its base rather than `master`, because the
branch was stacked on the Loop slice. When the Loop branch merged, GitHub
recorded #524 as **merged** too — its head had reached its base. The work
never reached `master`.

A merged PR cannot be reopened, so the recovery was to rebase the same commits
onto the current `master` and open **#531** as a replacement, with the
substitution stated at the top of its body. Nothing else changed. #531 merged
at `f08c54b5d`.

The lesson, which is cheap to apply and expensive to skip: **on a stacked PR,
retarget the base to `master` as soon as the branch below it lands.** The
failure is silent — GitHub reports success, the issue closes, and only a `git
log` on `master` disagrees. This is a fresh instance of a hazard the repo has
already been bitten by; treat a stacked PR's base as something to be watched,
not set once.

## Precedent this set

Three things in this slice are now vocabulary the later domains inherit.

**The console rename sheet.** A modal sheet with its own keys, for the same
reason the WiFi join sheet is one. It shipped here as
`lib/looper/view/tracks/track_rename_sheet.dart`, scoped to a track name — and
the very next slice (Audio, `591d2346`) generalised it to
`lib/common/console_rename_sheet.dart` with a `subtitle` and an `allowEmpty`
flag, so hardware inputs could be named too. The scoped-then-lifted order was
right: the second caller is what showed which parameters were real.

**The per-track sheet shape.** A centred dialog, max 744px, of labelled groups
over cards that take a fill so the lists inside recede instead of matching the
panel; changes apply as tapped and Done only dismisses; rows open in place,
one at a time, using the same expansion primitive the Network face's rows use;
the check gutter both shows and undoes. Any future "one row, its own settings"
console surface should copy this rather than inventing a second shape. Two
controls were added to the shared console surface on the way, both straight
off the mockups: `ConsoleToggleChip` (a pill that is on or off — a lane is
sent to *any* set of outputs, which a tab strip cannot say) and the accent
form of `ConsoleSmallButton` (the panel-ending Done).

**How the tabs relate to the earlier slices.** Control established
Pedal · MIDI and Loop established Tempo · Click · Mode; Names · Lengths ·
Routing is the same construction — a title above a `PillTabs` strip, no chrome
bar, a Flutter-free tab enum in the feature directory so the tray cubit can
hold it without importing a view, and the selected tab kept across navigation
in `SettingsTrayState`. The difference is what a row *means*: on Control and
Loop a row is a global setting, while on all three Tracks tabs a row is a
**track**, and the same engine-reported roster drives the three lists. That is
why the empty-rig state had to exist here first — a face whose rows are
objects can have none of them.

## Verification, as run

- `flutter test` green (the PR body's headline count, 1528, was written before
  the later fix commits landed).
  `test/looper/view/tracks/tracks_faces_test.dart` shipped with **13 widget
  tests** in four groups — Names, Lengths, Empty rig, Routing. The PR body's
  "7 new Tracks tests" predates the lane rework; the tests that pin the model
  above are `unchecking an input frees its own lane, in place`, `a freed lane
  is reused before the track grows again`, `an output chip moves ONLY its own
  lane`, `None (clean) stops every lane recording` and `only one lane is open
  at a time`. The face is pumped at 1920x1080, because the default 800x600
  surface pushes rows below the fold where a tap lands on nothing.
- `dart analyze` clean; the native engine suite `ALL PASSED`.
- Goldens: **six new** (`control_center_tracks_names`, `_tracks_lengths`,
  `_tracks_routing`, `_tracks_empty`, `_track_routing_sheet`,
  `_chip_dialog`), and every existing control-center golden regenerated
  because the rail gained an entry. The screenshot suite only runs on the
  author's machine, so this was a deliberate local regen and eyeball.
- One CI-only failure worth knowing about: the format gate caught files that
  were **written whole rather than edited in place**, which the local
  PostToolUse hook never sees. Whole-file writes bypass the hook.

## Exit criteria, as met

- No caller can ask a track for "its input" — the panel and the summary line
  both speak in lanes, and the lane list is multi-select.
- Dropping or adding an input never renumbers a lane; both directions are
  pinned by a test.
- The quantize override renders its current value, in all three states,
  including what "follow global" currently means.
- All three tabs handle a stopped engine with no tracks.
- Every surface that names a track goes through one resolver.

## Non-goals

- **No engine or protocol change.** The only package-side addition is one
  getter, `LooperRepository.trackQuantize`, over a map the repository already
  kept.
- **No per-lane FX here.** The lane strip says so explicitly rather than
  leaving a gap where a chain editor looks like it should be; per-lane effects
  stay on the Signal page.
- **No re-litigating the IA.** The rail table and the tab split are #498's.
- **No bank toggle for rigs with more than four tracks** — recorded in #527,
  deliberately not decided here.
- **No restyling outside the Tracks face**, beyond the shared console controls
  this slice had to add and the naming fix that #526 scoped.
