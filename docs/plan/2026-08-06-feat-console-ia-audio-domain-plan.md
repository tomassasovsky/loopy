---
title: "feat(console): Audio domain — Device, Recording and Status under one rail entry"
type: feat
date: 2026-08-06
issue: 528
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #534 (replaces #529)"
---

> **Retrofit note.** Written on 2026-08-06, after the slice had merged, from
> issue #528 and its one comment, the merged PR #534 and the shipped code.
> It records the intent and the decisions; it did not predict them. The issue
> was opened directly at `stage:build`, so this artifact was missing from
> `docs/TRACKING.md`'s pipeline. Nothing below is a forecast — where it reads
> like a plan, that is the decision as it was actually taken, and the section
> that matters most is **What the build discovered**, because this slice had
> more of it than any of its siblings.

## Overview

Slice 5 of the console IA (#498): `SettingsSection.audio` becomes one rail
destination with three tabs — **Device**, **Recording**, **Status** — built to
the twelve `AUDIO / *` screens in `segno-ui.pen`.

The split is the same question asked three ways. Device is what the rig plays
through and how fast it runs. Recording is what pressing record does. Status
is what the rig is actually doing right now. Most of the machinery already
existed in `lib/audio_setup/`; the face is a re-presentation of those cubits
in the console's row vocabulary, not a second copy of the rules.

Two things in it were not re-presentation, and they are why this slice is
worth reading: naming a hardware input was a capability the app did not have,
and per-device channel counts were a number the engine had never asked
miniaudio for.

## Dependencies

- Slices 1–4 of the parent plan, merged: Network (#515), Control (#521), Loop
  (#522), Tracks (#531).
- `lib/common/console_surface.dart` — the shared vocabulary promoted out of
  the Network face in slice 2. This face composes from it and draws no chrome
  of its own.
- The console rename sheet built for the Tracks slice (#523), and the track
  naming corrections of #526 — the input-naming work below is their twin one
  level down the signal path.
- PR hygiene, paid for here: #529 was the original PR and GitHub closed it
  when its base branch was deleted on the Tracks merge. #534 is the same
  commits rebased onto master. The rule the parent plan records — retarget
  children onto master before squash-merging a parent, delete branches last —
  is partly this slice's bill.

## Context

`lib/audio_setup/` already held `AudioSetupCubit` (devices, sample rate,
buffer, ASIO drivers, latency measurement, max loop length), the record and
quantize cubits under `lib/looper/cubit/`, and `audio_settings_section.dart`,
the pre-console scrolling surface over all of it. `EngineStatus` already
reported the open device, rate, buffer, latency state and record offset.

What did not exist: any notion of what a hardware input is *called*, and any
per-device channel count outside an ASIO probe. Both were found by drawing
the screens.

`AudioTab` is a Flutter-free enum beside `LoopTab` and `TracksTab`, because
`SettingsTrayCubit` holds the selected tab and must not import a widget
library to name a value it stores. The tab survives navigating away, as the
other faces' tabs do.

## The shape

### Rows open in place, one at a time

Device is three rows — device, sample rate / buffer, inputs — and each opens
onto its list inside the card rather than pushing a route. The Network face
established the pattern; the mockups make the reason plain here: a buffer
choice is only meaningful next to the rate it divides, and pushing a route
hides the other two settings while you change one. `_OpenRow` is a single
enum with a `none` member, so opening one row closes the other: two lists
open at once is a scroll, and this face has to fit the tray sheet.

Recording opens the maximum-loop row the same way, because its options are a
memory decision the line above them explains.

### Every buffer option carries what it costs

The closed rate/buffer row carries the round-trip figure in its subtitle and
reads `48 kHz · 128`. Opened, `SAMPLE RATE` lists the rates — with the one
that costs something (96 kHz, which halves the buffer headroom) saying so —
and `BUFFER` gives **every** option its own latency, not only the chosen one.
A list where only the current pick is annotated cannot be used to choose.

That figure is an estimate — `estimatedRoundTripMs` is two buffer periods —
and it is stated as one. The measured figure stays on Status, where it is
measured. The trade was taken deliberately: without an estimate the mockups'
per-option cost could not be honoured at all.

### Status is read-only

Everything on Status is what the rig **is** doing. The settings that decide
it live on Device, and a figure editable in two places is a figure that
disagrees with itself. So device, rate, buffer, round-trip latency and record
offset are rows with no disclosure and no tap.

The one action is re-running the measurement, and it refuses while a
measurement is in flight rather than restarting the thing it is reporting. A
timed-out measurement takes the warning tone rather than the muted one:
"No signal detected" is not a number in grey, it is the reason the offset
below it may be wrong. The loopback note comes from `l10n.loopbackNote`, the
same sentence the setup page shows, so the two surfaces cannot reach
different conclusions about the same rig.

### Failure states belong on the face that owns the setting

Two, both on Device:

- **No outputs enabled** is read from the LOOPER's `outputEnabledMask`, not
  from device state — outputs are switched per channel on the Signal page.
  Every one of them off is silence with no other symptom: the meters move,
  the loop plays, nothing comes out. It gets a failed banner rather than
  being left to be discovered.
- **Windows keeps its ASIO group.** When `asioOnly`, the probed drivers are
  listed with their channel counts; when none is found, the install note, and
  with it a link to the generic driver. Linked and never bundled — that
  licence forbids redistribution.

## Tasks

The build order, as taken — each commit standing on its own:

1. **Hardware inputs get names** (`46b43ca21`). The capability, ahead of the
   face that needed it: the repository key, the cubit, the resolver, and the
   two Tracks surfaces that immediately read from it.
2. **Rail entry and Status tab** (`7458f325c`). Destination, `AudioTab`,
   panel, rail glyph and label, and the first tab. The panel routed all three
   tabs at Status until the others existed.
3. **Device tab** (`de30ba0ac`). Device list, rate/buffer, named inputs, the
   silence banner, the ASIO group. The track rename sheet became
   `showConsoleRenameSheet` here, since it was never track-specific except in
   its name.
4. **Recording tab** (`51ddb327f`). Max loop cap, the three switches, the
   default-length chip dialog — and the three goldens, the face being whole.
5. **The corrections** (`9861b2f67`, `7054568f9`, `d1225f83a`, `6d8a2ffbd`).
   Below.

## What the build discovered

### A capability the app did not have: an input has a name

`AUDIO / settings-inputs` draws the input list as `guitar` over `input 1` —
the interface says input 2, the player says "mic" — and the Device tab's row
summarises it as `2 named`. Nothing in the app could hold that. There was no
`input_name.*` key in `SettingsRepository`, no cubit that owned it, and every
surface labelled an input by its ordinal through `l10n.inputChannelLabel`.
This was recorded on the issue before the build, so the slice's scope would
be honest: the Inputs row is a new capability, not a re-presentation.

It was modelled on track names because it is the same problem one level down
the signal path, and that pattern already worked end to end
(`track_name.$channel` → `TracksCubit.rename`). Studying what already works
before inventing is the house rule; here the twin was exact:

- `input_name.$i` in `SettingsRepository`, beside `_trackNameKey`.
- `InputsCubit` — a small cubit that owns one persisted map and nothing else,
  provided at `App` level beside the track names and loaded once, because an
  input is called what the player calls it on every surface that shows one.
- `l10n.inputName(names, input)` as the **one** resolver, the input-side twin
  of `trackName` — two surfaces disagreeing about what an input is called is
  exactly the bug track names already had (#526).

One decision that is not a copy: the names are kept **per socket up to the
engine's input ceiling** (`InputsState.maxInputs`, the app-side value of
`LE_MAX_INPUTS`), not per current device. Swapping interfaces and swapping
back does not lose them; a two-input device simply shows two.

It was in use beyond this face before the face itself existed: the Tracks
routing summary and the per-track lane list read `mic` rather than `In 2`.

### Channel counts were zero, and the fix belonged in the engine

The device list is supposed to read `18 in · 20 out`. It read nothing for
every device except the one the engine had open. The comment in
`engine_devices.c` asserted that miniaudio enumeration "reports no per-device
channel count" — that was wrong, and had been wrong for as long as the field
existed. The counts were never unobtainable, only unasked-for.

`ma_context_get_devices` returns the cheap list: id, name, default flag.
`ma_context_get_device_info` returns everything else, one query per device.
So `device_channels(ctx, id, capture)` was added and `enumerate_devices` now
calls it per device:

- it queries `ma_device_type_capture` or `ma_device_type_playback` according
  to which side is being enumerated, and fills `input_channels` on the
  capture path, `output_channels` on the playback path — a playback device
  reports what it can play and never the other direction;
- it walks `nativeDataFormats[0..nativeDataFormatCount)` and keeps the
  **widest** `channels`, not the first. A device advertising both 2ch stereo
  and 18ch multitrack is an 18-in interface, and taking the first entry would
  call it a stereo one;
- a device that cannot answer keeps `0`, which still means UNKNOWN. The
  header comments were corrected to say so, and the native test flipped from
  asserting `== 0` on both counts to `>= 0` on the queried direction and
  `== 0` on the other — a CI box with no audio device still answers nothing,
  but it must never claim the direction it was not asked about.

The alternative was hiding the row on the console side. That would have been
the smaller diff and the wrong one: the number is real, the design asks for
it, and the engine was the thing that was not asking.

Two console-side consequences. The host lists playback and capture
separately while one interface is both, so `_DeviceList` pairs the two
directions **by name** to say `18 in · 20 out` once. And `0` is treated as
unknown rather than printed: a device says its counts when they are known,
the open device borrows the counts the engine negotiated, and the rest say
nothing. `0 in · 0 out` was a lie the first version told, and a device
claiming no channels reads as one that cannot be used.

### Fidelity took more than one pass

The tab was built to the mockups and still was not drawn as the mockups draw
it. Five corrections, all after the fact:

- **A footnote nobody designed.** The tab carried a line under the card
  explaining that changing the device reopens the engine. True, and not on
  the screen — `AUDIO / audio` ends at the card, and the max-loop row already
  says it where it belongs. Removed, string and all.
- **Captions had been built as rows.** `SAMPLE RATE` and `BUFFER` were
  centred 70px `ConsoleRow`s. The mockups draw 13px muted captions,
  left-aligned, half the height, and not tappable. They are captions now.
- **The wrong grey.** Channel counts, per-buffer latencies and input ordinals
  render in the muted tone the mockups use, not the secondary tone a row
  value defaults to.
- **The device that is gone was missing.** `settings-device` lists the
  pinned-but-absent device greyed, with `unplugged` where its channel counts
  would be. A pin still points at it, and dropping it from the list would
  read as a device you never had. `ConsoleRow` gained a `titleColor` for it —
  greying the value alone leaves a name that still looks like something you
  could choose.
- **An em-dash where a device name belongs.** The closed row had named only a
  device the engine had managed to open. It names the **pinned** one, falling
  back to the engine's, then to the system default, and only then to the
  em-dash: picking a device and seeing a dash reads as a tap that did
  nothing.

Then the treatment of the opened lists themselves. They had been inset
rounded cards, which read as a second surface floating inside the first; the
mockups run every opened list edge to edge. `ConsoleCard` took a
`borderRadius` (and pads for a border only when it draws one), `_OpenableRow`
took a `padding`, and the device, rate/buffer, inputs and max-loop lists all
run flush and square inside their own card. Found on the way: an **open row
is shaded** with the control tone, which is what says the strip below belongs
to it.

The Device golden had to be re-rigged twice for the same reason the face was
corrected twice — its fake engine now enumerates both directions of two
interfaces the way a host reports them, and the golden opens the device row,
because the counts are the part worth pinning.

### Un-naming an input, and the face with nothing selected

`AUDIO / settings-rename` has no Clear button. It has a backspace and Save.
So the answer to "how do I un-name an input" is: empty the field and save,
and `showConsoleRenameSheet` grew an `allowEmpty` flag for it. The inputs
list passes it; the tracks list does not, because a track is never nameless —
its fallback **is** a name. An emptied input name hands the socket back its
ordinal through `l10n.inputName`. The sheet also carries the socket beside
its title, and its keyboard action key reads Save, as both mockups label it.

What the face shows when there is nothing to show, decided the same way
throughout — say what is not known rather than draw a zero:

- no device pinned and none open: the system default, since that is what a
  start would use;
- a device whose counts are unknown: no value at all;
- a device with no inputs: an empty card saying so, rather than an empty
  list;
- Status with no engine running: em-dashes on the rows that have no figure,
  and `Not measured` on latency until a measurement is run.

## Testing

- `flutter test` — the PR reported 1559 passing, with 13 new face tests and 5
  for the new cubit. As merged, `test/audio_setup/view/audio_faces_test.dart`
  holds 15: the last two fix commits each brought their own (a device with
  unknown counts saying nothing rather than zero, and clearing a name handing
  the socket back its ordinal).
- The face tests cover: the device list opening one row at a time, per-option
  buffer costs, rate and buffer reaching the engine, inputs listed by the
  name they were given, renaming through the sheet, the silence banner, the
  max-loop cap, the three switches and the default-length dialog.
- `test/audio_setup/cubit/inputs_cubit_test.dart` covers the five facts that
  matter about the cubit, including that names outlive the device that had
  those sockets.
- Native suite green, including the rewritten enumeration assertions.
- `dart analyze` clean.
- Three new goldens — `control_center_audio_device.png`,
  `_recording.png`, `_status.png` — plus the regenerations the shared-surface
  changes forced across the Network, Control, Loop and Tracks goldens. They
  only run on the author's machine and rot silently everywhere else, so they
  were regenerated and eyeballed per the parent plan's rule.

## Exit criteria

- One rail entry, three tabs, the tab kept across navigation.
- Every one of the twelve `AUDIO / *` screens has somewhere it is drawn.
- No figure on Status is editable, and no setting on Device is duplicated
  there.
- No device row prints a count the app does not know.
- An input can be named, un-named, and is called the same thing on every
  surface that shows one.
- Full verify loop from `CLAUDE.md` green.

## Non-goals

- No change to `AudioSetupCubit`'s rules — the face re-presents them.
- No second copy of the loopback explanation or the latency measurement; both
  stay owned where they already were.
- No per-channel output switching here: that lives on the Signal page, and
  this face only reports when every one of them is off.
- No monitor tri-state. The mockups draw ON / AUTO / OFF and `InputMonitor`
  holds a boolean; that gap belongs to the Signal slice (#533).
- No retirement of `audio_settings_section.dart` in this slice.
