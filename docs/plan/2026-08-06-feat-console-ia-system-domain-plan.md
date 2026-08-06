---
title: "feat(console): System domain — Display, Updates, Storage and About under one rail entry"
type: feat
date: 2026-08-06
issue: 530
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #532"
---

> **This document was written after the fact.** It is reconstructed on
> 2026-08-06 from [#530](https://github.com/tomassasovsky/segno/issues/530),
> the merged [PR #532](https://github.com/tomassasovsky/segno/pull/532)
> (`feat/console-ia-system-domain`, merge commit `b249468c4`) and the shipped
> code. It records the intent and the decisions the slice actually made; it
> did not predict them, and nothing here is a forecast. Where the plan
> pipeline in [TRACKING.md](../TRACKING.md) expects a `docs/plan/*.md`
> artifact between brainstorm and build, this is the missing one.

> **Gate:** `autonomy:merge-gate`, `priority:P1`, `area:console` — the
> direction was settled in #498; the taste on the result is a human's, and a
> human merged it.

## Overview

The System slice of the console IA ([#498](https://github.com/tomassasovsky/segno/issues/498)),
built after Control (#516), Loop (#518), Tracks (#523) and Audio (#528). One
rail entry, four tabs — **Display · Updates · Storage · About** — drawn to
`segno-ui.pen`'s ten `SYSTEM / *` screens.

Two of the four are honest re-presentations of settings the app already
owns. Two report facts a desktop build has no way to know, so they land on a
seam with a fake behind an existing define rather than on invented data or a
disabled tab.

The slice also carries the tray chrome and card-border corrections that
reviewing it against the mockups turned up. Those are not System-specific:
they retro-corrected every face the four earlier slices had already shipped.

## Dependencies

- The IA scaffolding and the four preceding domain faces: Control (PR #521),
  Loop (PR #522), Tracks (PR #531) and Audio (PR #534).
- The branch was stacked on the Audio slice (opened as PR #529, which was
  superseded — Audio landed as #534), so #532's diff is read against Audio
  already in place.
- `UpdateCubit`/`UpdateState`, `WaveformWindowCubit`, `HighContrastCubit`,
  `TracksCubit.showIndicators`, `RefreshRateCubit` and `showShortcutsHelp`
  all pre-exist. Nothing in Display or Updates is new capability.
- The `SEGNO_FAKE_RADIOS` define already existed for the radios. The seam
  below reuses it rather than adding a second flag.

## Context

`SettingsSection.view` and `SettingsSection.updates` are the app's own
taxonomy for two of these tabs, and #498's whole premise is that those
sections become destinations instead of scroll positions in one page. So
Display and Updates were reachable the day the slice started.

Storage and About were not. Disk accounting, capture retention and USB export
do not exist anywhere in the app; console name, serial, system image and panel
description are recorded nowhere. #530 said so plainly and put those two tabs
second in the order, so the slice would not quietly double in size.

The build followed that order literally. The first commit shipped **two**
tabs, with a two-tab strip, on the reasoning that a tab which opens onto
nothing is worse than a tab that is not there yet. The second commit brought
the other two in once the seam below existed — which is `AGENTS.md`'s "grow
the system in layers" applied inside a single PR rather than argued about
across two.

## The four faces — the decisions

**Display** (`SYSTEM / display`, `SYSTEM / waveform-failed`). The waveform
window, high contrast and track indicators are switches, never the words "on"
and "off". The UI refresh rate goes through the console's chip dialog. A row
opens the keyboard-shortcut legend.

The failure state is the interesting one, and it had never been drawn — the
`.pen`'s `waveform-failed` screen was a byte-identical copy of `display`.
**A failure sits at the top of the list the setting lives in, not in a
toast.** It reuses the string the toast already uses, so one condition never
reads two ways, and it carries a retry. The failed flag is held by the face,
not by `WaveformWindowCubit`: the cubit records the *preference* (the window
is wanted); whether the window actually opened is a property of this attempt,
on this screen, right now.

**Updates** (`update` and its four states). Installed version and channel,
then the two automatic switches, then **one banner that carries the whole
flow** — its dot and its action change with the phase, which is exactly how
the mockups draw it. `ConsoleBanner` grew the two things those states need: a
`settled` (green) tone, because "check now" and "installed and ready" are
restful and an amber dot beside them would read as a warning about a rig that
is fine, and a `progress` bar under the message.

**Nothing downloads until asked.** The automatic switch looks; it never
fetches or installs, the subtitle says so, and `UpdateCubit` enforces it. The
idle and up-to-date phases keep their check action so the row is never a dead
end; an unsupported platform gets the banner with no action at all.

**Storage** (`storage`). Five rows for what the disk holds, then two
housekeeping actions. **Deleting captures asks first**, like every
destructive action on this console, and afterwards the cubit **re-reads
rather than guessing** at what is left — the only write on this face, and it
does not model its own effect. Nowhere to export to is a fact about the rig,
not a failure: the export row says "no USB volume" and is not tappable,
instead of failing under a finger. When the build cannot read the disk at
all, the whole card is replaced by one that says so — zeroes drawn as facts
would be worse than saying nothing.

**About** (`about`). Three groups: what this console is, its hardware, and
the legal line into the licence page. **Rows whose fact this build does not
have are left out, not drawn with a dash** — a desktop build is not a
console, and a serial number that is not there is not a serial number that is
blank. That has a small structural consequence the face has to own: which row
is a card's last row depends on what the build knows, so the card decides
where the final hairline goes rather than each row declaring it.

## The `ConsoleFactsClient` seam

Storage and About report things only the appliance image has. On a desktop
every one of those reads is either unavailable or meaningless, and both faces
would have nothing to draw — which is precisely why #530 had deferred them.

The slice answers with a narrow interface, `ConsoleFactsClient`, carrying
four questions: what the disk holds, what this console is, delete captures
older than N days, and is there anywhere to export to. Two implementations
sit behind it — `UnsupportedConsoleFactsClient`, which answers "unknown" and
is what the app gets today, and `FakeConsoleFactsClient`, which answers with
the rig the mockups draw, down to the numbers.

**The fake sits behind `SEGNO_FAKE_RADIOS`, the define the radios already
use.** Inventing a second flag would have meant a developer holding two
switches in their head to see one console, and both switches mean the same
thing: this build is standing in for the appliance. One define, one meaning.

Two properties are load-bearing:

- **The faces can be driven off the appliance.** With the define on, Storage
  and About can be seen, driven and rendered into goldens from a desktop —
  including
  the housekeeping action, which mutates the fake's own figures so the
  re-read has something different to report.
- **Absence is modeled, not faked.** `StorageUsage.known` and the empty
  strings on `ConsoleFacts` are what the faces key off. Without the define,
  they say what they cannot know. This is the reason the seam is worth its
  weight at all: the alternative — plumbing nothing and disabling the tabs —
  leaves the design unverifiable, and the alternative of default zeroes
  leaves the app lying.

`ConsoleFactsCubit` is read-mostly and is provided app-wide, loading on
create; the face re-reads on open, because a USB stick may have arrived
since.

## What the build discovered

Reviewing this slice against the mockups turned up faults in surfaces this
slice did not introduce. They shipped here because the review found them
here, and **they retro-corrected every earlier face** — Control, Loop, Tracks
and Audio all changed appearance with them.

**The tray sheet was approximated.** Measured off the mockups' tray layer,
the sheet is the **card tone and opaque**, not the page background at 78%
behind a 24px blur. That was not only a colour error: a frosted panel let the
stage's waveforms move behind the settings you were reading. The bottom
radius is 17, not 24; there is a hairline bottom edge; and the sheet casts a
drop shadow that lifts it off the stage. The drag pill is 62x5, not 40x5. The
radius and pill dimensions became named constants in `tray_metrics.dart`
beside the existing handle height, so the sheet and the handle cannot drift.

**The drop shadow had to be a token.** `test/theme/token_adoption_test.dart`
walks `lib/` and fails on any colour literal in the view layer, on the ground
that a hex in a widget is invisible to a palette migration and to the
high-contrast variant. The alternative to a token was an allowlist entry —
and the allowlist is explicitly "a design decision, not a way to silence the
test". The tray is the console's own chrome, so it got `SurfaceTheme
.dropShadow` with both variants, and the guard test stayed honest.

**Every card carries its border.** Measured across `SYSTEM / display`,
`AUDIO / audio` and `TRACKS / tracks`: every card is stroked with a 1px line
at a 12px radius. `ConsoleCard` drew that line only when asked and nothing
asked, so the faces read as text floating on the sheet. `bordered` now
defaults to true; the flag survives for a card already inside something
bordered, and the routing sheet's lists opt out explicitly because they sit
inside a dialog.

The same scan produced two smaller corrections, both carried here:

- **An opened list is seamed, not framed.** `AUDIO / settings-device` draws
  it on the page fill, square, with a single line along its top — the join to
  the row it came from. That is `ConsoleCard.recessed`, and the device,
  rate/buffer, inputs and max-loop lists use it. A rounded inset card read as
  a second surface floating in the first.
- **An opened row keeps its hairline on the faces that draw it that way.**
  Network opens into one rounded bordered block carrying row and actions
  together, where the row's own line would cut through the middle; Audio
  stays a flat row with the list seamed beneath. A real difference between
  two faces is a flag (`ConsoleRow.dividerWhileExpanded`), not a blanket
  rule.

A last pass fixed two optical faults with the same root: a selected label
must not resize its own control. The toggle chip and the segmented control
are sized by their own text, so weighting the selected label at 600 reflowed
the row under the user's finger; a constant weight costs a little emphasis
and buys a control that stays still. The chip dialog does **not** have that
problem — its cells are a fixed width — so it keeps the mockups' treatment:
every label at normal weight, the current one told apart by its accent colour
and filled cell.

**A widget test hung on a fake's pretend latency.** `FakeConsoleFactsClient`
delays to make loading and housekeeping visible while developing. Even a
zero-duration `Future.delayed` schedules a timer, and a `testWidgets` body
that awaits one without pumping waits forever. The fix is to make the latency
injectable *and* truly absent: tests construct the fake with `Duration.zero`,
and the fake returns immediately rather than awaiting a zero delay. A fake
that is configurable but still schedules is not fixed.

## Tasks, as executed

1. `SystemTab` — a Flutter-free enum, like the other domains', because the
   tray cubit stores the selected tab and must not import a widget library to
   name a value it holds. `SettingsTrayState` gains `systemTab`, kept across
   navigation like the rest.
2. `SettingsTrayDestination.system` wired into the rail (the mockups' chip
   glyph) and into `TrayPanel`.
3. `SystemTrayPanel` — title, pill tab strip, and the switch onto the four
   tab bodies.
4. Display and Updates first, against the cubits that already existed;
   `ConsoleBanner` extended with `settled` and `progress`.
5. `ConsoleFactsClient` + the two implementations + the factory; the cubit
   and its state; the provider hoisted into `App`.
6. Storage and About, and the tab strip widened from two to four.
7. The tray chrome, `dropShadow` token, and card-border corrections above.
8. Strings for all of it in both `app_en.arb` and `app_es.arb`.

## Testing

- `test/system/view/system_faces_test.dart` — one group per tab. The
  load-bearing assertions are the decisions, not the layout: that an offer
  sits untouched until the button is pressed (`verifyNever` on the download,
  then `verify` after the tap); that a failed check is red and offers a
  retry; that an unsupported platform offers nothing; that deleting captures
  raises the confirm dialog and the figures afterwards come from a re-read;
  that a build which cannot read the disk says so and draws no rows; and that
  a build which is not a console omits the identity rows while keeping the
  ones it does know.
- Goldens: three new ones under `test/screenshots/goldens/`
  (`control_center_system_display`, `_storage`, `_about`), pumped through the
  same preview driver as the other domains, with the fake at zero latency.
- Every pre-existing console golden was regenerated, because the tray and
  card corrections change every face. That regen is the review artifact for
  those corrections, and it only runs on the author's machine — the
  screenshot suite self-skips elsewhere.
- The PR reports the full loop from `CLAUDE.md`: `flutter test` 1575
  passing, `dart analyze` clean, native suite `ALL PASSED`.
- One housekeeping commit at the end formats the new files: files written
  whole never pass through the local hook that formats edited ones.

## Exit criteria

- System is one rail entry with four working tabs, and no tab opens onto
  nothing.
- No face draws a fact this build does not have — neither as a zero nor as a
  dash.
- Nothing downloads or deletes without being asked; the destructive action
  confirms and then re-reads.
- The tray sheet and every card match the measured mockup values, and no
  colour literal was added to the view layer to get there.
- Full suite, `dart analyze` and the native suite green; goldens regenerated
  and eyeballed.

## Non-goals

- **No real disk accounting, retention or USB export.** The seam is the
  contract; the appliance-side implementation is not in this slice, which is
  why the shipped client answers "unknown".
- No new define, no new configuration surface — the fake rides the radios'
  existing one.
- No change to `UpdateCubit`'s policy. The opt-in rule was already there;
  this face draws it.
- No brightness control. The issue lists `brightness` among Display's
  screens; the shipped face is built against `SYSTEM / display` and
  `SYSTEM / waveform-failed`.
- No IA change beyond the row #498 already specifies for System.
