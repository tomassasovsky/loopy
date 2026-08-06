---
title: "feat(console): merge WiFi and Bluetooth into one Network rail domain"
type: feat
date: 2026-08-05
issue: 498
parent-plan: 2026-08-05-feat-console-ia-plan.md
retrofitted: 2026-08-06
shipped: "PR #515"
---

> **This document was written after the work shipped**, from issue #498, the
> merged PR [#515](https://github.com/tomassasovsky/segno/pull/515) and the
> code on `master` (merge commit `321183d3`, branch
> `feat/console-ia-network-domain`). It is the missing `docs/plan/` artifact
> for a slice that went straight to build, and it records the decisions and
> what building them turned up — it did not predict them. Where it reads
> prescriptively, that is the house voice describing a shape that is already
> in the tree, not a forecast.

> **Tracking:** this slice had **no issue of its own.** It rides on #498, the
> IA epic, and its PR says `Refs #498` deliberately rather than `Closes` —
> Network is one of seven domain slices and closing the epic on the first one
> would have been wrong. Labels as merged: `area:console`,
> `autonomy:merge-gate` **and** `autonomy:blocked-verify` — merge-gate for the
> UI taste call, blocked-verify because the bluez half cannot be proven off a
> radio. Size: 58 files, +4029 / −846.

## Overview

The console rail spent two of its eight slots on radios: one for WiFi, one for
Bluetooth. Issue #498 calls that "the same waste as one bucket for twelve
groups" — the same charge it levels at the Settings page — and gives the table
one **Network** entry with two tabs.

This is **slice 6 of the issue's suggested list and the first one built.** It
was taken first for a reason that has nothing to do with the table's order:
Network is the only domain whose two faces both already existed
(`WifiTrayPanel`, `BluetoothTrayPanel`), so it could prove the
domain-plus-tabs pattern without also lifting content out of the Settings
scroll. It also had `PillTabs` waiting for it, landed by #491 for exactly this
purpose.

Being first, it is also where the rest of the IA's vocabulary got written. The
row and card primitives, the face conventions and the tab-state model all
originate here; every later domain reads from them rather than drawing its
own. That inheritance is the section "Precedent this set" at the end, and it
is the reason this slice is worth a plan document at all.

## Dependencies

- **#491** — landed `PillTabs` and the tray rail/tab work this builds on.
- **#512, #513, #514** — merged before this branch was cut; master was green
  at 1468 tests when it started.
- `segno-ui.pen`, screens `NETWORK / *` (17 of them), as the design of record.
  `docs/design/console-prototype.html` is **stale** — it predates #498's own
  table and still lists Settings / WiFi / Bluetooth as rail entries. The
  `.pen` file wins, and each of its screens carries a `c/<screen>` note giving
  the rationale for what it draws.
- No dependency on any part of #442, and none of them on this.

## Context

Both radios already worked end to end: `wifi_client` / `bluetooth_client`
wrapping the appliance helpers `segno-wifi-ctl` / `segno-bt-ctl`, repositories
over those, cubits over those, and an in-tray panel each. Nothing about the
transport needed changing to merge two rail entries into one.

The obstacle was **chrome, not the rail.** Each panel was a title bar and a
body in one widget:

```
WifiTrayPanel      = HostTrayChromeBar(title, onBack, trailing: scan) + body
BluetoothTrayPanel = HostTrayChromeBar(title, onBack, …)              + body
```

Putting both under one destination stacks two title bars. So the first real
task was never "add a tab strip" — it was to split each panel into a
chrome-less body and decide who owns the chrome above them. That decision is
the one that repeats for every remaining domain, which is why it was worth
getting right on the slice with the least content to move.

## The shape

### One destination, and a tab that is not a destination

`SettingsTrayDestination.wifi` and `.bluetooth` collapse into a single
`.network`. **Which radio is showing is not a destination** — it is
`SettingsTrayState.networkTab`, a `NetworkTab` enum with `wifi` and
`bluetooth`.

The consequences are the point of the split:

- The tray home tiles keep landing on a specific radio (long-press a tile, or
  switch one on) because those shortcuts now open the domain **at** a tab:
  `openWifi()` and `openBluetooth()` both funnel into one private
  `_openNetwork(NetworkTab)`.
- `showNetworkTab(tab)` moves the tab and deliberately does **not** touch
  `destination` — the strip is only reachable while Network is already
  showing.
- Closing the tray resets `destination` and not `networkTab`, so returning to
  Network lands where it was left.

`NetworkTab` lives in its own Flutter-free file, because the tray cubit holds
the value and the panel draws the strip, and a cubit must not import a widget
library to name something it stores.

The rail entry gets `Icons.settings_input_antenna` and `l10n.trayNetworkLabel`
— an antenna rather than a WiFi fan or a Bluetooth rune, because either
radio's own glyph would read as only that one. The entry is filled from the
first commit, per the issue's rule that a rail entry is never empty.

### The face conventions

Drawn to `NETWORK / *`, and stated here because every later domain inherits
them:

- **No chrome bar and no back chevron.** The rail is always on screen; a
  second way back would be a second navigation surface. `NetworkTrayPanel` is
  a `PillTabs` strip, a 14px gap, and the body — nothing above the strip.
- **Each tab owns a title row** (`NetworkFaceHeader`) carrying that radio's
  own rescan button and its **power switch**. Power lives there because power
  decides whether the rest of the face exists: switched off, that row *is* the
  face, and the list is not drawn at all. There is nothing truthful to list
  about a radio that is down.
- **One card of 70px rows**: `title / subtitle` on the left, a state word
  (`connected` / `saved` / `open` / `paired`) and a disclosure marker on the
  right. The marker gutter is reserved per group rather than per row, so rows
  without a chevron still line their titles up with rows that have one.
- **Rows open in place** into a tinted, bordered card carrying their actions —
  Disconnect / Forget for a known network, Connect for a paired device that is
  idle. Everything else acts on tap.
- **Destructive confirms; reversible does not.** Forget deletes a credential
  and goes through `showNetworkForgetDialog`; disconnect is undone by tapping
  the row again and asks nothing.
- **In flight and failure are a banner at the top of the list, not a dialog**:
  amber dot plus Cancel while joining or pairing, red dot plus Try again after
  a refusal, with the live state echoed beside the title.
- **The console has one keyboard.** Joining a secured network opens the
  mockups' sheet — title, masked field with a live caret, keys built in.
- **Bluetooth adds the console's own visibility card** (Discoverable /
  Broadcast with their subtitles), bordered, because those switches belong to
  the adapter rather than to any device.

### The shared vocabulary

The row and card pieces went into `lib/network/network_surface.dart` rather
than into either face, so the two tabs of one domain cannot drift apart the
way the two former panels had: `kNetworkRowHeight`, `NetworkCard`,
`NetworkRow`, `NetworkDisclosure`, `NetworkExpandedRow`, `NetworkActionChip`,
`NetworkFaceHeader`, `NetworkSwitch`, `NetworkBanner`, `NetworkSmallButton`,
`NetworkEmptyCard`, and `showNetworkForgetDialog`.

Two of those are more than layout:

- `NetworkSwitch` is hand-drawn — a 53x31 pill with a 25px knob — rather than
  Material's `Switch`, which brings its own 40x24 geometry, ripple and thumb
  elevation, none of which the mockups have and all of which read as borrowed
  once the switch sits in a list row. #498 also settles that booleans are
  switches and never the words "on"/"off".
- `NetworkCard` carries a 1px inset because rows paint their hairline edge to
  edge; the inset keeps that hairline inside the rounded corner instead of
  cutting across it.

## What the build discovered

This is the part no plan written beforehand would have contained.

### The first cut was to the old shape, and had to be redone

The branch's first commit did the merge honestly and kept the panels' existing
shapes: one `HostTrayChromeBar` owned by `NetworkTrayPanel`, chrome-less
bodies below it, and — because rescanning is a WiFi verb on one tab and a
Bluetooth verb on the other — each feature exporting its own `*ScanAction`
that the domain hoisted into the shared bar for whichever tab was showing.
That is a sound design, and it is not what the mockups draw.

The second commit rebuilt the domain against the 17 `NETWORK / *` screens and
**deleted the chrome bar entirely**, moving the rescan control down into each
tab's title row next to its power switch. The hoisted-trailing-action
mechanism died with it. The lesson generalises: reading the `.pen` screens
first would have saved a whole cut of the domain, and it is why the later
slices start from the mockups rather than from the widgets they are replacing.

### Bluetooth had no device actions at all

The Network face needs Connect, Disconnect, Pair and Forget. `BluetoothClient`
stopped at status / scan / power / discoverable / advertise — every verb the
face is built around was missing. The gap was closed down the whole stack in
this slice:

- `BluetoothClient.pair / connect / disconnect / forget`, through the
  repository, with matching implementations in the system client and the
  unsupported one.
- `BluetoothDevice` gains `paired`, `connected`, `inRange` and `kind`. Paired
  devices are listed even when out of range, for the same reason saved
  networks are: a pairing you cannot see is still a pairing you may want to
  drop.
- `segno-bt-ctl` grows the matching verbs, and the ordering inside them is the
  part that bites: **pair** runs discovery first (an unseen device is not
  pairable), then pairs, then trusts so the device may reconnect after a
  reboot, then connects; **forget** disconnects and un-trusts before removing.
  `scan` now reports per-device detail parsed out of `bluetoothctl info`,
  mapping the `Icon:` field to a readable kind.
- Every device verb reports only success or failure. The cubit re-reads `scan`
  and `status` afterwards rather than trusting the verb's account of what it
  changed, because bluez can accept a command and leave the device as it was.
- `run_bt_ctl_tests.sh` pins that ordering against a stubbed `bluetoothctl`,
  and is wired into `main.yaml` beside the other helper suites.

This is what earned the PR its `autonomy:blocked-verify` label: the command
ordering is tested, what bluez does with it is not.

### Pairing is not "busy"

`BluetoothState.busy` was the wrong marker for pairing. Pairing waits on a
human pressing a button on a device, which can take as long as it takes, so it
got `pairingAddress` of its own plus a `cancelPairing()` — the list stays live
behind the pairing banner instead of freezing on it. WiFi needed the mirror of
this: `failedSsid`, tied to the error it explains so a stale SSID can never
outlive the message that named it, and `cancelConnect()`, which drops the
in-flight marker and disconnects, because the helper call itself cannot be
recalled once issued and that is the only thing still true afterwards.

### The join sheet cannot use a `TextField`

The obvious implementation — a dialog with a real text field over the app-wide
on-screen keyboard host — does not work on this console. That host is driven
by *field focus*, so focusing the field summons a second keyboard panel
underneath a dialog that is itself trying to centre in what is left. The sheet
therefore **holds its own text** and listens for physical keys itself (for
desktop builds and for a console with a USB keyboard attached). It also drops
Material's 640px bottom-sheet cap, which would have made a toy of a keyboard
on a 1920px console. WPA2's 8-character floor is checked in the sheet, where
it can be corrected, rather than handed to the helper and returned seconds
later as a generic association failure.

### Two design-system corrections fell out

Neither was in scope; both were wrong once there was a design to check against.

- **`PillTabs` did not match the DS `Tab`.** It had been drawn before the
  strip had a design: 7px radius, 14/7 padding, 13px label, and a selected
  state tinted with translucent accent. It becomes 8px radius, 17/10 padding,
  16px label, and the flat `accentSurface` token — an alpha tint reads as a
  different colour on each of the several backgrounds the strip sits on. This
  also corrects the FX stage strips, which use the same widget.
- **`OnScreenKeyboard` was built from `FilledButton.tonal`,** which brings its
  own container colour, elevation overlay and 40px minimum geometry — the
  reason it never looked like the console it lives on. It is now drawn with
  surface tokens, and gained an optional digit row (`showNumberRow`;
  passphrases are full of digits and a layer switch per digit is unusable
  standing over a console) and a named action key (`doneLabel`, "Join" here).

### The desktop cannot run this domain at all

Both radios are Linux-only appliance helpers, so on macOS every path past "no
WiFi on this build" is unreachable — including the paths with the most
behaviour in them. That made the domain with the richest interaction the one
surface that could not be exercised while building it.

`--dart-define=SEGNO_FAKE_RADIOS=true` swaps in in-memory stacks. The flag is
read inside `createWifiClient` / `createBluetoothClient` **before** their
platform test, so every entry point picks it up with no app wiring change. The
fakes are opinionated rather than empty, because the point is to reach the
states the mockups draw: a saved network in range, a saved one out of range,
an open one and an association to start from; a connected device, a paired but
absent one, and a fresh one. Delays are deliberate — a scan that resolves
between frames never shows its spinner. Failure is reachable on purpose:
`segno123` is the passphrase that works, anything else fails the way the
supplicant does, and one device always refuses to pair. Off by default, so a
shipped build can never present invented networks as real ones; the factory
tests assert the flag from both sides, so the branch is covered by the
ordinary CI run as well. Documented in `docs/PROGRESS.md`.

### Two things the app still cannot source

The rows show what exists rather than what the mockups draw:

- **Link speed** — the mockups put `260 Mbit/s` on a connected row; the WiFi
  helper reports no rate.
- **Device kind** for devices bluez gives no `Icon:` for.

## Tasks, as executed

1. Split `WifiTrayPanel` / `BluetoothTrayPanel` into chrome-less
   `WifiTrayBody` / `BluetoothTrayBody`; delete the old panels.
2. Collapse the two destinations into `SettingsTrayDestination.network`; add
   `NetworkTab` and `SettingsTrayState.networkTab`; re-point the tray home
   shortcuts and the rail's icon/label.
3. Add `NetworkTrayPanel` — the tab strip and the body switch, and nothing
   else.
4. Rebuild both faces to `NETWORK / *`, extracting the shared row/card
   vocabulary into `network_surface.dart` as the second face needs each piece.
5. Add the WiFi join sheet with the keyboard built in.
6. Close the Bluetooth device-action gap through client, repository, cubit and
   `segno-bt-ctl`; add `run_bt_ctl_tests.sh` and wire it into CI.
7. Add the fake radio stacks behind `SEGNO_FAKE_RADIOS`.
8. Correct `PillTabs` and `OnScreenKeyboard` to the design system.
9. Regenerate and eyeball the goldens; rename the two that changed identity.

## Testing

As reported on the merged PR:

- `flutter test` — 1491 pass, including 13 new face tests in
  `test/network/network_faces_test.dart` covering power, open-row actions,
  forget-confirms, the join sheet and its passphrase floor, and pairing; plus
  updates to `settings_tray_cubit_test.dart` and `settings_tray_test.dart` for
  the destination collapse, and new fake-client tests in `wifi_client` and
  `bluetooth_client`.
- `dart analyze` clean; `dart format` clean.
- `bash packages/segno_engine/src/test/run_native_tests.sh` — all passed.
- `bash deploy/yocto/.../test/run_bt_ctl_tests.sh` — 11 pass.
- Goldens regenerated and eyeballed against the mockups.
  `control_center_wifi.png` and `control_center_bluetooth.png` become
  `control_center_network_wifi.png` / `control_center_network_bluetooth.png`,
  joined by `_wifi_off`, `_wifi_expanded`, `_wifi_forget`, `_wifi_join` and
  `_bt_expanded`; `control_center_tray.png` changes because the rail lost an
  entry. The screenshot suite self-skips off an absolute path into the
  author's font cache, so this is a deliberate local step.
- 167 strings added to each of `app_en.arb` and `app_es.arb`.

## Exit criteria, as met

- The rail shows one Network entry, filled, with WiFi and Bluetooth as tabs of
  it; no destination exists for either radio alone.
- The tray home shortcuts still land on a specific radio, and the tab survives
  leaving and returning to the domain.
- Both faces are drawn from one shared vocabulary, so neither can drift.
- Every device action the face offers exists all the way down to the helper,
  with its ordering pinned by a shell test.
- Full suite, native tests and analysis green; goldens regenerated and looked
  at.

## Precedent this set

Everything below was written here first and inherited by Control (#521), Loop
(#522), Tracks (#524 / #531), Audio (#534) and System (#532).

- **The shared surface vocabulary.** `lib/network/network_surface.dart` was
  the first console primitive library. The Control slice moved it to
  **`lib/common/console_surface.dart`** and dropped the `Network` prefix once
  a second domain read from it (commit `2f497373`) —
  `NetworkCard`→`ConsoleCard`, `NetworkRow`→`ConsoleRow`,
  `kNetworkRowHeight`→`kConsoleRowHeight`, and so on through
  `ConsoleExpandedRow`, `ConsoleActionChip`, `ConsoleFaceHeader`,
  `ConsoleSwitch`, `ConsoleBanner`, `ConsoleSmallButton`, `ConsoleEmptyCard`
  and the forget dialog. It has since grown a group label, a value bar, a
  segmented control, a picker built from the same rows, toggles and chips —
  but the 70px row, the 12px card with its 1px inset, the reserved disclosure
  gutter and the hand-drawn switch are all the ones defined here.
- **The face conventions**: no chrome bar and no back chevron on a domain
  face; a per-tab title row carrying that surface's own controls; one card of
  70px rows; rows that open in place into a tinted card of actions;
  destructive actions confirm and reversible ones do not; in-flight and
  failure ride as a banner at the top of the list rather than a dialog.
- **The tab strip.** `PillTabs` corrected to the DS `Tab` metrics here is the
  strip every later domain uses, and the pattern of a stateless domain panel
  whose selected tab is held by `SettingsTrayCubit` — so a shortcut can open a
  domain *at* a tab, and returning to it lands where it was left.
- **`OnScreenKeyboard`** as a DS-token surface with an optional digit row and
  a named action key, used directly by surfaces that need keys inline instead
  of through the focus-driven host.
- **The `.pen` is the design of record**, screen by screen, with its `c/`
  notes as the rationale; `console-prototype.html` is stale and should not be
  read as the design.
- **Build a domain from the mockups, not from the widgets it replaces** — the
  one lesson bought the hard way here.

## Non-goals

- Not a reskin. Token, colour and type work belongs to #499; this slice
  touched `PillTabs` and `OnScreenKeyboard` only because their metrics were
  demonstrably wrong against the DS component they claim to be.
- Not the whole IA. Six domains and the Signal fold-in remained after this,
  and Settings stays reachable until its content has somewhere else to live —
  hence `Refs #498` rather than `Closes`.
- No protocol, firmware or engine change. The only native-side work is
  `segno-bt-ctl`, an appliance helper script.
- No claim about bluez. The commands and their ordering are tested; the radio
  behaviour behind them needs hardware.
