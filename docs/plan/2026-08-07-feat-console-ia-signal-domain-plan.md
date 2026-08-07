---
title: "feat(console): Signal domain — the last IA slice"
type: feat
date: 2026-08-07
issue: 533
parent: docs/plan/2026-08-05-feat-console-ia-plan.md
designs: "segno-ui.pen — 12 `SIGNAL / *` frames"
split_out: 535 (racks)
autonomy: merge-gate
reviewed: 2026-08-07 (/plan-technical-review — simplicity, VGV, plan-splitting)
---

> Written **before** the build, unlike its six siblings. The parent plan's
> process note names the tell it is answering: *an issue created at
> `stage:build` with no plan doc*. #533 was exactly that.
>
> **Revised after `/plan-technical-review`.** The review caught four factual
> errors in the first draft — a capability claimed missing that already ships
> (`FxScope.moveEffect`), a resolution placed in a boot-only code path, a
> directory layout that matched no shipped face, and ~2,800 lines of
> demolition left unaccounted. All are corrected below and marked **[R]**.

## Overview

Signal is the last of the seven console IA slices, and the only one that does
not replace a settings group. It replaces a **shipped, tested, full-screen
surface** — `lib/looper/view/signal_graph/`, 5,698 lines, with its own
three-pane layout, tap-to-trace, knob rack, FX dock and plugin browser.

The premise is that this is **reconciliation, not a rewrite of the
behaviour** — and the evidence is stronger than expected:

**The mockups' tab strip *is* the app's own FX addressing model.**
`packages/looper_repository/lib/src/models/fx_address.dart:9` declares
`enum FxStage { input, loop, track, master }`. The design draws four tabs
labelled `input · loop · track · master`. Same four things, same order.
`FxScope` (`lib/looper/view/fx_editor/fx_scope.dart`) is already the
scope-agnostic adapter over one chain at any of them — including
`moveEffect(int from, int to)` at `:105`, implemented at `:199`, `:334` and
`:475`. **[R]** The first draft said chain reordering did not exist. It does,
as an arbitrary-index move — a superset of what `◀`/`▶` needs.

**The console vocabulary already carries the FX fader.**
`ConsoleValueBar` is `height: 53` (`console_surface.dart:1386`),
`labelWidth: 106` (`:1390`), `readoutWidth: 94` (`:1393`). Measured off
`SIGNAL / fx-edit`: row 53 tall, label column 106, readout column 94, 14px
gaps. Not approximately — exactly.

What is actually new is the **card**, the **drag-reorder strip**, and two small
changes to shared widgets. Everything else composes.

## Direction calls

### 1. The tray face replaces the full-screen route — decided by the user

> "This is quite simple: the current implementation will be gone. We won't
> have it anymore. That's why we're doing all of this."

`showSignalPage` and the three-pane surface are **removed**.
`SettingsTrayDestination` gains `signal` in first position; the Signal tile
leaves the tray home face.

This closes the exception recorded in prose at
`lib/looper/view/tray/tray_navigation_rail.dart:19` — *"Settings and the Signal
page still push full-screen routes and so stay tiles on the home face"* — and
the identical exception in `lib/looper/cubit/settings_tray_state.dart:5-9`.
**Both comments die with the thing they describe.** **[R]**

**Not in this slice:** removing `SettingsTrayDestination.home`. The mockup rail
draws eight domains and no `home`; the shipped rail draws `home` + seven.
Deleting `home` also has to answer what happens to `Bright` and to the Settings
tile. The parent plan already lists "the tray home face" as its own remaining
item.

### 2. Racks are out of scope — delegated to me, decided here

#535 (`stage:plan`, `autonomy:plan-gate`) owns two unanswered questions:
rig-global vs session-bundle persistence, and what "modified" means. Both are
easier to change before anything reaches disk.

**This slice builds the mockups' own empty state.** Every card renders
`no rack` / `tap to load one`. Not built:

| Not built | Where it appears |
|---|---|
| `SIGNAL / library`, `rack-new`, `rack-delete` | three whole screens |
| The `Rack library` header button | every `signal-*` and `fx-*` screen |
| The `rack` caption + rack chip row | `signal-detail`, `fx-edit`, `fx-plugin`, `fx-reorder` |
| The `MODIFIED` badge | `signal-input` |
| A card's rack name (accent) | every card |
| The panel's rack-name title + `✎` rename | `signal-detail` and the three `fx-*` |

This is #535's own proposal: *"#533's face ships first and reads 'no rack'
until this lands, which is the mockups' own empty state."*

**Consequence for the panel title.** With no rack there is no name to show. It
falls back to the card's own name — `rhythm` — with the same subtitle. The `✎`
is omitted: renaming a rack is a rack feature, and *track* rename already lives
on the Tracks face.

### 3. Monitor `AUTO` means "follow record-arm" — delegated to me, decided here

The mockups draw `off / auto / on`; `InputMonitor.enabled` is a `bool`.

**`AUTO` = monitor while any lane fed by this input sits on a track that is
armed or capturing.** `ON` = always. `OFF` = never.

**[R] The first draft got both the predicate and its home wrong.**

*The predicate is a fan-in, not a 1:1.* There is no "the input's track": a
**lane** records one `Lane.inputChannel` (`models/lane.dart:28`), and
`LooperRepository._laneInput` (`:242`) is keyed `(channel, lane) → input`. One
input can feed lanes on several tracks. The real rule:

```
auto ⇒ enabled = any lane L where L.inputChannel == input
                 on a track T where T.pending || T.isCapturing
```

`Track.pending` is the waiting quantized arm; `Track.isCapturing` is
`recording || overdubbing` (`models/track.dart:137`).

*The home is `LooperRepository`, not `MonitorCubit`.* The draft put resolution
in `MonitorCubit._applyMonitor`, which has exactly one caller —
`monitor_cubit.dart:79`, inside `_restore()`. It fires **once at boot**. `AUTO`
would latch whatever the arm state was at launch and never move again.

`LooperRepository` already owns both halves and already owns the write:

| It has | Where |
|---|---|
| `_laneInput` — the `(channel, lane) → input` map | `looper_repository.dart:242` |
| the `setMonitorInputEnabled` write | `:737`, `:1556`, `:1564` |
| `Stream<LooperState> looperState` — the arm-state source | `:339` |

So resolution is a predicate evaluated where the data already is, re-run where
the repository already recomputes monitor gates on state change. **No new
subscription, no new lifecycle, no per-transition FFI write from a cubit.**

The cubit keeps what it should: `MonitorMode` is persisted user *intent* and
belongs on the repository model; the boolean the engine takes is *reality*,
derived downstream. That is the pattern `docs/PROGRESS.md:360-368` already
records — intent down, reality up.

**Override point.** If `AUTO` should mean something else, it is one predicate
in one file. Say so before PR 1 and nothing else moves.

## Scope boundary

The parent plan lists "scope arrived mid-build" as one of four things skipping
`/plan` cost. Stated exhaustively.

**In scope**

- `SettingsTrayDestination.signal` + rail entry + face routing.
- The four-tab face over `FxStage`, with the card grid per stage.
- The scope chips (`MONITOR ONLY`, `PRINTED INTO THE TAKE`).
- The `OUTPUTS` group on the master tab, **read-only** (see below).
- The in-place detail panel: level, in-the-mix, monitor tri-state.
- The FX editor block: one `ConsoleValueBar` per engine parameter, bypass,
  `◀`/`▶` (calling the existing `FxScope.moveEffect`), remove.
- Add-an-effect dialog, browse-all-plugins sheet, drag-to-reorder.
- The monitor tri-state: model, persistence, resolution, UI.
- Deleting the full-screen surface, its entry points, **and everything it
  orphans**.

**Out of scope, with its home**

| Out | Where it goes |
|---|---|
| Racks, in all forms | #535 |
| **Writing** the master output switches | #569 **[R]** |
| Removing `SettingsTrayDestination.home` / the tile grid | parent plan, "What remains" |
| Splitting `console_surface.dart` | #530 — see below |
| Tap-to-trace | **has no drawn replacement** — see Risks |
| `PillTabs` weight-on-selection | pre-existing debt across all six shipped domains |

**Packages touched.** Three, not one **[R]**: `lib/`,
`packages/looper_repository/` (the `MonitorMode` model + resolution), and
`packages/settings_repository/` — whose
`loadMonitorInputEnabled` / `saveMonitorInputEnabled`
(`settings_repository.dart:689-694`) are `bool` over `getBool`/`setBool` and
cannot round-trip a tri-state. The first draft never named it.

**The thing most likely to arrive as a surprise: tap-to-trace.** A real,
shipped, tested behaviour of the surface being deleted (`signal_rows.dart`'s
`inTag`/`outTag`/`trkTag` tag sets, covered by `signal_rows_test.dart`), and
**no `SIGNAL / *` screen draws anything like it**. The last PR deletes it. If
it should survive, it needs a screen first.

## Design measurement

Measured via Pencil MCP against `segno-ui.pen`, resolving variables and
instances. All 455 top-level frames were enumerated before deriving anything —
`SIGNAL / fx-add` and `SIGNAL / rack-delete` sit at positions 385 and 386, not
in the 8–17 block with the other ten, so a prefix read misses both.

### Shared face chrome — every `signal-*` and `fx-*` screen

| Element | Metric |
|---|---|
| Screen / tray sheet | 1920x1080 / 1918x1078, fill `#161618`, bottom stroke `#3a3a40` 1px, radius `[0,0,17,17]` |
| Rail | 180 wide; items 159x46, radius 11, gap 5, padding `[19,11,41,10]` |
| Rail item, selected | fill `#16233d`, label `#3b82f6` w600 fs17 lh1.18 |
| Rail item, unselected | no fill, label `#9a9aa2` fs17 lh1.18 |
| Content column | 1738 wide, padding `[19,19,41,19]`, vertical gap 14 → **inner width 1700** |
| Header row | 1700x40; title fs20 w650 lh1.15 `#f3f4f7` |
| Tab strip | 1700x38; pills padding `[10,17]`, radius 8, gap 5 |
| Tab, selected | fill `#16233d`, text `#3b82f6` fs16 lh1.13 |
| Tab, unselected | no fill, text `#9a9aa2` fs16 lh1.13 |
| Scope chip row | 1700x24; chip padding `[2,10]`, radius 119; text fs12 w650 ls0.72 lh1.5 |

Vertical rhythm, from absolute bounds: header @19 → strip @73 → chip @125 →
cards @163 → panel @392. Every step is `previous + height + 14`.

Tab labels are **lowercase**: `input`, `loop`, `track`, `master`.

| Tab | Chip | Size | Fill | Stroke | Ink |
|---|---|---|---|---|---|
| loop, track, master | `MONITOR ONLY` | 125x24 | `#26262a` | `#3a3a40` | `#9a9aa2` |
| input | `PRINTED INTO THE TAKE` | 186x24 | `#2a1214` | `#e5484d` | `#e5484d` |

These are `FxScope.consequence()` in chip form — the same strings the FX dock
header already carries as prose.

### The signal card

202 wide, gap 12, padding 18, inner gap 10, fill `#1e1e21`, stroke `#2a2a2e`
1px, radius 12. **Selected: stroke `#3b82f6` 1px.**

Height is content-driven: **196** with a one-line chain summary
(`signal-input`), **215** with a two-line one (`signal-loop`). One card whose
fifth row wraps within its 166px content width — not two card sizes.

| Row | Content | Type |
|---|---|---|
| 1 | name — `rhythm`, `guitar`, `master out` | fs18 w650 lh1.17 `#f3f4f7` |
| 2 | coordinate — `track 3 · lane A`, `input 1`, `main` | fs13 ls0.26 lh1.15 `#6b6b73` |
| 3 | routing — `→` + `mix` / `recorder` / `outputs` | `→` fs14 lh1.21; label fs13 lh1.23, both `#6b6b73`, label at +19 |
| 4 | rack name — **`no rack` in this slice** | fs16 w500 lh1.13 `#6b6b73` (loaded would be w600 `#3b82f6`) |
| 5 | chain summary — **`tap to load one` in this slice** | fs14 lh1.35 `#9a9aa2`, wraps at 166 |
| 6 | monitor — `MONITOR: ON` / `AUTO` / `OFF` | fs13 ls0.78 lh1.23; ON/AUTO `#3b82f6`, OFF `#6b6b73` |

**Row 6 is omitted on a card with no rack** — the `bass` card has five children
where `rhythm` has six, at the same 215px height, so it is a deliberate
omission and not a space constraint. *Absence is modelled, not defaulted*,
drawn correctly.

**[R] The first draft then got the rule backwards**, claiming a
loop / track / master card has no monitor row at all. It does:
`signal-loop` draws `MONITOR: AUTO` and `MONITOR: OFF` on its cards and
`signal-master` draws `MONITOR: ON`. The rule keys off the **rack**, not the
stage.

That has a consequence worth stating plainly, because racks are out of scope:
**every card in this slice is rackless, so no card on the loop, track or
master tab shows a monitor row.** The tri-state still ships and is still
editable — but only inside the detail panel. Those three faces say nothing
about monitoring until #535 lands.

**Inputs are the exception, and it is a decided one.** An input's monitor gate
is a fact about the jack, not about the chain on it — it is true or false
whether or not a rack is loaded, so an input card **always** carries its
monitor line. The design never drew a rackless input card; `SIGNAL /
signal-input` now does (the `aux` card, D11), so the contrast against
`signal-loop`'s vacant `bass` card is on record rather than inferred.

Master's card is the same card at full width: 1700x196.

### `SIGNAL / signal-loop` — the loop tab

Three cards: `rhythm` (track 3 · lane A, `MONITOR: AUTO`), `drums` (track 1 ·
lane A, `MONITOR: OFF`), `bass` (no rack, no monitor row). Chip `MONITOR ONLY`.

**Carried by:** `LooperBloc` → `signal_rows.dart`'s `TakeRow` / `TrackGroup`
(295 lines, no widgets, unit-tested) already flattens lanes into exactly these
rows including routing. `LaneFxScope` carries the chain. `l10n.trackName` names
the track.

**Does not exist:** the card widget; the tab-to-`FxStage` binding.

### `SIGNAL / signal-input` — the input tab

Two cards: `guitar` (input 1, `MONITOR: ON`), `mic` (input 2, `MONITOR: AUTO` +
`MODIFIED`). Card height 196. Chip `PRINTED INTO THE TAKE`.

`MODIFIED` badge (out of scope, measured for #535): 76x15, padding `[0,7]`,
radius 119, stroke `#e0a94a` 1px, text fs11 w600 ls0.66 `#e0a94a`, 7 after the
name.

**Carried by:** `MonitorCubit` → `InputRow`; `InputFxScope`; `l10n.inputName`
(slice 5, keyed `input_name.$device.$input`).

**Does not exist:** the tri-state.

### `SIGNAL / signal-master` — the master tab

One full-width card (1700x196, `master out` / `main` / `→ outputs`), then:

| Element | Metric |
|---|---|
| Caption `OUTPUTS` | fs13 ls1.2 `#6b6b73`, 30 above the card |
| Card | 1700, padding 1, fill `#1e1e21`, stroke `#2a2a2e` 1px, radius 12 |
| Row | 1698x70, bottom divider `#ffffff0b` 1px except the last |
| Label / sublabel | `Out 1` fs17 lh1.18 `#f3f4f7` over `main left` fs14 lh1.21 `#6b6b73`, gap 2, at x=20 |
| Switch | 53x31 radius 119, knob 25, inset 20 from the right |

Rows: `Out 1 / main left` (on), `Out 2 / main right` (on), `Out 3 / phones
left` (off), `Out 4 / phones right` (off).

**The switch is `ConsoleSwitch` exactly** — `trackSize: Size(53, 31)`,
`knobSize: 25`, `_inset: 3` (`console_surface.dart:1030-1035`).

**Does not exist:** a rig-level "this hardware output is live" flag.
`InputMonitor.outputMask` is *per input* — a different fact. **This is the one
capability the master tab needs and the app does not have.** See Risks.

### `SIGNAL / signal-track` — does not exist

The strip draws four tabs. The pen draws three. There is no `SIGNAL /
signal-track` frame anywhere in the 455.

**Derivation, stated so it is not silently invented:** the track tab is
`signal-loop` with `StageFxScope(FxStage.track)` — one card per track,
coordinate `track 3` (no lane), routing `→ outputs`, chip `MONITOR ONLY`, no
monitor row. It goes into the pen (D1) before any code lands.

### `SIGNAL / signal-detail` — the in-place panel

Selecting a card opens a panel **below the whole card row**, 14 beneath it. The
selected card takes an accent border. One at a time.

| Element | Metric |
|---|---|
| Panel | 1700 wide, padding 18, gap 14, fill `#1e1e21`, stroke `#3b82f6` 1px, radius 12; **546 tall** |
| Header | 1664x53; title fs23 w650 lh1.17 `#f3f4f7`; subtitle fs14 lh1.21 `#6b6b73` |
| Inline caption | `level` / `in the mix` / `hear while playing` — fs14 lh1.21 `#9a9aa2`, **sentence case** |
| Chip row | 38 tall; chips padding `[10,17]`, radius 8, gap 5 |
| Chip, selected | fill `#16233d`, text `#3b82f6` fs16 lh1.13 |
| Chip, unselected | no fill, text `#9a9aa2` fs16 lh1.13 |
| Level row | 1664x52, fill `#0b0b0c`, radius 10; bar inset 14, 1570x24, fill `#26262a`, radius 6 |
| Level fill | `#16233d` + 2px right edge `#3b82f6`; readout 52 wide at x=1598, fs14 `#9a9aa2` |
| Segmented | 1664x52, fill `#0b0b0c`, radius 11, padding 5, segment gap 5, segments 42 tall radius 7 |
| Segment, selected | fill `#3b82f6`, text `#ffffff` w650 fs16 lh1.13 |
| Segment, unselected | no fill, text `#9a9aa2` fs16 lh1.13 |

Two segmented controls: **`in the mix`** — 2-up, segments 825 wide,
`muted` / `heard`. **`hear while playing`** — 3-up, segments 548 wide,
`off` / `auto` / `on`.

Chain chips read `Drive`, `Tremolo`, `Reverb`, then `+ effect` as the last
chip — the add affordance is a chip in the strip, not a separate button.

**Carried by:** `FxScope.effects`; `LaneFxScope`/`InputFxScope` mix and volume.

**Does not exist:** the panel; the tri-state; a stretched `ConsoleSegmented`;
an accent border on `ConsoleCard`.

### `SIGNAL / fx-edit` and `SIGNAL / fx-plugin` — the editor

Selecting a **chain chip** opens the editor **inside the same panel**, between
the chain strip and `hear while playing`. Confirmed by height: 546 → 588
(2 params) → 651 (3 params), with `level` and `in the mix` **gone** from both.
The editor takes their place; the monitor segment stays.

| Element | Metric |
|---|---|
| Block | 1664 wide, padding 18, fill `#0b0b0c`, stroke `#2a2a2e` 1px, radius 12 |
| Param row | 53 tall, 63 pitch (gap 10) |
| Label | 106 wide, fs13 ls0.78 lh1.23 `#6b6b73`, **UPPERCASE** |
| Track | from x=120, 1400 wide, fill `#141417`, stroke `#ffffff12` 1px, radius 12 |
| Track fill | inset 1, 51 tall, fill `#16233d`, right edge stroke `#3b82f6` 2px |
| Readout | 94 wide at x=1534, fs14 lh1.14 `#9a9aa2` |
| Footer | 1628x53, top divider `#ffffff0d` 1px, 15 below the last param row |
| `bypass` pill | 76x33, padding `[7,14]`, radius 119, stroke `#2a2a2e`, fs14 lh1.21 `#9a9aa2` |
| `◀` / `▶` | 42x40, padding `[10,14]`, fill `#1e1e21`, stroke `#3a3a40`, radius 10, glyph fs15 `#f3f4f7`, at x=86 / 138 |
| `Remove` | 85x40, same style, right-aligned at x=1543 |

Block height = `18 + (n·53 + (n−1)·10 + 15) + 53 + 18`. Verified: n=2 → 220,
n=3 → 283.

**106 + 14 + 1400 + 14 + 94 = 1628.** That is `ConsoleValueBar` with no
adjustment.

`fx-edit` edits Tremolo (`RATE` / `DEPTH`); `fx-plugin` edits a hosted VST3
(`THRESHOLD` / `BAND GAIN` / `BAND FREQ`). Both are the *engine's* parameter
names, per #498's rule and `c/fx-edit`. Same faders, no special case.

**Carried by:** `TrackEffectParam` (label, divisions, `ParamReadout`);
`PluginRef` + the host's generic parameter list; `FxScope.setEffectEnabled` is
`bypass`; **`FxScope.moveEffect` is `◀`/`▶`** **[R]**.

**Does not exist:** the block chrome. Nothing else.

### `SIGNAL / fx-reorder` — dragging

The chain strip switches to `layout: "none"` during a drag.

- The dragged chip lifts: 74x38 → **75x40**, fs16 → 16.8, radius 8 → 8.4,
  padding `[10,17]` → `[10.5, 17.85]` — a uniform **1.0135 scale** — offset
  `(-2, -5)` from its slot.
- The **drop target** carries a left stroke `#3b82f6` **4px** — the accent slot
  `c/fx-reorder` describes.
- Surviving chips reflow to close the gap (`Tremolo` at x=82 where `Drive` was
  at 0).

The panel here has **no editor and no level/mix** — header, chain, monitor
only, 352 tall. Dragging is its own mode.

**Does not exist:** any drag affordance in the console vocabulary. **[R] But
the drop-index maths does:** `signal_fx_rack.dart:160-218` has a working
`Draggable`/`DragTarget` reorder — `_DropSlot` before every card,
`_reorderTo(from, insertAt)` index normalisation, and a `_landedAt`/`_dropGen`
landing flag. The widget is new; **port `_reorderTo`, do not re-derive it.**

### `SIGNAL / fx-add` — the add dialog

Centred dialog **744x495** at (587,292) — the same 744 width #527 fixed the
pick-one on. Padding 25, fill `#161618`, stroke `#3a3a40` 1px, radius 17.

| Element | Metric |
|---|---|
| Title `Add an effect` | fs19 w650 lh1.16 `#f3f4f7` |
| Prose | 10 below; fs16 lh1.55 `#9a9aa2` — `Into “Guitar front”, at the end of the chain.` |
| Caption `BUILT IN` | 19 below; fs13 ls0.91 lh1.23 `#6b6b73` |
| Built-in grid | 10 below; 694 wide, 4 columns of **166x48**, gutter 10, radius 11, rows gap 10 |
| Caption `PLUGINS · RECENT` | 19 below |
| Recent grid | 10 below; 4 columns of **166x66**, gutter 10 |
| `Browse all 103 plugins…` | 19 below; 694x48, radius 11 |
| `Cancel` | 19 below; 77x40, right-aligned |

**The accent state on this grid does not mean "selected".** `Drive` and
`Filter` are accent; the other five are neutral. The target chain — `Guitar
front` — *is* Drive → Filter. Accent marks **already in this chain**, not the
current pick. A `ConsoleChipGrid` used as a pick-one gets this backwards.

**166 / 10 / 48 is `ConsoleChipGrid.cellWidth` / `.gutter` / `.cellHeight`**
(`console_surface.dart:2089-2095`). Recent cells are 66 where
`.twoLineCellHeight` is 56 — see D7.

The seven built-ins are `TrackEffectType`'s own: Drive, Filter, Delay, Tremolo,
Octaver, Echo, Reverb. #498 already ruled any other set wrong; the grid draws
7 + one empty cell.

**Carried by:** `TrackEffectType`; `PluginCatalog`; `FxScope.insertPlugin`.

**Does not exist:** a recents list for plugins; the "already in chain" tone.

**[R] The 66-tall recent cells are not `twoLineCellHeight`.** That constant
(56) is a label over a **single-line sublabel**; the pen draws one label
*wrapping*, which `ConsoleChipGrid` cannot do (`maxLines: 1`). D4 and D7 fix
this together by making the plugin's format the sublabel.

### `SIGNAL / fx-browse` — the plugin search sheet

Bottom sheet **1918x580** at y=498, scrim `#08080a9e`, fill `#161618`, top
stroke `#3a3a40`, padding `[20,19,19,19]` — the `showConsoleRenameSheet` shell
(`lib/common/console_rename_sheet.dart:25`).

| Element | Metric |
|---|---|
| Header | 1880x40; `Add a plugin` fs18 w650 lh1.17; `103 installed` fs14 lh1.21 `#6b6b73` at x=119; `Cancel` 77x40 right |
| Search field | 12 below; 1880x52, fill `#0b0b0c`, stroke `#3b82f6` 1px, radius 10; text fs18 lh1.17 at x=18; caret 2x22 `#3b82f6` |
| Results | 14 below; 1880 wide, 6 columns of **305x48**, gutter 10, radius 11, rows gap 10 |
| `11 matches` | 10 below the grid; fs13 lh1.23 `#6b6b73` |
| Keyboard | 13 below; rows 50 tall gap 7; keys radius 8, fill `#1e1e21`, stroke `#2a2a2e` |

The match count sits **below** the grid. Deliberate — `library`'s header count
does the same.

**Carried by:** `PluginCatalog` and `plugin_browser.dart`'s search.

**Does not exist:** a 305-wide grid column (the vocabulary's chip is 166); the
console keyboard driving a *filter* rather than a *field commit*.

### `library`, `rack-new`, `rack-delete` — measured, not built

Recorded so #535 need not re-measure.

**`library`** — replaces the tab strip and card grid entirely. Header
`Rack library` fs20 w650 + `6 racks` fs14 lh1.21 `#6b6b73` at +9; trailing
`← Back to FX` 121x40. List card 1700, padding 1, radius 12; rows 1698x115
(last 114), `#ffffff0b` dividers. Row: name fs17 lh1.18 `#f3f4f7`; gap 7; chip
row 40 tall — removable chips 33 tall (fill `#26262a`, stroke `#3a3a40`, radius
8, label fs14 lh1.21 `#f3f4f7` + `×` fs16 `#6b6b73`), gap 7, then `+ effect`
83x40; gap 2; `loaded on guitar` fs14 lh1.21 `#6b6b73`. Trailing `✎` 27x26 +
`🗑` 25x26 at x=1619, y=44, gap 7. Footer `+ New rack` 1700x40, fill `#16233d`,
stroke `#3b82f6`, centred ink `#3b82f6`.

**`rack-new`** — scrim `#08080a9e`; sheet 1918x434 at y=644, padding
`[20,19,19,19]`, gap 12.5. `Name the rack` fs18 w650 + `Cancel` 77x40. Field
1880x52 as fx-browse. Keyboard rows 50 / gap 7; action key `Create` 374x50,
fill `#3b82f6`, fs17 w600 `#ffffff`.

**`rack-delete`** — scrim `#08080a6b`; dialog 528x191 at (695,444), padding 25,
radius 17. Title fs19 w650 lh1.16 — `Delete “Dirty rhythm”?`. Body 478 wide,
fs16 lh1.55 `#9a9aa2`, 10 below:
`It is loaded on rhythm · loop. Deleting it leaves that slot empty. The takes underneath are untouched.`
Buttons 19 below, right-aligned: `Keep it` 77x40 neutral, gap 11,
`Delete rack` 111x40 fill `#e5484d`, ink `#ffffff` w600. This is
`showConsoleConfirmDialog` with a destructive tone.

## The vocabulary

Signal is the **seventh** domain to compose from the console vocabulary.

### What it already says — reuse, do not re-draw

| Primitive | Where | Signal use | Fit |
|---|---|---|---|
| `ConsoleValueBar` | `console_surface.dart:1329` | every FX fader | **exact** — 53 / 106 / 94 |
| `ConsoleSwitch` | `:1011` | master output switches | **exact** — 53x31, knob 25, inset 3 |
| `ConsoleChipGrid` | `:2064` | `fx-add`'s built-in grid | **exact** — 166 / 10 / 48 |
| `ConsoleDialogButton` | `:2683` | every 40-tall button | **exact** — 40, padding 14, radius 10, fs15 lh1.2 |
| `ConsoleSmallButton` | `:1227` | the `bypass` pill | **exact** — 33, padding 14, radius 10, fs14 lh1.21 |
| `ConsoleRow` | `:292` | output rows | 70 tall with a 2-line label, above the 58 minimum |
| `ConsoleFace` / `ConsoleGroup` | `:2585` / `:2541` | the face scaffold | ✓ |
| `ConsoleProse` | `:577` | `fx-add`'s consequence line | `maxWidth 923` > the 694 used |
| `PillTabs` | **`lib/common/pill_tabs.dart:32`** **[R]** | the tab strip | ✓ (see D8 on weight) |
| `showConsoleRenameSheet` | **`lib/common/console_rename_sheet.dart:25`** **[R]** | `fx-browse`'s shell | ✓ |
| `showConsoleConfirmDialog` | `console_surface.dart:2292` | `rack-delete` | #535 |

`ConsoleDialogButton` is the notable one: named for dialogs, but its metrics
*are* the design's general 40-tall button, which Signal uses outside any dialog
(`+ effect`, `Remove`, `◀`, `▶`). **Rename or alias it; do not clone it.**

### What it cannot say

**Two shared-widget changes — not one** **[R]**:

1. **A stretched `ConsoleSegmented`.** The design's `in the mix` and `hear
   while playing` are 1664 wide with equal segments. The segments are
   **already `Expanded`** (`:1669`); the change is dropping the
   `IntrinsicWidth` wrapper at `:1656` behind a flag. **Call it `stretch`, not
   `fill`** — `ConsoleCard.fill` is already a `Color?` and the collision would
   read badly.
2. **An accent border on `ConsoleCard`.** The first draft claimed
   `borderExtent` covered this. It does not: `borderExtent` (`:219`) is a
   *layout* constant, and the border is a hard-coded
   `Border.all(color: surface.line)` at `:232`. The `#3b82f6` border on the
   selected card and the detail panel needs a new colour parameter.

**Feature-local, not shared:**

3. **`SignalCard`** — 202 wide, six stacked facts, tap-to-select, content-driven
   height. Nothing in the vocabulary is a card-as-tile. Keep it in the Signal
   feature until a second domain asks — the rule the file has followed since
   Network.
4. **The drag-reorder chip strip** — port `_reorderTo` from `signal_fx_rack`.
5. **The scope chip** — a tone-carrying pill. `ConsoleBanner` has tones but is
   a banner. Start local.

The FX editor block, the chain strip and the panel are **compositions of
existing parts**. No primitive for them.

### Does Signal make #530's split urgent?

**Yes in kind, no in schedule.**

Signal adds two small things to `console_surface.dart` and nothing else;
everything genuinely new is feature-local. By line count the file barely moves.

**[R] The barrel argument is also weaker than the first draft said:** #530
reasons from "one 2,756-line file", but `PillTabs` and `showConsoleRenameSheet`
already live in their own files under `lib/common/` and are imported
separately. The vocabulary is already partly split; #530 is finishing a job,
not starting one.

What Signal does prove is the **reader** problem. Planning against 2,756 lines
meant grepping a class list to discover `ConsoleValueBar` was already the exact
fader and `ConsoleDialogButton` already the exact button. Both were nearly
re-invented — and `ConsoleCard.borderExtent` *was* misread, in this very
document, as a styling hook it is not.

**Recommendation for #530:** do the split as its own mechanical PR **after**
Signal lands, when the vocabulary has stopped moving. Inside this slice it
would put a whole-file reorganisation in the same diff as a twelve-screen face.

## Design departures → **shipped as #571 + #573**, merged first

> **[R] Done.** Two `chore(design):` PRs, stacked, both ahead of any code:
>
> - **#571** — the design work that existed only in Pencil's memory (the
>   per-output switches on `signal-master`, the level and mix rows on
>   `signal-detail`) committed as its own baseline. `.pen` is encrypted and
>   cannot be diffed, so commit boundaries are the only record of which
>   geometry came from where — and this plan measures geometry that until
>   #571 existed nowhere in git.
> - **#573** — the eleven departures below. Based on #571, **not** master:
>   retarget it onto master before squash-merging #571, and delete branches
>   last.
>
> Verified after the edits: **459 top-level frames** (455 + `signal-track` and
> its `t/` `g/` `c/` companions), all **thirteen** SIGNAL screens laying out
> clean. Two clipping reports remain and neither is a defect — `fx-reorder`'s
> dragged chip is deliberately offset −2,−5 and scaled 1.0135, so overflowing
> its slot *is* the drag state, and `rack-new`'s `Cancel` sits flush at
> 1803+77=1880.

Geometry **and** the `c/<screen>` note, its own PR, `chore(design):` in both
title and commit subject, merged **before** any code.

| # | Screen | Departure |
|---|---|---|
| D1 | **new** `SIGNAL / signal-track` | The strip draws four tabs; three have frames. Draw the track face per the derivation above. Add `t/`, `g/`, `c/signal-track`. |
| D2 | `fx-browse` | The keyboard's accent action key reads **`Cancel`**, duplicating the header's Cancel and painting a dismiss in the affirmative slot. Make it a neutral `⏎`/`Done`, or drop the accent. |
| D3 | `signal-master` | The four output rows carry **stale layer names copied from `SYSTEM / display`** — `Output waveform window`, `High contrast`, `Track indicators` ×2, plus three sublabel names. Visible text is correct; names are not. Rename to `Out 1`…`Out 4`. |
| D4 | `fx-plugin`, `fx-add`, `fx-browse` | The chain chip reads **`TDR NovaVST3`** — name and format concatenated, while the same card's summary reads `TDR Nova`. **The format is a real fact, in the wrong place.** In the chain strip, drop it (the chip is narrow and the summary already reads `TDR Nova`). In `fx-add`'s recent shelf and `fx-browse`'s results, make it the chip's **sublabel** — which is precisely what `ConsoleSegment.sublabel` documents itself as: *"the thing's own machine fact, where label is what a person calls it."* Resolves D7 as a side effect. |
| D5 | `c/signal-loop` | The note says "the vacant **dashed** card"; the geometry gives it the same solid `#2a2a2e` stroke as a loaded one. **Keep the geometry** — no dashed border exists anywhere in the vocabulary, and the vacant card is already distinguished by `no rack` + `tap to load one` + the omitted monitor row. Fix the note. |
| D6 | `signal-input` | `Vocal air` reports **`partially clipped`** — a 68x19 text in an 18-tall row with no `lineHeight`. Set `lh1.13` like every sibling. |
| D7 | `fx-add` | Recent-plugin cells are **166x66** and `ConsoleChipGrid.twoLineCellHeight` is **56** — but these are **different cells**, not a rounding disagreement. The constant is a label + single-line sublabel (fs16 + fs14, both `maxLines: 1`, gap 2 → 56). The pen draws one label *wrapping* to two lines (`Airwindows Console`, 146x38), which the grid cannot express at all — its label is `maxLines: 1`. **Give the plugin chips the format as a sublabel (D4) and they become 56 exactly.** Otherwise the vocabulary needs a wrapping-label variant it does not have and should not grow. |
| D10 | `fx-browse` | **[R] Reversed while doing the work — the design is right and this recommendation was wrong.** Result cells are **305x48** across 6 columns of 1880, where `ConsoleChipGrid.cellWidth` is a fixed **166**. The draft said the pen should adopt 166. Computing it out: 11 chips at 166 packs to 6+5 columns using **1,046 of 1,880px**, stranding two thirds of the sheet. `ConsoleChipGrid` gains a **stretch mode** instead — the same idea as `ConsoleSegmented.stretch`, which makes it one concept appearing twice rather than scope creep. **No pen change**; `c/fx-browse` records the reasoning. |
| D11 | `signal-input` | **new** `aux` card — an input with no rack that **still carries its monitor line**. Decided by the user: whether you hear yourself is a fact about the jack, not the chain on it. Drawn inline the way `signal-loop` draws its own vacant card, so the two read against each other. Without it, every card in this slice would be rackless and the face would say nothing about monitoring at all. |
| D8 | *all six shipped domains* | The pen draws selected tabs w600 / unselected normal; `pill_tabs.dart:127` is a constant `FontWeight.w500`. **Pre-existing debt, not this slice's** — flagged so it is a known deviation, not a Signal regression. Sweep it in only if you say so. |

**Note-only (D9).** `in the mix` is a boolean drawn as a 2-up segmented
(`muted` / `heard`) while `signal-master`'s per-output booleans are switches.
Not a violation — the words are not "on"/"off" — but two screens say different
things about how a boolean looks. Record the rule in `c/signal-detail`: **a
boolean inside a stack of segmented rows stays segmented; a boolean in a list
row is a switch.**

## Architecture

**[R] Corrected directory.** The first draft proposed
`lib/looper/view/tray/signal/`, which matches no shipped face —
`lib/looper/view/tray/` holds the tray *shell* only (`tray_home`,
`tray_navigation_rail`, `tray_panel`, `tray_tile`, `tray_metrics`,
`tray_brightness_slider`). Every shipped face lives beside its feature:

| Domain | Code | Test |
|---|---|---|
| Network | `lib/network/` | `test/network/network_faces_test.dart` |
| System | `lib/system/view/` | `test/system/view/system_faces_test.dart` |
| Audio | `lib/audio_setup/view/console/` | `test/audio_setup/view/audio_faces_test.dart` |
| Tracks | `lib/looper/view/tracks/` | `test/looper/view/tracks/tracks_faces_test.dart` |
| Loop | `lib/looper/view/loop/` | `test/looper/view/loop/loop_faces_test.dart` |
| Control | `lib/control/` | `test/control/control_face_test.dart` |

Signal therefore takes `lib/looper/view/signal/`, beside the `signal_graph/` it
replaces:

```
lib/looper/view/signal/
  signal_tray_panel.dart    # face scaffold + tabs over FxStage
  signal_card.dart          # the 202-wide card
  signal_cards.dart         # per-stage card lists off signal_rows.dart
  signal_detail_panel.dart  # the in-place panel
  signal_fx_editor.dart     # the editor block over ConsoleValueBar
  signal_chain_strip.dart   # chain chips + drag reorder
  signal_dialogs.dart       # fx-add dialog + fx-browse sheet
```

Seven files, matching the naming of `loop_tray_panel.dart` /
`tracks_tray_panel.dart`. `fx-add` and `fx-browse` share one file — both are
small single-purpose shells.

Reused unchanged: `fx_scope.dart`, `signal_rows.dart`, `plugin_catalog.dart`,
`fx_address.dart`, `console_surface.dart`.

### Monitor tri-state

```dart
// packages/looper_repository/lib/src/models/input_monitor.dart
enum MonitorMode { off, auto, on }
```

`InputMonitor.enabled` becomes `InputMonitor.mode`. **[R] No deprecated getter
and no persisted migration** — `AGENTS.md:2-3` is explicit: *"Do not preserve
backward compatibility. Remove obsolete paths instead of adding compatibility
layers, fallbacks, or migrations."* Every caller is first-party and in files
this PR already touches:

| Caller | Fate |
|---|---|
| `signal_list_view.dart:238` | deleted in this slice |
| `monitor_cubit.dart:165,460` | edited by this PR anyway |
| `session_mapping.dart:36,101,168` | edited by this PR |

`settings_repository.dart:689-694` becomes `loadMonitorInputMode` /
`saveMonitorInputMode` over the enum name. The old bool key is orphaned; an
absent value reads `off`, which is `InputMonitor`'s current default anyway.

Resolution lives in `LooperRepository` beside `_laneInput` and the existing
`setMonitorInputEnabled` write, per direction call 3. `MonitorCubit` keeps
intent only; its methods return `void` — CI's bloc lint enforces this
(`prefer_void_public_cubit_methods`) and `dart analyze` does not.

## Work breakdown

**[R] Six code PRs.** The model PR moves **first**, because the card's monitor
row renders `MonitorMode` and would otherwise need a two-state stand-in it then
throws away.

**Each branch is cut off master *after* its predecessor merges** — sequential,
never stacked. The parent plan lost three PRs to base-branch accidents. Note
this is about git mechanics, not file independence: PRs 3–5 each modify files
PRs 2–4 created, so they must genuinely be serialised, not opened in parallel.

| # | PR | Screens | Ships |
|---|---|---|---|
| 0 | `chore(design):` pen fixes | — | D1–D7, D9's note |
| 1 | Monitor tri-state, model through resolution | — | `MonitorMode`; `InputMonitor.mode`; `settings_repository` tri-state persistence; the fan-in predicate in `LooperRepository`; `monitor_cubit` and `session_mapping` call sites. **No UI.** Three packages. |
| 2 | Rail seam + the four lists | `signal-loop`, `signal-input`, `signal-master`, `signal-track` | `SettingsTrayDestination.signal`, rail entry, face, tabs over `FxStage`, `SignalCard`, scope chips, read-only `OUTPUTS` group, Signal tile removed from tray home |
| 3 | Detail panel | `signal-detail` | Card selection, panel, level, in-the-mix, the monitor segment; **both `console_surface.dart` changes** (`ConsoleSegmented.stretch`, `ConsoleCard` border colour) |
| 4 | The FX editor | `fx-edit`, `fx-plugin` | Editor block, `ConsoleValueBar` per param, bypass / `◀` / `▶` (via existing `FxScope.moveEffect`) / `Remove` |
| 5 | Add, browse, reorder | `fx-add`, `fx-browse`, `fx-reorder` | The dialog, the sheet, drag-to-reorder (porting `_reorderTo`) |
| 6 | Demolition | — | See below |
| — | Racks | `library`, `rack-new`, `rack-delete` | **#535** |

PR 5 can split into `add + browse` and `reorder` if review prefers; they share
only the chip strip.

### PR 6 — the demolition, in full **[R]**

The first draft accounted for ~2,900 of the 5,698 lines. The rest goes too.

**Deleted directly** (1,898 + `fx_dock` + `plugin_browser`):
`signal_list_view.dart`, `signal_chrome.dart`, `signal_panes.dart`,
`signal_row_views.dart`, `fx_editor/fx_dock.dart`, `plugin_browser.dart`.

**Orphaned by that deletion** — verified by tracing every importer outside
`signal_graph/`:

| Orphan | Lines | Sole consumer(s), all deleted |
|---|---|---|
| `signal_fx_rack.dart` | 1,509 | `fx_dock.dart` |
| `fx_param_tile.dart` | 347 | `signal_fx_rack.dart` |
| `signal_fx_summary.dart` | 296 | `signal_list_view.dart` |
| `fx_param_edit_sheet.dart` | 267 | `signal_fx_rack.dart` |
| `signal_fx_chrome.dart` | 205 | `fx_dock`, `signal_fx_rack`, `signal_fx_summary`, `signal_list_view` |
| `signal_routing_chips.dart` | 167 | `signal_list_view.dart` |
| | **2,791** | |

**Survives — it has other consumers:** `signal_knob.dart` (326, used by
`audio_setup/view/midi_learn_section.dart`) and `signal_style.dart` (83, used
by `midi_learn_section.dart` and `fx_editor/fx_block_chip.dart`). `signal_style`
loses 10 of its 12 importers, so it wants pruning, not just retention.
`fx_block_chip.dart`'s own last consumer is `signal_fx_summary.dart` — check it
at build time; it may join the orphan list.

**Test files deleted** (7 of 9 under `test/looper/view/signal_graph/`):
`fx_param_tile_test`, `plugin_browser_test`, `signal_fx_chrome_test`,
`signal_fx_rack_test`, `signal_fx_summary_test`, `signal_list_view_test`,
`signal_routing_chips_test`. **Surviving:** `signal_knob_test`,
`signal_rows_test` (the view-model is reused; only its trace-tag cases go with
tap-to-trace).

**Also breaks and must be updated:** `test/theme/token_adoption_test.dart:24`
hard-codes `'lib/looper/view/signal_graph/signal_fx_rack.dart'`.

**Prose that must be rewritten, not just compiled away:** `showSignalPage` has
three call sites (`tracks_commands.dart:215`, `tracks_chrome.dart:115`,
`tray_home.dart:75`) but six textual references — plus the export at
`signal_graph.dart:6`, the declaration at `signal_list_view.dart:33`, and doc
comments at `pedal_assignment_page.dart:18`, `settings_tray_state.dart:115`,
`tray_home.dart:232`. `settings_tray_state.dart:5-9` and
`tray_navigation_rail.dart:19` both document the route-pushing exception this
slice removes.

## Success criteria

```yaml
success-criteria:
  - id: tests-green
    text: The full Dart/Flutter suite passes.
    verify: /Users/Tomas/development/flutter/bin/flutter test

  - id: analyze-clean
    text: Static analysis is clean.
    verify: dart analyze

  - id: bloc-lint-clean
    text: Bloc lint is clean — no cubit method returns a value.
    verify: bloc lint lib test packages

  - id: native-green
    text: The native engine suite passes — the resolved monitor gate crosses the FFI seam via setMonitorInputEnabled.
    verify: bash packages/segno_engine/src/test/run_native_tests.sh

  - id: signal-is-a-rail-destination
    text: SettingsTrayDestination has a signal member and the rail renders it.
    verify: grep -qE '^\s+signal,$' lib/looper/cubit/settings_tray_state.dart && grep -q 'SettingsTrayDestination.signal' lib/looper/view/tray/tray_navigation_rail.dart

  - id: full-screen-route-is-gone
    text: showSignalPage no longer appears anywhere in lib, including doc comments.
    verify: "! grep -rq 'showSignalPage' lib"

  - id: route-exception-prose-gone
    text: Neither the rail nor the destination enum still documents Signal as a route-pushing exception.
    verify: "! grep -rq 'push full-screen routes' lib/looper/view/tray/tray_navigation_rail.dart lib/looper/cubit/settings_tray_state.dart"

  - id: no-orphans-left
    text: Every file orphaned by the demolition is gone.
    verify: "! ls lib/looper/view/signal_graph/ 2>/dev/null | grep -qE 'signal_fx_rack|fx_param_tile|signal_fx_summary|fx_param_edit_sheet|signal_fx_chrome|signal_routing_chips|signal_list_view|signal_panes|signal_row_views|signal_chrome'"

  - id: tri-state-modelled
    text: MonitorMode exists with off/auto/on and no deprecated bool getter survives.
    verify: grep -q 'enum MonitorMode' packages/looper_repository/lib/src/models/input_monitor.dart && ! grep -q 'Deprecated' packages/looper_repository/lib/src/models/input_monitor.dart

  - id: tri-state-persists
    text: settings_repository stores the mode, not a bool.
    verify: grep -q 'MonitorInputMode' packages/settings_repository/lib/src/settings_repository.dart && ! grep -q 'MonitorInputEnabled' packages/settings_repository/lib/src/settings_repository.dart

  - id: no-racks-leaked
    text: No rack model or library UI landed in this slice (#535 owns them).
    verify: "! grep -rqE 'class Rack|rackLibrary|MonitorMode.*rack' lib packages/looper_repository/lib"

  - id: faders-are-the-shared-primitive
    text: The FX editor uses ConsoleValueBar rather than a Signal-local fader.
    verify: grep -q 'ConsoleValueBar' lib/looper/view/signal/signal_fx_editor.dart

  - id: reorder-reuses-the-scope
    text: The editor's move controls call the existing FxScope.moveEffect rather than a new API.
    verify: grep -q 'moveEffect' lib/looper/view/signal/signal_fx_editor.dart

  - id: face-test-matches-the-shipped-shape
    text: One signal_faces_test.dart exists, grouped by pen frame name like its five siblings.
    verify: test -f test/looper/view/signal/signal_faces_test.dart && grep -q "SIGNAL / signal-loop" test/looper/view/signal/signal_faces_test.dart

  - id: auto-resolution-is-covered
    text: A test drives an arm transition and asserts the AUTO gate follows it.
    verify: grep -rq 'MonitorMode.auto' packages/looper_repository/test

  - id: leading-distribution
    text: Every new text style with a line-height multiplier also sets leadingDistribution.
    verify: manual 1) `grep -rn "height: 1\\." lib/looper/view/signal/` 2) confirm each hit has `leadingDistribution: TextLeadingDistribution.even` in the same TextStyle.

  - id: animation-mid-flight
    text: Panel open/close and card selection assert on a mid-animation frame, measured on the clipping box.
    verify: manual 1) `grep -n "pump(const Duration" test/looper/view/signal/signal_faces_test.dart` 2) confirm at least one assertion per animated transition reads the CLIPPING box height, not the content's.

  - id: goldens-regenerated
    text: Screenshot goldens regenerated and eyeballed on the author's machine.
    verify: manual 1) delete test/screenshots/goldens/signal_surface.png and the four fx_editor_*.png 2) run the screenshot tests to regenerate 3) open each new PNG and confirm it matches the measured metrics in this plan.

  - id: design-pr-merged-first
    text: The chore(design) pen PR is merged before the first code PR.
    verify: manual 1) `gh pr list --state merged --search "chore(design)"` shows the Signal pen PR 2) its merge date precedes PR 1's.
```

## Risks

**The master tab's output switches have no model behind them — and now have a
tracked home.** **[R]** The `OUTPUTS` group needs a rig-level "this hardware
output is live" flag; `InputMonitor.outputMask` is *per input*, a different
fact. PR 2 renders the group **read-only** against `AudioSetupState`'s output
list with switches reflecting the current mask union. Turning every output off
is also the silence the Audio face already warns about (`c/signal-master` says
so outright), so the write path needs that guard too.

**Tracked as #569** (`stage:plan`, `autonomy:plan-gate`), the way racks are
tracked as #535 — where the flag lives and what the last-output guard does are
direction calls. The first draft disclosed this only in prose, which is exactly
how input naming arrived mid-build in #528.

**Tap-to-trace dies undesigned.** Named in the scope boundary; repeated here
because it is the most likely "wait, where did that go" after PR 6.

**`fx-browse` puts a soft keyboard behind a live filter.** Every other console
keyboard commits a field; this one filters 103 items per keystroke. The
catalogue is already in memory, so this is a rebuild cost, not I/O — but it
wants a test that types and asserts the match count, not just the grid.

**Six PRs over one surface is what the plan-splitting review exists to flag.**
Deliberate: twelve screens over a 5,700-line replacement cannot be one PR, and
the parent plan's retrospective says a four-deep *stack* cost three PRs. These
are sequential off master, not stacked.

## Testing

**[R] The first draft's testing section was below the shipped bar and pointed
at the wrong shape.** The convention across all six faces is **one
`*_faces_test.dart` per domain**, 580–1,212 lines, grouped
`SIGNAL / <screen>` matching the pen frame names, with **failure, in-flight and
empty states enumerated per screen**. `test/system/view/system_faces_test.dart`
is 1,043 lines and ~37 `testWidgets`, with purpose-built fakes for slow and
failing clients.

Signal's is `test/looper/view/signal/signal_faces_test.dart`, and must carry:

- A group per screen, named for its pen frame, including the derived
  `SIGNAL / signal-track`.
- Per screen: the empty state (no tracks, no inputs, no chain), and for
  `fx-browse` the no-matches state.
- **Mid-animation assertions** for panel open/close and card selection,
  measured on the **clipping** box — the content is laid out at full size from
  the first frame, so measuring it proves nothing.
- The `+ effect` chip opening `fx-add`, and `fx-add`'s accent state marking
  **already in chain** rather than selection.
- Typing into `fx-browse` and asserting the match count, not just the grid.

Beyond the face test:

- `packages/looper_repository/test/` — the `AUTO` fan-in predicate, driven
  through an arm transition on a track fed by a shared input. **This is the
  slice's riskiest new behaviour and the first draft named no test for it.**
- `packages/settings_repository/test/` — tri-state round-trip.
- `test/audio_setup/cubit/monitor_cubit_test.dart` — the `MonitorMode` paths.
- `test/looper/view/fx_editor/fx_scope_test.dart` — unchanged; `moveEffect`
  already has coverage.
- `signal_rows_test.dart` survives PR 6; its trace-tag cases go with
  tap-to-trace.
- `test/theme/token_adoption_test.dart` — update line 24 before deleting
  `signal_fx_rack.dart`.
- Golden regeneration for `signal_surface` and the four `fx_editor_*` goldens,
  which only run on the author's machine and rot silently elsewhere.
