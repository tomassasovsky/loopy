---
date: 2026-06-10
topic: multi-lane-tracks-dual-route-monitoring
---

# Multi-Lane Tracks + Dual-Route (Record / Monitor) Effects

## What We're Building

A rework of the looper's routing/monitoring/effects model so it matches the
[audio routing requirements](../../../Downloads/audioroutingrequirements.md)
(captured from a voice memo). The core idea is **two independent routes per
input** with **always-clean recording**:

- **Recording route** — an input is captured *clean* (no effects on the way in)
  into a **lane** of a track. A track is a **multi-lane container**: if several
  inputs are assigned to one track they are **not merged** — each gets its own
  clean mono buffer and they all play back together under one shared transport
  and loop length. Each lane carries its **own** non-destructive effect chain
  applied on playback, plus its own output routing, volume, and mute.
- **Monitoring route** — independently, any input can be sent **live to the
  output** through its **own** effect chain (e.g. a delay). Monitor effects go
  *only* to the output and are **never recorded**, and the monitor works whether
  or not the track is recorded/playing.

This replaces the per-track pre/post "stage" model and the single global
monitor-FX bus shipped on PR #11 with a cleaner, more literal model:
**per-lane record effects** + **per-input monitor effects**.

## Why This Approach

The voice-memo author was explicit and we disambiguated the one fuzzy passage
(the `in1`/`in2` worked example) directly: both inputs are recorded into track 1
as **separate dry lanes**, and `in1`'s lane runs two effects while `in2`'s lane
plays dry. That rules out the "easier approximations":

- **Not** "one input = one track with UI grouping" — the author wants a real
  multi-input track whose inputs stay independent yet share a transport/loop.
- **Not** per-track (whole-track) effects — effects are **per input-lane**.
- **Not** a single global monitor bus — monitor effects are **per input**.

We keep the genuinely-correct piece already shipped (recording is always dry)
and reuse the existing effect DSP machinery (`le_fx_state`, the SPSC command
ring, `fx_apply_chain`, the `TrackEffect` model and chain-editor UI) as the
foundation for *both* the per-lane and per-input-monitor chains — so the prior
work is the substrate, not waste. The pre/post-stage and global-bus surfaces are
what get replaced.

Delivered as **phased, independently-mergeable PRs**, with the **engine
multi-lane core proven end-to-end by native tests first** (the riskiest,
most-foundational change) before any Dart/UI is layered on.

**Engine implementation: a track owns an array of lanes (Impl A).** We
considered modelling a "track" as a *group* of today's mono tracks (each
existing mono track already has its own buffer, effect chain, output mask,
volume, mute, and latency compensation, so it is functionally a lane). That
would reuse almost the entire engine and only add a group-transport primitive.
We deliberately chose instead to **rewrite `le_track` to hold an array of
lanes** so the data model has a single, clean `track` object that owns its lanes
and one shared transport/clock/undo — at the cost of a larger, more invasive
engine change. The cleaner model is judged worth the extra work.

## Key Decisions

- **A track is a multi-lane container.** One clean mono buffer per assigned
  input ("lane"), not an average. Rationale: the requirement "two inputs → one
  track, not merged, both play back" taken literally; the worked example
  confirms separate lanes.
- **Engine data model: `le_track` owns an array of lanes (Impl A).** A lane is
  the fundamental recordable unit: `{ assigned input channel, mono buffer +
  undo pool, effect-chain config + DSP state, output mask, volume, mute }`. The
  track owns the shared transport, master-clock phase, loop length/multiple,
  quantize, and one undo span across its lanes. Chosen over the
  group-of-mono-tracks alternative for a cleaner single-object model (see Why).
- **Effects are per input-lane (record route).** Each lane has its own ordered,
  chainable, non-destructive effect chain applied on playback. Rationale: the
  worked example — `in1`'s lane has two effects, `in2`'s lane is dry.
- **Monitoring is a per-input route with its own effect chain.** Input → output
  live, through that input's monitor chain, never recorded, independent of
  playback. Replaces the global monitor-FX bus and the "monitor follows a track"
  feature. Rationale: the doc describes per-input monitor effects that "go only
  to the output."
- **Shared transport per track.** Hitting Record on a track arms/captures *all*
  its assigned inputs at once into their lanes; lanes share loop length,
  quantize, and start/stop together. Rationale: the author's "they feed one
  track / both play"; simplest coherent grouping.
- **Per-lane vs per-track split.** Per-lane: effect chain, output routing,
  volume, mute. Shared per-track: record/play/stop transport, loop length,
  quantize, undo. Rationale: everything about "this input's sound" is
  independent; transport/loop are the grouping.
- **Undo is per-track (shared transport).** One overdub pass adds a layer across
  all lanes; one undo removes the last pass across all lanes. Rationale:
  consistency with the shared transport (revisit if per-lane undo is wanted).
- **No separate whole-track master effect chain (YAGNI).** Only per-lane record
  chains and per-input monitor chains for now; a track-summed master chain can
  be added later if a real need appears.
- **Keep "recording is always dry."** Already correct on PR #11; foundational to
  the non-destructive model and unchanged.
- **Reuse the effect DSP substrate.** `le_fx_state`, command ring,
  `fx_apply_chain`, `TrackEffect`/encode-decode, and the card chain-editor are
  reused for per-lane and per-input-monitor chains. The pre/post `stage` field
  and the global-bus commands/State/UI are removed/replaced.
- **Scope: full model, phased PRs, engine-core spike first.** Phase order:
  (1) engine multi-lane recording core (N un-merged lanes, shared transport,
  latency-compensated capture, playback, undo) with native tests; (2) per-lane
  effects; (3) per-input monitor routes + chains (remove global bus); (4) Dart
  layers (models, repository, blocs, persistence) threaded through phases;
  (5) UI rework (per-lane + per-input-monitor in the routing view). Each phase
  green before the next.

## Migration / Disposition of Shipped Work (PR #11)

- **Keep:** dry-recording fix; the `le_fx_state` refactor; the `TrackEffect`
  model + encode/decode; the effect DSP (drive/filter/delay/tremolo) and chain
  application; the card chain-editor widget (re-targetable to lanes/monitor).
- **Replace:** per-track pre/post `stage` semantics → per-lane chains; the
  global monitor-FX bus (engine `a_monitor_fx_*`, `SET_MONITOR_FX*`, Dart
  `setMonitorFx*`, `MonitorCubit` bus chain, `monitor.fx` persistence, the
  `MonitorFxEditor` UI) → per-input monitor routes/chains; the "monitor follows a
  track" feature → subsumed by per-input monitor.
- **Branching:** merge PR #11 first (it is a coherent net improvement and the
  dry-recording fix is foundational), then start the rework from a fresh branch
  off `master`, so the rework's replacements read as deliberate rather than
  churn-on-churn. Confirm at plan time.

## Open Questions

- **Engine capacity / memory budget.** The data model is decided (track owns a
  lane array); the open part is sizing. Max lanes per track should cap at the
  hardware input count (realistically a handful — e.g. a Scarlett 4i4 has 4
  inputs), so worst case is `LE_MAX_TRACKS × max_lanes` full mono buffers + undo
  pools + delay rings. Pin concrete caps and a memory budget at plan time, and
  decide whether lane buffers/undo pools allocate lazily (on first record into a
  lane) to keep idle memory flat.
- **Lane assignment UX.** How does a user assign an input to a track's lane,
  add/remove lanes, and see the two routes (record vs monitor) per input? This is
  a significant routing-view redesign (the current per-track signal-flow graph is
  the starting point) and should get its own design pass in planning.
- **Per-input monitor enable.** Is monitoring per-input on/off (each input can be
  independently monitored), and how does that coexist with the existing
  monitor-on/off master + output routing? Confirm the monitor output mask is
  per-input too (each monitored input routes to chosen outputs).
- **Latency compensation per lane.** All lanes of a track share one transport
  and the global record offset, so each lane reuses today's single-buffer
  phase-locking math; the plan must confirm the per-lane write heads stay
  phase-locked to the master loop exactly as the single buffer does today (no new
  compensation logic, just applied N times).
- **Undo granularity revisit.** Per-track undo is the default; confirm no
  per-lane undo need before locking it in.
- **Quantize / target-multiple / sound-activated record / rec-dub.** These are
  currently per-track; confirm they stay per-track (shared) under the multi-lane
  model.
