---
date: 2026-06-22
topic: unified-input-fx-routing
---

# Unified Input FX & Routing

## What We're Building

A simplification and unification of audio input/output routing so that **an input
has a single FX chain, a single set of output routes, and an on/off gate** — and
the FX you monitor is the FX that gets recorded. Today FX are configured in two
disconnected places (per-input *monitor lanes* for live monitoring, and separate
*track lanes* for non-destructive playback FX), recording is always clean, and the
thing you hear while performing is not the thing that gets stored. This rework
collapses that doubling: configure FX once on the input, hear it live, and capture
it (reversibly) when you record.

Recording stays **non-destructive by default** — the recorded buffer is still
clean, and the input's FX chain is *snapshot-copied* onto the new track lane and
re-applied on playback. A new **commit/freeze** action bakes that FX into the
buffer when the user is sure. Outputs gain a **structural on/off gate** (an
output that is "off" is removed from the routing graph as a target; existing route
assignments are preserved so re-enabling restores them, distinct from mute).

## Why This Approach

Three implementation shapes were considered:

1. **Incremental fold (chosen)** — reshape the existing models in place: collapse
   `InputMonitor.lanes` down to a single FX chain + output mask on the input, and
   reuse the *already-shipped* non-destructive track-lane FX as the
   "reapply-on-playback" mechanism. Recording simply snapshots the input FX onto
   the track lane. Add the commit-to-bake action and the structural output gate on
   top. Lowest risk, reuses proven stereo-FX DSP and the track-lane playback path,
   ships as small stackable PRs.
2. **Unified "channel strip" abstraction** — one `Channel` type shared by inputs
   and outputs. More symmetrical, but outputs carry no FX in this design, so the
   symmetry is half-cosmetic (YAGNI), and the blast radius across engine/FFI/repo/
   blocs is large. Rejected.
3. **Engine-printed FX (destructive)** — apply input FX directly into the record
   buffer, no snapshot/commit. Simplest engine, but reverses the reversible+commit
   decision below. Rejected.

The incremental fold wins because most of the user-facing capability already
exists — per-input FX, the input enable gate, and non-destructive playback FX are
all shipped. The genuine gap is (a) recording does not carry the input's FX, and
(b) FX must be configured twice. Folding solves both while reusing the engine code
that already works.

## Key Decisions

- **Single FX chain per input.** Each input collapses to one FX chain + one output
  mask + on/off, replacing the multi-lane monitor model. The chain you monitor is
  the chain that records. *Rationale:* cleanest mental model; eliminates the
  monitor-FX-vs-track-FX doubling. *Cost:* supersedes the just-shipped per-input
  multi-lane monitoring (dry-to-FOH / wet-to-monitor split) — requires a migration
  that folds existing monitor lanes to a single chain.
- **Non-destructive by default, with a commit/freeze toggle.** Recording captures
  a clean buffer plus a snapshot of the input's FX as the track lane's playback FX
  (fully reversible). An explicit commit action bakes the FX into the buffer.
  *Rationale:* keeps the WYSIWYG feel without giving up the ability to change or
  remove FX after recording.
- **Copy-on-record, not a live reference.** The new track lane gets its own copy
  of the input's FX chain. *Rationale:* each recording is its own entity; later
  tweaking the input's FX for the next take must not retroactively alter earlier
  tracks.
- **Output on/off is structural.** "Off" removes the output from the routing graph
  as a selectable target; it is distinct from mute. *Rationale:* matches the user's
  intent that toggling an output changes the graph, not just the signal level.
- **Output gate preserves routes.** Turning an output off keeps stored route/mask
  assignments inactive; turning it back on restores them — mirroring how the input
  enable gate already behaves. *Rationale:* least destructive, consistent with the
  existing input gate semantics.

## Open Questions

- **Migration specifics.** The current persistence format is v2 (wet→lane 0,
  dry→lane 1 per input). How exactly should multiple existing monitor lanes fold
  into one chain — take lane 0, or merge? Define the v2→v3 migration in the plan.
- **Commit/freeze UX & engine path.** Is commit per-track-lane only? Is it
  undoable (keep the clean buffer alongside the baked one, or replace)? How does it
  interact with the existing undo span on `le_track`?
- **Dead code from the superseded feature.** Multi-lane monitor UI (lane add/remove,
  per-lane routing/mix) and `MonitorCubit` lane APIs need removal or repurposing —
  scope the deletion.
- **Output-off UX.** When an output goes off, how do routes pointing at it surface
  in the graph UI (greyed target vs. hidden)? Tie to the "literal graph" / drag UI
  conventions.
- **Recording from a disabled input.** Should the record lane's input assignment
  respect the input on/off gate, or is record routing independent of monitoring?
- **PR sequencing.** Likely splits: (1) engine — single-chain input + record-FX
  snapshot; (2) commit/freeze; (3) output structural gate; (4) Dart repo/bloc +
  migration; (5) UI fold + dead-code removal. Confirm during `/plan`.
