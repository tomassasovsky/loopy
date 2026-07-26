---
date: 2026-07-26
topic: sheeran-style-fx-racks-pre-post
---

# Sheeran-style FX Racks (Pre/Post)

## What We're Building

A full redesign of Loopy’s audio FX system toward **Sheeran Looper X parity**:
FX **racks** assignable to **inputs and tracks**, each with **Pre** (printed into
the record/overdub buffer) or **Post** (playback-only, non-destructive), plus
**Live Signal** monitoring (`Auto` / `Off` / `On`), a dedicated **FX page** in
Loopy’s design system, a **full factory rack preset library** with user
save/load, and later **pedal/expression assign**, **bounce As Loop** tails, and
optional **per-lane overrides** on top of track racks.

This replaces the current always-dry capture + whole-chain snapshot-to-lane model
as the primary mental model. Existing Input FX / Lane FX migrate into the new
rack ownership rules.

## Why This Approach

Approaches considered:

1. **Evolve engine to real Pre/Post + Sheeran product surface (chosen)** —
   Extend `engine_fx` / record path so Pre prints wet into the buffer; Post
   remains playback coloring. Domain becomes Input racks + Track racks. UI is a
   dedicated FX page. Ship as a phased epic on the existing stack.
2. **Compatibility shim (rejected)** — Keep always-dry buffers; relabel today’s
   chains Pre/Post in UI. Fast, but not Sheeran semantics; fails “everything like
   the pedal.”
3. **Greenfield FX graph package (rejected)** — New runtime beside the looper
   engine. Too much blast radius; current DSP can grow.

Chosen because the user wants **true Sheeran behavior** (including Pre bake),
full product surface (racks, Live Signal, presets, pedal/expression, bounce),
and Loopy already has reusable DSP + FX UI scaffolding.

## Key Decisions

- **Sheeran parity is the product goal**, not a thin Loopy-native approximation.
  First epic documents and phases the full surface; implementation lands in
  ordered phases.
- **Recording semantics: true Pre bake.** When a rack is Pre, its wet signal is
  written into the lane buffer on record/overdub. Post racks never touch the
  buffer; they color playback only.
- **Ownership: Input + Track**, each with Pre and Post.
- **Chain shape: two lists per owner** (`pre[]` + `post[]`) — UI “racks” with a
  Pre/Post toggle map onto those lists (not a mini graph of mixed-stage racks).
- **Granularity: track chains shared by all lanes**; per-lane overrides later.
- **Live Signal: full Auto / Off / On** (Auto = UI-selected track focus, not
  necessarily `primaryTrack` crown).
- **UI: dedicated FX page**; Signal stays routing/levels.
- **Presets: full factory library** in part 4 (not MVP parts 1–3).
- **Evolve existing engine/repo/UI**; retire snapshot-as-primary after domain
  migration. Do not revive deleted historical `mon_fx` stage fields.
- **Migration default: Post** for both Input FX and Lane FX (safe).
- **Autonomy:** `plan-gate`. Build on `feat/sheeran-style-fx-racks`.

## Open Questions

Resolved into plan-gate P1–P11 on the epic plan (monitor Pre→Post; overdub
reprint; Input Pre before Track Pre; multi-On sum; etc.). Remaining:

- **Pedal/expression mapping targets** — control/MIDI vs appliance footswitches
  (Phase 5 child issue).
- **Bounce As Loop** — looper op vs export-only (Phase 5 child issue).
- **Unify Live Signal focus with primaryTrack crown?** — default no (P11).
