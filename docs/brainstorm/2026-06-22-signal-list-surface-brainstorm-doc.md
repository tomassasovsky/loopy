# Brainstorm — Signal surface, take 2: from node-graph to three lists

**Date:** 2026-06-22
**Status:** Approach chosen, ready to plan
**Supersedes the routing presentation of:** the unified Signal node-graph
(`docs/brainstorm/2026-06-22-unified-signal-surface-brainstorm-doc.md`,
shipped as PR #70 on `feat/unified-signal-surface`).

---

## Problem

The shipped Signal surface is a full-screen **node-and-wire graph** (hardware
inputs on the left → track lanes in the middle → hardware outputs on the right,
connected by bezier wires). It looks great at 2–6 channels, but two things break
it:

1. **Wire spaghetti at scale.** Every capture wire (input→lane) and every
   playback wire (lane→output) is drawn *all the time* and all cross the same
   vertical corridor. At ~16×16 with many tracks it collapses into an
   unreadable ribbon — you cannot trace a single signal.
2. **Ambiguous lanes.** Lanes are numbered *per track* and flattened into one
   middle column with no track identity, so eight single-lane tracks render as
   eight identical **"Lane 1"** rows.

The mess is not a styling bug — it is the node-graph paradigm hitting its limit
when asked to show all connections at once.

## What we learned (decision inputs)

| Question | Answer | Implication |
| --- | --- | --- |
| Realistic scale? | **Small most of the time** (2–8 in / a few tracks); 16×16 is a rare power-user setup that must not *break*. | Optimize the common small case; the dense case only needs to stay legible, not be fast to edit. |
| Main task on this surface? | **Set up once, rarely touch** (configured at soundcheck). | Legibility + correctness beat fast repeated edits. A "verify the whole config at a glance" picture matters. |
| Direction? | **Rethink — flat list with inline routing chips** (user chose over hardening the graph or adding a matrix). | Drop wires entirely. Routing becomes chips. No crossing lines at any scale. |

## Goals

- Stay **legible at any scale** — 2×2 and 16×16 both read cleanly; density is
  handled by scrolling, never by overlapping wires.
- **Fix lane identity** at the root: a lane is always shown under its track, and
  a single-lane track is just the track.
- **Preserve the signal-flow mental model** (inputs → tracks → outputs) and the
  instrument-panel aesthetic from PR #70 (Space Grotesk / IBM Plex Mono, gate
  pills, rotary knob, dock) — only the *canvas + wires* go away.
- Keep the engine wiring unchanged (`MonitorCubit` for inputs, `LooperBloc` for
  lanes + the output gate); this is a **presentation** rethink.

## Non-goals (YAGNI)

- No matrix / patchbay grid (optimizes for a dense, fast-edit workflow we do not
  have).
- No pan/zoom canvas, no wires, no edge bundling.
- No new state management — reuse the existing cubit/bloc + events.

---

## The design — "Signal as three lists"

Three **side-by-side panes**, mirroring the graph's left→right reading order but
as independent scrolling lists. No wires anywhere.

```
┌─ INPUTS ───────────┐  ┌─ TRACKS ───────────┐  ┌─ OUTPUTS ──┐
│ IN 1  ● LIVE  ▮▮▮  │  │ Drums              │  │ Out 1  ●on │
│  fx: Drive · Delay │  │  rec In 1 · ✦snap  │  │  ← In1,Dr  │
│  → ①②   vol ▮▮     │  │  fx: —     → ①     │  │ Out 2  ●on │
│ IN 2  ○ OFF        │  │ Bass               │  │  ← Bass    │
│  → ②    vol ▮      │  │  rec In 2  → ②     │  │ Out 3  ○off│
│ IN 3 (loopback)    │  │ Gtr  (2 takes)     │  │  …         │
│  …                 │  │   Take 1  rec In3  │  │            │
│                    │  │   Take 2  rec In3  │  │            │
└────────────────────┘  └────────────────────┘  └────────────┘
```

### Inputs pane
One row per hardware input — the **FX home** + monitoring + where it routes.
- Gate pill (`LIVE`/`OFF`), channel id, level meter.
- Its single **FX chain** as inline mono chips (tap a chip → edit in the dock).
- **Output routing chips**: one chip per output, lit when routed, **wearing that
  output's hue**; tap to toggle. (Replaces the playback-ish monitor wires.)
- Mute + rotary volume (in the dock when focused).
- Loopback inputs are struck-through and inert.

### Tracks pane
Grouped **by track**, which fixes the "Lane 1 ×8" problem structurally:
- A track is a labelled group (its name / number).
- A **single-lane track is one row that *is* the track** — no "Lane 1" label.
- A genuinely **multi-lane track** shows the track header + `Take 1 / Take 2 …`
  rows nested under it (lane numbers only appear where there's more than one).
- Each take row: a **capture badge** naming the input it recorded (`rec In 3`)
  with the **FX-snapshot** marker, its snapshot FX chips, mute/vol, and its
  **output routing chips** (output-hued, tappable).

### Outputs pane
One row per hardware output.
- The **structural on/off gate** (greyed + struck when off), output id in its
  **fixed hue**, and a compact **"fed by"** summary (the inputs/takes routing to
  it — chips or a count). A `liveRegion` "no active outputs" notice when all off.

### Replacing wires — two cues working together
- **Color:** every output owns a stable hue (reuse `SurfaceTheme.lanePalette`).
  Routing chips wear the *destination output's* hue, so "what goes to Out 2
  (amber)" is scannable by colour with zero interaction.
- **Tap-to-trace:** tap any row — input, take, or output — and every related row
  and chip across all three panes **highlights while the rest dims**. Tap `Out 2`
  → all its feeders light up; tap an input → its takes + outputs light up. This
  is the "what connects to what" that wires gave us, on demand, at any scale.

### Editing (unchanged feel)
The contextual **dock** stays: tap an input's FX chip → edit its chain; tap a
take → its "this take" snapshot editor; the **rotary knob** drives mix. The whole
PR #70 instrument-panel visual language (fonts, mono readouts, gate pills, glow,
knob) carries over — it was never the problem.

### Scale behaviour
At 16×16 each pane simply **scrolls**; nothing overlaps. Tap-to-trace keeps
connections answerable even when panes are scrolled apart. The common small case
stays calm and beautiful.

---

## Approaches considered

**A. Harden the existing flow graph** — focus-driven edges (wires only for the
focused node) + track grouping + honest labels. *Recommended by Claude; not
chosen.* Keeps wires; user wanted out of the wire business entirely.

**B. Graph + matrix toggle** — add a patchbay grid for the dense case. *Rejected:*
builds a whole second surface for a scenario that is rare (YAGNI).

**C. Flat list + inline routing chips** — **chosen.** No wires; routing as
output-hued chips; three side-by-side panes; tap-to-trace + colour for
legibility. Scales by scrolling, fixes lane identity by grouping.

---

## What carries over vs. what changes

**Keep:** `SurfaceTheme` tokens + bundled fonts, the mono/gate-pill/knob visual
language, `SignalInputDock` / `SignalLaneDock` (contextual editor) + `SignalKnob`
+ `EffectParamsEditor`, capture-on-record semantics, and **all** engine state
(`MonitorCubit`, `LooperBloc` events, output gate). Most of the dock/style layer
(`signal_style.dart`, `signal_knob.dart`, `signal_dock.dart`) is reusable as-is.

**Change / retire:** `SignalGraphLayout` (canvas geometry), `GraphCanvas` /
`GraphEdge` / `GraphEdgePainter` usage and the wire edges, the pan/zoom canvas,
`SignalInputNode` / `LaneNode` (become list **rows**), and `EffectChainCard`-on-
wire (FX become inline list chips). `package:routing_graph` is largely retired
for this surface; trim or drop what only the canvas used. New: an output-hue
routing-chip widget + the tap-to-trace highlight state (view-local), and a
track-grouped list model that collapses single-lane tracks.

---

## Open questions for /plan

- **Trace state ownership:** view-local `focusedChannel` (like the current focus)
  — confirm it stays presentation-only, no new cubit.
- **Routing-chip density:** at 16 outputs, a per-output chip row is wide — do we
  cap visible chips with a "+N" overflow, or rely on horizontal scroll within the
  row? (Lean: show enabled outputs as chips, a compact "+N" for the rest.)
- **Capture affordance** without wires: keep "focus a take, tap an input chip to
  (re)assign its recorded input"? Or a small input picker on the take row?
- **Three panes on a narrow window:** responsive fallback to stacked sections
  (the "one scrolling column" layout) below some width.
- **Goldens/tests:** the canvas/edge/layout tests retire with the graph; new
  widget tests for the three list panes, routing chips, tap-to-trace, and the
  track-grouping/label logic. Map old → new coverage (as in PR #70 Phase 3).

## Next steps

`/plan` this, then `/frontend-design` the three-pane list mock (in the PR #70
instrument-panel language) before building. Likely lands as a follow-up on
`feat/unified-signal-surface` (or a fresh branch off it), replacing the graph
presentation while keeping the engine + dock layers.
