---
title: "feat(console): Control domain — Pedal and MIDI under one rail entry"
type: feat
date: 2026-08-05
issue: 516
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #521 (replaces #517)"
---

> **This document was written after the fact**, on 2026-08-06, from
> [#516](https://github.com/tomassasovsky/segno/issues/516), the merged
> [#521](https://github.com/tomassasovsky/segno/pull/521) and the shipped code
> at `2f4973733`. It is the missing `stage:plan` artifact for a slice that went
> straight from issue to branch. It records the intent and the decisions — it
> did not predict them. Where it reads like a plan, that is the house voice;
> where it reads like a report, that is "What the build discovered", and that
> section is the reason the document exists.

> **Gate as shipped:** `autonomy:merge-gate` — the direction was settled in
> #498, but this is broad-blast-radius console UI and it deletes a rail
> destination, so a human merged it.

## Overview

The console rail has a **Pedal** entry, and the MIDI mapping surface lives
somewhere inside the Settings scroll. They are the same question asked twice:
*what outside this box is driving it?* The console IA reorganisation in
[#498](https://github.com/tomassasovsky/segno/issues/498) answers it once —
one **Control** rail destination with a `PillTabs` strip, **Pedal · MIDI** —
and the Pedal-only destination ([#440](https://github.com/tomassasovsky/segno/issues/440))
goes away with it.

This is the **second slice** of the parent plan
([console IA](2026-08-05-feat-console-ia-plan.md)), following the Network
domain ([#515](https://github.com/tomassasovsky/segno/issues/515)). Network
went first because it was the smaller of the two and had to invent the shared
row/card/banner vocabulary that every later face reads from. Control goes
second because it is the first slice with a *second* caller for that
vocabulary — which is what turns a domain-local file into a console-wide one.

It is built to the `CONTROL / *` screens in `segno-ui.pen`: `control`, `pedal`,
`pedal-slots`; `control-midi`, `midi-switch`, `midi-listening`, `midi-replace`,
`midi-sweep`; and the absent-device and failure states `midi-stale`,
`midi-no-device`, `midi-gone`, `midi-open-failed`.

## Dependencies

- **#515 (Network domain) must land first.** It owns
  `lib/network/network_surface.dart` — the row, card, banner, disclosure and
  confirm primitives this face is assembled from. Building on top of it means
  the two faces cannot disagree about what a row is.
- Nothing else. `ControlCubit` already owns pedal bindings, controller
  bindings and the learn state; `MidiSetupCubit` already owns the device
  connection. This slice is a re-presentation of state the rig already has —
  **no new mapping engine**.
- The tray home face survives this slice. Settings has to stay reachable until
  Loop / Tracks / Audio / System have taken its content, so its removal — and
  brightness becoming the mockups' `Bright` rail entry — is the parent plan's
  last slice, not this one.

## Context

`SettingsTrayDestination.pedal` exists because of #440: pedal assignment and
MIDI-learn were unreachable on the console build, and the fix was to give the
footswitch plate its own rail destination. That destination carries a
`PedalTrayPanel` — a scale diagram of the real top plate — which is why
`_TrayFaceFrame` grew a `fixed` landscape variant sized 980x700: the plate is
846:406.6, and stretching it to the sheet distorts the thing being pointed at.

The MIDI side has no console home at all. Its mapping UI is a section of the
Settings scroll, reachable only by leaving the tray.

## The shape

### One destination, two tabs, and the domain names itself first

The Control face puts its **title above the tab strip**, where the Network face
puts the tabs first. That is the mockups' own distinction and it survives being
questioned: a Network tab carries a power switch and needs a title row to hang
that switch on, so its name arrives per tab. Neither Control tab carries a
per-tab control, so the domain says its name once, at the top, and the tabs sit
under it.

The tab lives in `SettingsTrayState` next to `networkTab`, for the same reason:
returning to a domain lands where you left it. Like `NetworkTab`, `ControlTab`
is a Flutter-free enum — the tray cubit stores it and must not import a widget
library to name a value it holds.

### Pedal: a target list, not a plate

The plate does not come across. It is a picture of hardware you are standing
on; what this surface is for is *choosing a target*, which is a list. So the
tab is switch cards over an assign list, and the fixed landscape frame goes
with the plate.

Assignable switches only. **Mode and Bank can never hold a binding by rule**
(B12) — Mode is the only way out of FX mode, Bank the only way to reach the
other four track switches — so they get no card.

The assign list puts **chain targets first** and individual effect slots one
tap further down behind *Show individual effects*. That order is a claim about
durability, not about frequency: a binding to a chain survives its contents
being re-arranged, while a binding to one slot breaks when that slot moves.

Two marks that must not collide: tint already means *the row you opened*, so
the currently-assigned target is marked with a **check**, not a tint. A binding
whose target no longer resolves takes the **warning** tone — rendering a
missing target in the muted grey of "unassigned" states a different and wrong
fact.

Editing writes to the **global** binding set even when a session remap is in
force, promoting it. That is the full-screen plate's existing rule, and the two
surfaces must not disagree about where an edit lands.

### MIDI: device, then mappings

Two stacked things, because they answer different questions — *is anything
delivering MIDI at all*, and *what are its controls wired to*.

- A device row and a status card: connection state, and traffic.
- The fixed transport CC map, stated and not editable. It is the protocol the
  pedal firmware and any generic controller both speak.
- Every global mapping as a row that opens onto its own calibration: **LO/HI**
  for a sweep, a **threshold** plus Toggle/Momentary for a switch, over **Relearn**
  and **Remove**.
- Listening and the replace prompt ride as the list's banner rather than as
  modals, per `midi-listening` and `midi-replace`.

The mappings are global — they follow the rig, not the loaded session — and the
surface says so in words before anyone invests in a layout.

## Tasks

1. Promote the Network slice's primitives to a console-wide surface and drop
   the domain prefix, now that a second caller exists. Grow it with only what
   this face needs.
2. Add `ControlTab` and carry it in `SettingsTrayState`; rename the tray
   destination `pedal` → `control`; retire `PedalTrayPanel` and the fixed
   landscape frame with it.
3. Build the Pedal tab: transport switch cards, the target list, and the
   assign write path.
4. Build the MIDI tab: device row, status card, fixed CC map, mapping rows and
   their calibration editors, banner states.
5. Name the footswitches once, beside the binding model, so the console and the
   pedal agree about which switch is being discussed.
6. Regenerate and eyeball the goldens — the rail gains an entry, so every
   golden that photographs the rail moves.

## Testing

- Standard verify loop from `CLAUDE.md`: `flutter test`, `dart analyze`,
  the native engine suite.
- The Control face carries its own widget tests: the tab strip swaps the body,
  the transport cards and track rows render, selecting a switch lists what it
  can drive, individual effects appear one tap down, choosing a target assigns
  it; and on the MIDI side, the device/status/mapping stack, each device fault
  telling itself apart, traffic reported only on a live link, a mapping opening
  to its calibration, removal, and the add buttons being inert with no device
  attached.
- Goldens only ever photograph settled states, so any animation work needs
  mid-animation assertions of its own.

## What the build discovered

Everything below came out of building it. None of it was foreseen.

### The shared surface had to be promoted, not copied

#516 anticipated this in one parenthesis — the primitives were "to be renamed
for the console rather than the domain once a second caller exists" — and that
is exactly what happened, in the same PR as the second caller.
`lib/network/network_surface.dart` (778 lines) moved to
`lib/common/console_surface.dart` and every `Network*` symbol lost its prefix.
Doing it in the same PR is why the diff is large (+3635/-1038 over 33 files):
the WiFi and Bluetooth bodies and their tests are rewritten to the new names,
and the Network goldens move with the rail.

The surface also grew, and the additions are all things a *list-shaped* face
needs that a *radio-shaped* face did not: a group label, a leading slot on a
row, a value bar, a segmented control, a picker sheet. The picker is the one
worth arguing about — Material's popup menu is a mouse-sized floating card, and
every list in this tray is a 70px row, so the sheet is built from the same rows
as everything else rather than borrowing a control designed for a different
input device.

### The animation was wrong in three ways that only a real tap shows

The expansion the Network slice shipped looked fine in a golden and wrong under
a finger:

- **The fade never ran.** `AnimatedOpacity` animates when its *value* changes,
  and the value passed was a constant `1`. The chips arrived fully lit on frame
  one while the box was still growing under them.
- **Closing did not animate at all.** The caller stops building its actions the
  moment a row shuts, so `AnimatedSize` was left shrinking an empty box: the
  chips vanished, then a gap collapsed behind them. `ConsoleExpansion` became
  stateful and holds the last child for exactly as long as the close takes.
- **The border moved the content.** A border in `decoration` insets what it
  wraps, so the title and its chips stepped a pixel sideways and back on every
  open. It is painted as a `foregroundDecoration` now — over the row, not
  around it, with no layout effect in either state.

Two more followed: the press lit only the top 70px of an open card (the ink
well splashed inside the row, not the card), and the divider snapped on and off
at the frame of the tap. Both fixed by moving the tap to the card and putting
the divider on the same animation as the tint. Open and close now share one
duration and matched curves with the disclosure rotation and the card tint, so
a row reads as one thing moving rather than three.

**The lesson for later slices: goldens photograph settled states only.** Four
mid-animation assertions were added to the Network face tests to cover this —
the strip's clip still growing three frames into an open, the chips still on
screen mid-close and gone once it settles.

### The first Pedal tab was invented at the keyboard, and looked it

The tab initially showed four cards, because the mockups draw four switches —
the prototype's pedal has four. **This pedal has ten**, and the four *track*
switches hold a binding each *per bank* (A3): eight assignable slots the face
was silently hiding, reachable only from the full-screen plate that the last
slice of this reorganisation deletes.

The first attempt to fix that was written straight into the widget and reverted
wholesale. The version that shipped was designed in `segno-ui.pen` first —
`pedal-selected`, `pedal-slots`, `pedal-bank-b`, `pedal-stale` — and came out
different: transport switches stay cards, track switches become a **list** under
an A/B selector, because eight cards outweighed the four above them. The bank
selector is the design system's mini toggle, the same control the stage header
uses, sitting beside the caption it qualifies rather than floated to the far
edge of a 1920px pane. It seeds from the bank the pedal is actually on — editing
the bank the performer is standing in is the common case, and starting anywhere
else invites an edit that appears to do nothing.

**Draw it before building it, even mid-slice.** The revert cost less than the
surface would have.

### External MIDI mapping had never worked in the shipped app

Not a regression this slice caused — a bug it made easy to notice.
`ControlCubit` takes an optional `controller` and `midiDevices`; `App` passed
neither. So `learnControllerBinding` returned on its first line, nothing
subscribed to the controller's binding events, and a device coming back
re-armed nothing. Add sweep / Add switch picked a target and then did nothing at
all, on any platform. Both repositories were already built and provided
app-wide — they were simply never handed to the one cubit that owns controller
intent, and the old MIDI-learn section in Settings was equally dead.

The fix is nine lines in `app.dart`, and the regression test pumps the real
`App` and asserts a learn actually starts. **A face built to a design is a
functional audit of the state behind it**; the design asked a question the old
UI never had to answer.

The same instinct produced the device-fault work: the status line said "no MIDI
device" for every state that was not connected, while the repository already
tells four apart — `none`, `deviceGone`, `error`, `connecting`. The mockups draw
three of them as their own screens. Collapsing them sends the operator looking
in the wrong place. The traffic line also stopped reporting on a link that does
not exist.

### The mockups assume a concept the rig does not have

The `CONTROL / pedal` screens list assignment targets by **user-given rack
names** — "Dirty rhythm", "Bus tape". The rig has no such thing: a chain is
identified by *where it sits*, and nothing names, saves or loads one. So the
rows use the app's own `bindingTargetLabel` vocabulary ("Track 3 chain") with
the stage down the right-hand edge, and an effect row is named by its slot
rather than repeating its chain.

This was recorded as a divergence rather than improvised around, and it was the
right call: the same gap turned up again in the Signal face slice
([#533](https://github.com/tomassasovsky/segno/issues/533)), where it is
load-bearing rather than cosmetic, and was split out as
[#535](https://github.com/tomassasovsky/segno/issues/535) — a rack model,
persistence, a MODIFIED rule and a library UI, filed `autonomy:plan-gate`
because the persistence scope and the MODIFIED rule are direction calls.
**Naming racks is its own feature; two faces now read "no rack" until it
lands.**

`Simulate input` — the one remaining piece of `control-midi` — was likewise
filed rather than improvised, as
[#519](https://github.com/tomassasovsky/segno/issues/519): it needs a
synthetic-event entry point in the controller pipeline, and the per-row case
has no design yet.

### The stacked PR died when its parent merged

**PR #517 was auto-closed by GitHub when its base branch was deleted by the
#515 squash-merge.** Nothing was lost — the branch and its commits were intact
— but a closed PR cannot be retargeted or reopened, so the work was re-opened
as #521: same branch, rebased onto `master` with `git rebase --onto` so the
parent's now-squashed commits are not replayed.

The process lesson, for every stacked PR after this one:

- A child PR's base branch is deleted the moment the parent squash-merges.
  Plan the rebase *before* the parent merges, not after.
- Do not merge `master` into a stacked child — it breaks the child's merge-ref
  and CI goes quietly absent.
- Re-open under a new number rather than fighting the closed one, and say so in
  the body so the trail from the issue is not lost.

### Smaller things worth carrying

- The rail now reads **Controls** (the tray home face) next to **Control**
  (this domain). Renaming the home face now would invent vocabulary the design
  does not have — the mockups have no home face at all — so the clash resolves
  when the home face goes in the parent plan's last slice. It was documented on
  the PR rather than papered over.
- The rail's Control glyph is a foot controller, not a keyboard: the domain
  covers the floor pedal and whatever MIDI box is beside it, and neither is a
  piano.
- `ConsoleBanner`'s action became optional, for the idle notice at the head of
  the mapping list: it has nothing to offer but the explanation.
- The screenshot driver needs an explicit empty ticker, and the pedal
  repository's hotplug poll timer must not outlive the widget tree — the
  binding fails a test that leaves one pending.
- Retiring `PedalTrayPanel` also retired its tests. The #440 destination's
  three widget tests went with the destination; that is the intended direction
  per `AGENTS.md` (remove obsolete paths, do not keep compatibility layers).

## Precedent this set

`lib/common/console_surface.dart` is now the console's shared vocabulary, and
every domain slice after this one is assembled from it rather than inventing
rows. What this slice added, and what became of it:

| Added here | Used since by |
|---|---|
| `ConsoleGroupLabel` | Audio (Device / Recording / Status), Loop (Tempo / Click / Mode), Tracks routing sheet, System (Display / Updates / Storage / About) — the most-reused symbol of the set |
| `ConsoleRow` `leading`, `selected`, `indented`, `centred`, `valueColor` | every later face; `indented` and `centred` carry the assign list's shape, `valueColor` the stale-binding tone |
| `ConsoleValueBar` | the MIDI calibration editors, and the Loop face's Click tab |
| `ConsoleSegment` / `ConsoleSegmented` | the MIDI switch behaviour toggle |
| `ConsoleMiniToggle` | the Pedal tab's A/B bank selector |
| `showConsolePickerSheet` | the MIDI device and target pickers, and the Loop face's Mode tab |
| `ConsoleExpansion` (stateful, both directions animated) | Audio Device and Recording tabs, the Tracks routing sheet, the MIDI mapping rows |

Later slices grew the file further (a toggle chip and a chip dialog, and the
value bar became stateful). The rule the promotion established holds: **a
primitive lives in `lib/common/console_surface.dart` once a second domain reads
it, and keeps no domain in its name.**

## Exit criteria

- One Control rail destination with two tabs; the Pedal-only destination and
  its panel are gone, not deprecated.
- Both tabs drawn to their `CONTROL / *` screens, including the device-absent
  and failure states.
- No new mapping or binding state — the face reads what `ControlCubit` and
  `MidiSetupCubit` already own.
- Divergences from the mockups filed as issues, not improvised in the widget.
- `flutter test`, `dart analyze`, `dart format` and the native engine suite
  clean; goldens regenerated and eyeballed against `CONTROL / control`.

## Non-goals

- **No pedal plate on this face.** The full-screen plate keeps its own life
  until the parent plan's last slice deletes Settings.
- **No new mapping engine, no protocol change, no firmware change.** The fixed
  transport CCs are stated, not edited.
- **No named racks.** The gap is documented and filed (#535); this face uses
  the app's own target vocabulary.
- **No `Simulate input`** (#519).
- **No tray home face removal**, and no `Bright` rail entry — those land last.
- **No renaming of the home face** to resolve the Controls/Control clash.
