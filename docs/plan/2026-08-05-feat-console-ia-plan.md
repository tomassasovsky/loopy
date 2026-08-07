---
title: "feat(console): adopt the reorganised console IA — Settings splits into domains"
type: feat
date: 2026-08-05
issue: 498
retrofitted: 2026-08-06
shipped: "PRs #515, #521, #522, #531, #534, #532"
---

> **Retrofit note.** This document was written on 2026-08-06, after six of its
> seven slices had already merged. It is reconstructed from issue #498, the
> merged PRs and the shipped code. It records the intent and the decisions;
> it did not predict them. The slices were opened directly at `stage:build`,
> so the `plan` and `plan-review` stages of `docs/TRACKING.md` were skipped
> and this artifact was missing. See **Process note** at the end — it is the
> reason the document exists at all, and the most useful part of it for the
> slices still to come.

## Overview

There is no Settings page any more. It had grown into twelve unrelated groups
in one scroll — audio devices, recording options, engine status, MIDI, pedal,
view preferences, looper mode, defaults, tracks, and a pointer to System — and
the console tray made that worse, because a tray sheet is a fixed height and
Settings was several screens of scrolling inside it.

The rail becomes **one domain per entry, each two to four tabs deep**. Still
eight rail entries: wider and shallower, not deeper. Every face fits the tray
sheet without scrolling.

The direction was settled before any of this: the console prototype, and then
`segno-ui.pen`, are the design. The slices below are the work of landing it,
not of re-deciding it.

## The rail

| Rail | Tabs | Came from |
|---|---|---|
| Signal | input · loop · track · master | unchanged |
| Control | Pedal · MIDI | the Pedal rail entry + Settings' MIDI groups |
| Loop | Tempo · Click · Mode | Loop + `SettingsSection.tempo` + `SettingsSection.mode` |
| Tracks | Names · Lengths · Routing | `SettingsSection.tracks` + the track routing dialog |
| Audio | Device · Recording | `SettingsSection.audio` |
| Tuner | — | unchanged (still a stub, #482) |
| Network | WiFi · Bluetooth | the two radio rail entries, merged |
| System | Display · Updates · Storage · About | `SettingsSection.view` + `.updates` + new |

Why this split and not another: `SettingsSection` is **already the app's own
taxonomy**, and the console had flattened all of it into one page. The IA
restores the app's own sections as destinations. Pedal and MIDI are siblings —
both are things outside the console that drive it — and had been in two
different places. Two rail slots for two radios was the same waste as one
bucket for twelve groups. Per-track routing had no discoverable entry point at
all; it now has a tab.

## Slice sequence

Each slice is independently mergeable and has its own plan document. They were
built in this order, and the order mattered: the first slice pays for the
shared vocabulary every later one draws from.

| # | Slice | Issue | PR | Plan |
|---|---|---|---|---|
| 1 | Network — WiFi · Bluetooth | #498 | #515 | `2026-08-05-feat-console-ia-network-domain-plan.md` |
| 2 | Control — Pedal · MIDI | #516 | #521 | `2026-08-05-feat-console-ia-control-domain-plan.md` |
| 3 | Loop — Tempo · Click · Mode | #518 | #522 | `2026-08-06-feat-console-ia-loop-domain-plan.md` |
| 4 | Tracks — Names · Lengths · Routing | #523 | #531 | `2026-08-06-feat-console-ia-tracks-domain-plan.md` |
| 5 | Audio — Device · Recording | #528 | #554 | `2026-08-06-feat-console-ia-audio-domain-plan.md` |
| 6 | System — Display · Updates · Storage · About | #530 | #532 | `2026-08-06-feat-console-ia-system-domain-plan.md` |
| — | naming + pick-one corrections | #526, #527 | #531 | `2026-08-06-fix-console-naming-and-pick-one-plan.md` |
| 7 | Signal — input · loop · track · master | #533 | — | not yet planned |

Two slices had to be reopened as replacement PRs after stacked-branch
accidents (#517 → #521, #524 → #531, #529 → #534). The rule that came out of
it, recorded here because it cost three PRs: **retarget children onto master
before squash-merging a parent, and delete branches last.** A merged or
auto-closed PR cannot be reopened or retargeted.

## Conventions this IA established

These are cross-slice and binding on the remaining work. Each was decided in a
slice and then inherited; the slice plan that introduced it carries the
reasoning.

**One shared vocabulary.** `lib/common/console_surface.dart` — promoted out of
`lib/network/network_surface.dart` in slice 2, once a second domain read from
it. Faces are composed from it and do not draw their own chrome:
`ConsoleCard`, `ConsoleRow`, `ConsoleExpansion`, `ConsoleExpandedRow`,
`ConsoleSwitch`, `ConsoleBanner`, `ConsoleValueBar`, `ConsoleToggleChip`,
`ConsoleSegmented`, `ConsoleGroupLabel`, `ConsoleEmptyCard`,
`ConsoleSmallButton`, and the sheets — `showConsolePickerSheet`,
`showConsoleChipDialog`, `showConsoleRenameSheet`, `showConsoleForgetDialog`.

**No chrome bar, no back chevron.** The rail is always on screen; a second way
back would be a second navigation surface.

**Where the domain says its name.** A tab that carries a per-tab control (a
radio's power switch, a rescan) needs a title row and puts its tabs first. A
domain whose tabs carry no such control says its name once, above the strip.
That is the mockups' own distinction and it held up across all six.

**Rows open in place**, one at a time, into a tinted card carrying that row's
actions. Everything else acts on tap.

**Banners, not toasts.** Anything in flight, just failed, or offered sits at
the top of the list the setting lives in, in the words the toast used to use.
One banner carries a whole flow; its dot and its action change with the phase.

**Booleans are switches**, never the words "on" and "off".

**Pick-one is a chip dialog** for short sets and a row list for annotated or
long ones. See the naming/pick-one plan for why this had to be corrected after
the fact.

**Things the app cannot know are not drawn as zeroes.** A face says what it
cannot know, or omits the row entirely — an absent serial is not a blank one.
Where a desktop cannot answer at all, the fact goes behind a client seam with
a fake under the existing `SEGNO_FAKE_RADIOS` define, so the face is drivable
off the appliance.

## Capabilities the IA surfaced

Building to the designs repeatedly found things the app could not do. Each was
either added in its slice or split out:

- **Naming a hardware input** — added in slice 5 (`input_name.$device.$input`,
  `InputsCubit`, `l10n.inputName`), immediately reused by Tracks routing. Keyed
  per DEVICE: the same socket on two interfaces is two different jacks.
- **Naming a track everywhere it is referenced** — #526, corrected across
  pedal bindings, MIDI labels and routing summaries via `l10n.trackName`.
- **Per-device channel counts** — the engine never asked miniaudio, so every
  device read 0 in / 0 out. Fixed in `engine_devices.c` in slice 5.
- **Named racks** — the mockups show user-named chains ("Dirty rhythm", "Bus
  tape"); the rig identifies a chain by where it sits. Split out as #535,
  `stage:plan`, `autonomy:plan-gate` — it needs a persistence-scope decision.
- **Monitor tri-state** — the mockups draw ON / AUTO / OFF; `InputMonitor`
  holds a boolean. Open, belongs to slice 7.

## What remains

- **Slice 7, Signal** (#533) — the last face, and the only one that replaces
  an existing rich surface rather than a settings group. It goes through
  `/plan` first.
- **Racks** (#535) — direction call outstanding: rig-global or session-bundle
  persistence, and what "modified" means for a loaded rack.
- **The tray home face**, and the rail-label clash between "Control" the
  domain and "Controls" the existing label.
- `segno-ui.pen` carries uncommitted design work on the Signal screens
  (per-output switches on `SIGNAL / signal-master`, level and mix state on
  `SIGNAL / signal-detail`) added while scoping slice 7.

## Gates and verification

`autonomy:merge-gate` for the IA as a whole: the direction is decided, but
this is broad blast-radius UI and a human merges each slice.

Every slice runs the full loop before it is called done:

```bash
/Users/Tomas/development/flutter/bin/flutter test
dart analyze
bash packages/segno_engine/src/test/run_native_tests.sh
```

Screenshot goldens under `test/screenshots` need regenerating and eyeballing
per slice, and they only run on the author's machine — they rot silently
everywhere else.

## Process note

This plan and its six siblings are retrofits. What skipping the plan and
plan-review stages actually cost, stated plainly so the remaining slices do
not repeat it:

1. **A control was built from the wrong vocabulary** and reached many call
   sites before anyone read the screen that had already specified it (#527).
   A plan pass reads the screens before the code.
2. **A face shipped a wrong model of the rig** — one input per track, which is
   the lane-0 convenience wrapper's view of a multi-lane engine. The mockup's
   own footnote had encoded the same mistake, so building faithfully to a
   single screen reproduced it. Both were corrected.
3. **Scope arrived mid-build** rather than up front: input naming, the engine's
   channel counts, the tray chrome corrections, the navigation rail rebuild.
   Each was right to do; none was in the slice it landed in.
4. **The stack went four PRs deep**, which is exactly what the plan-splitting
   review exists to flag, and three PRs were lost to base-branch accidents.

The tell to watch for: **an issue created at `stage:build` with no plan doc
linked**. Signal (#533) and racks (#535) go through `/plan` and
`/plan-technical-review` first.
