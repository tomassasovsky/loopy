---
title: Unified Signal Surface — UX/UI for the unified input FX & routing engine
type: brainstorm
date: 2026-06-22
status: ready-for-design
---

# Unified Signal Surface

## Problem

The engine just changed shape (PR #69, "Unified Input FX & Routing"), but the UI
was only mechanically folded, not rethought. The new engine model is:

- An **input** = an on/off gate + **one** FX chain + an output mask.
- The FX chain you **monitor** live is **snapshot-copied onto the track lane when
  you record** — what you hear is what you record (non-destructive playback
  re-applies the snapshot).
- **Outputs** have a **structural on/off gate** (off = removed from the routing
  graph as a target; stored routes preserved).

The current UI still reflects the *old* multi-lane / dual-route world and splits
one idea across three node-and-wire surfaces:

1. **Input-monitor graph** — `lib/audio_setup/view/monitor_graph/` — reached from
   the **Audio Setup** page.
2. **Whole-system routing graph** — `lib/looper/view/tracks_routing_graph/` —
   reached from **Big Picture settings → Routing tab**.
3. **Per-track lane graph** — `lib/looper/view/lane_graph/` — reached from the
   **per-track routing dialog**.

### Pains (user-confirmed)

- **FX is configured twice.** You dial a tone on the input (monitor graph), and a
  separate FX chain exists on the track lane. Snapshot-on-record makes them the
  same thing at record time, but the UI still has two FX-editing homes. The
  feature's "configure once" promise is invisible.
- **Monitoring is buried/separate.** "What you monitor = what you record" is now
  one idea, yet monitoring lives in Audio Setup while recording lives in the
  performance view.
- **Too many graph surfaces.** Three different node/wire canvases for a model
  that is now much simpler.

The user is **not** rejecting the graph metaphor (they explicitly like the graph —
see `loopy-ui-literal-graph`). The problem is *fragmentation and redundancy*, not
the visual idea.

## Goals

- **One** signal surface, not three.
- **One** FX home: the input owns its tone, and that tone is what records.
- **Monitoring folded into the model**: an input that is *on* and routed to
  outputs *is* being monitored; recording simply captures it. No separate
  "monitor" concept/screen.
- **Scales 1 → 18 channels** gracefully (same surface for a guitar-into-stereo rig
  and an 18-in/20-out interface).
- Preserve the structural **output gate** and the **per-take snapshot** (D10: a
  recorded lane can still be tweaked post-record, but that is clearly secondary).

### Non-goals

- No change to the engine or the data model — this is a pure UX/IA rework on top
  of the shipped PR #69 engine.
- Not removing multi-lane tracks (a track can still capture several inputs); only
  removing the *separate surfaces* for editing them.

## Chosen direction — "Unified Signal graph, input = FX home"

A **single signal-flow canvas** replaces all three surfaces:

```
   INPUTS                 TRACKS                 OUTPUTS
   (left rail)            (middle)               (right rail)

  ┌──────────┐           ┌──────────┐           ┌────────┐
  │ In 1  ⏻  │──┐        │ Track 1  │──┐        │ Out 1  │  (enabled)
  │ tone:🎛🎛 │  └──lane──│  ◆ In 1  │  ├────────│ Out 2  │
  │ lvl ▭▭▭  │           │  (snap)  │  │        │ Out 3  │  (gated off,
  │ → out ●● │           └──────────┘  │        │ Out 4 │   greyed)
  └──────────┘                         └────────└────────┘
```

- **Input node = a "strip in the graph"** (the single FX home):
  - on/off **gate** (this is "monitor this input" — same toggle, honest name),
  - its **one FX chain** (cards, drag-to-reorder, tap-to-edit — the live tone,
    which is exactly what records),
  - a **level** meter/control,
  - an **output assignment** (wires to the output rail).
  An input that is **on** and wired to outputs is audible live = monitored. There
  is no separate "monitoring" surface or concept.

- **Track node = the captured take(s).** A track sits in the middle. Tap a track
  to **focus** it, then tap inputs to **capture** them: each input→track wire is a
  **lane** carrying that input's **FX snapshot** (badge: "snapshot of In N @
  record"). This **absorbs the per-track lane dialog** into the one canvas.
  Tapping a lane's snapshot badge opens the **same** FX editor, scoped/labelled
  **"this take"** — the only place post-record per-lane editing happens (D10),
  clearly secondary to the input's live chain.

- **Output node = a routing target with a structural gate.** Tap to toggle the
  gate; a gated-off output renders greyed + line-through and is non-targetable,
  but edges to it still draw (a track routed only there is discoverable). A
  non-blocking "no active outputs" notice appears when the last output is off.

### Information architecture

- A single **"Signal"** surface, reachable as a **primary view from the Big
  Picture performance flow** (a top-bar button + a keyboard key, like the existing
  settings/`S` affordance). Because monitoring = the live performance, it belongs
  in the performance flow, not buried in Audio Setup.
- It **replaces**: the Audio-Setup monitor graph, the Big-Picture-settings Routing
  tab, and the per-track lane dialog.
- **Audio Setup** keeps only what is genuinely device setup: device pickers,
  sample rate / buffer, exclusive mode, latency calibration, loopback note. (The
  "configure input monitoring" entry there goes away — monitoring now lives on the
  Signal surface.)

### Scaling 1 → 18

- The canvas is already a **zoom/pan** surface (the shipped routing-graph kit), so
  18 in / 20 out fits.
- For the **common 1–2 input case**, the canvas **auto-fits** to a compact layout
  (few nodes, no panning needed) so it reads like a small mixer, not a sprawling
  diagram. Same surface, no second UI — it just isn't crowded when the rig is
  small.

## Why this wins

| Pain | How this resolves it |
|------|----------------------|
| FX configured twice | FX lives **only** on the input node (pre-record). The track's per-lane editor is explicitly the **snapshot** of that input, edited only as a deliberate "tweak this take." One home, one source of truth. |
| Monitoring buried/separate | The input's **gate + output wiring IS monitoring**. No separate screen or concept; it's the same node you record from. |
| Too many graph surfaces | **One** canvas. The monitor graph, the routing graph, and the lane dialog all collapse into it. |
| Keep the graph the user likes | Still a node/wire signal-flow diagram — just unified and richer at the input node. |

## Alternatives considered

1. **Mixer channel-strips lead, graph demoted to a read-only overview.** Dead
   simple for 1–2 inputs and a familiar mixer model, but it demotes the graph the
   user values and makes many-to-many output routing less spatial. **Rejected**
   (conflicts with the user's attachment to the literal graph).
2. **FX home on the track, not the input.** Tune tone in the track's context.
   Re-creates the "configure per take" feel the feature set out to kill and is
   worse for "set a tone once, reuse across takes." **Rejected.**
3. **One unified graph but keep per-track lane wiring in a separate focused
   view.** Less crowded canvas, but reintroduces a second surface — against the
   "fewer surfaces" goal. **Folded in instead** (track focus + input taps wire
   lanes inline).

## Key interactions (happy paths)

1. **Set a tone and hear it:** open Signal → tap **In 1** (gate on, now live to its
   default outputs) → add FX cards on In 1 → adjust → you hear it. That's
   monitoring; nothing else to do.
2. **Record what you hear:** arm/record a track (existing transport) → the track
   shows a lane wired from In 1 with a **snapshot** badge. The take plays back with
   the In 1 tone you set. Editing In 1 afterwards does **not** change the take.
3. **Tweak a take after the fact:** tap the track lane's snapshot badge → the FX
   editor opens labelled **"this take"** → edits affect only that lane.
4. **Capture a second input into the same track:** focus the track → tap **In 2** →
   a second lane appears with its own snapshot.
5. **Mute/disable an output:** tap **Out 4** → greyed + line-through; routes
   preserved; tap again to restore. Last-output-off shows the notice.

## Open questions / for the design pass

- Input node layout: how much of the FX chain shows inline vs. behind a "tap to
  edit" expansion, given the node also carries gate + level + output. (Design to
  resolve; likely a compact chain summary inline, full editor in the docked
  bottom panel as today.)
- Whether the docked bottom panel (focused node's controls + selected-effect
  editor) stays one shared panel for inputs *and* tracks, or splits.
- Visual language for "this is the live tone" vs "this is a recorded snapshot"
  (colour/badge system) so the two never read as the same editable thing.
- Transport integration: the Signal surface vs. the performance grid — is Signal a
  full-screen route, a side panel, or a mode? (Likely a full-screen route reached
  by key, mirroring the existing settings route.)

## Handoff

Next: `/frontend-design` the **Signal** surface — desktop-first, Big-Picture neon
theme — producing a mockup of:
- the unified inputs→tracks→outputs canvas with a **rich input node** (gate, FX
  chain, level, output),
- the **track lane** with its snapshot badge,
- the **output gate** (enabled + greyed-off) and the no-active-outputs notice,
- the **docked editor panel** for the focused node / selected effect,
- both the **1-input compact** auto-fit and a **multichannel** layout.
