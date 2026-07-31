---
title: "FX system v3 — execution guide (living document)"
type: docs
date: 2026-07-28
issue: 351
---

# FX system v3 — execution guide

> **Living document.** Any session that merges a part MUST update that part's
> Status cell (and the "Next up" line) before it ends — that is what keeps
> every future session auto-oriented. Model/effort cannot be switched by a
> running session; they are chosen at session start, which is why each part
> plan carries its recommendation in its own header.

**Epic:** [#351](https://github.com/tomassasovsky/loopy/issues/351) ·
**Plan index:** [2026-07-28-feat-fx-system-v3-plan.md](2026-07-28-feat-fx-system-v3-plan.md)

## How to start any part

1. Confirm the part's dependencies are **Merged** in the table below.
2. Open a **fresh session** (clean context) on a new worktree/branch.
3. Pick the **model + effort from the table** in the model selector.
4. Say: `/build docs/plan/2026-07-28-feat-fx-system-v3-part-<id>-plan.md`
5. The session creates the part's child issue (`stage:build` + the autonomy
   label below), builds to green, opens the PR (`Closes #<child>`,
   `stage:in-review`, gate labels), and — if labeled `autonomy:auto` —
   merges when CI is green and `/code-review` is clean.
6. **Before ending: update this table** (Status cell + Next up).

## Status

**Next up:** everything through the pedal-plate presentational extraction is
merged (0, 1a, 1b, 2, 3a, 3b, 4a, 4b, 5a, 5b, 6a). **6b** (remap bindings +
momentary) is built and in review. **7** (expression + external MIDI) unblocks
once 6b lands — it reuses 6b's sealed target type and release-all rule.

[#410](https://github.com/tomassasovsky/loopy/pull/410) — the #403
press/long-press gesture-helper collapse this guide called for before 6b —
is MERGED; 6b was rebased onto it.

**[B10] amendment** (from #399's review, carried forward through 5b): the
codec-level downgrade degrades **both** v3-only values below v3 — mode fx →
play AND `PedalTrackLed.blue` → green — because pre-5a firmware rejects a
frame carrying an unknown LED index wholesale. 5b's projection emits fx and
blue unconditionally; the codec alone owns the per-version degrade. The part-5a
plan's original wording ("only the mode-field downgrade differs") predates this
amendment; `PedalCodec`'s doc comments are the authority. 5b's own faceplate
labels had to learn the same lesson — they read the live `InteractionMode`,
never `frame.mode`, precisely because the wire mode is degraded in lockstep
with the LED colour.

Open items carried out of merged parts, neither blocking a new part:
- [#389](https://github.com/tomassasovsky/loopy/issues/389) (`plan-gate`, from
  3b) — a session load never writes the applied chains back to settings, so a
  cold boot after a load resurrects the previous session's **bus** chains and
  brings the Loop stage back **dry**. Needs a direction call on whether a
  session load owns the settings keys; schedule it before 4b if the Signal
  surface is meant to show trustworthy post-restart state.
- Part 2's [B4] A/B listen check — the human exit-bar item on the wet cache,
  which no CI job can stand in for.
- [#405](https://github.com/tomassasovsky/loopy/issues/405) (`plan-gate`, from
  5b) — part 5b's [A5] capture finalize was CUT from the part. Entering FX
  cancels every pending arm (so nothing can start a take the user cannot see),
  but a live capture survives into FX exactly as it does into Mute. Ending it
  needs an engine primitive that ignores quantize — a record press arms a
  loop-top finalize instead, and with the transport parked it starts a capture
  — plus a call on whether an off-grid cut is musically right at all. Not a 6b
  blocker.
- [#402](https://github.com/tomassasovsky/loopy/issues/402)
  (`blocked-verify`, from 5b) — the physical-pedal slice: mode cycle on
  hardware, FX LEDs on a v3 pedal, and a v2 pedal showing chain LEDs with the
  mode projected as mute. Everything in 5b is CI- and simulator-verified only.
- [#403](https://github.com/tomassasovsky/loopy/issues/403) (`auto`, from 5b) —
  MERGED as [#410](https://github.com/tomassasovsky/loopy/pull/410): undo, MODE
  and Stop now share one `_HoldGesture`.

| Part | Scope | Model / effort | Autonomy | Depends on | Status |
|------|-------|----------------|----------|------------|--------|
| 0 | arm() fix (standalone bug) | Opus · medium | `auto` | — | merged (#375) |
| 1a | engine bypass + ramp | **Fable · high** | `merge-gate` | — | merged (#379) |
| 1b | track bus + master insert | **Fable · high** | `merge-gate` | 1a | merged (#382) |
| 2 | loop-stage wet cache | **Fable · extra-high** | `merge-gate` | 1a, 1b | merged (#385) |
| 3a | domain model + shared types + CI jobs | **Fable · high** | `merge-gate` | 1a, 1b | merged (#386) |
| 3b | session v5 migration + manifest stages | Opus · medium | `merge-gate` | 3a, 0 | merged (#388) |
| 4a | delete dead FX code | Sonnet · low | `auto` | — | merged (#392) |
| 4b | four-stage Signal surface | Opus · medium | `merge-gate` | 3a, 4a | merged (#395) |
| 5a | protocol v3 wire + version discovery | **Fable · high** | `merge-gate` | — (#331 prereq) | merged (#399) |
| 5b | FX interaction mode (app) | Opus · high | `merge-gate` (physical slice `blocked-verify`) | 5a, 3a, 1a | merged (#404) |
| 6a | faceplate presentational extraction | Sonnet · medium | `auto` | — | merged (#408) |
| 6b | remap bindings + momentary | Opus · high | `merge-gate` | 6a, 5b, 3a | in-review (#412) |
| 7 | expression + external MIDI | Opus · high | `merge-gate` | 3a, 6b | pending |
| 8 | TRS jack hardware (non-gating child) | Fable · high (at bench) | `blocked-verify` | 7 | pending |
| 9 | hardening + export + soak | Opus · medium | `blocked-verify` | all | pending |

Status values: `pending` → `building (#issue)` → `in-review (#PR)` →
`merged (#PR)`.

**6b notes for part 7.** The pieces 7 inherits, and the decisions behind them:

- `lib/control/binding/` holds the whole model: `FxBindingTarget` (sealed
  chain/slot), `PedalBinding` + `PedalBindingKey`, `PedalBindingSet`, and the
  `FxBindingResolver` extension on `LooperRepository`. Expression/CC bindings
  reuse the sealed target and the resolver verbatim — only the KEY type is
  new.
- The target encoding EXTENDS `FxAddress` canonical JSON rather than
  redeclaring it (R19): a chain target's string IS the address string; a slot
  target appends one `slot` key. Safe because `FxAddress.fromJson` ignores
  unknown keys.
- Bindings live in `ControlState` (`globalBindings` / `sessionBindings` /
  `heldMomentary`), not in cubit fields — the Signal chips and the assignment
  screen both rebuild on `emit`. `state.bindings` derives the A12 merge, so
  the two sets can never disagree about which applies.
- `releaseAllMomentary()` is the ONE enforcement point (B1); the restore
  VALUES stay in a private cubit map, only the held KEY set is in state.
  Part 7's CC path must funnel through the same method.
- Persistence: settings key `pedal.bindings` for globals; `Session.pedalBindings`
  (manifest **v6**, opaque, presence-keyed) for the session set, threaded
  through `SessionCubit`'s `currentPedalBindings` / `onPedalBindings` function
  seams rather than a cubit-to-cubit link.

## Ordering and parallelism

- Critical chain: **1a → 1b → {2 ∥ 3a} → 3b/4b → 5b → 6b → 7 → 8**.
- **2 and 3a run in parallel** after 1b (different sessions/worktrees).
- 0, 4a, 5a, 6a have no in-epic dependencies — slot in any time.
- Only 1a→1b→2 is a true stacked chain: mind the repo's squash-merge
  child-rebase discipline.

## Model / effort rationale

- **Fable, high or extra-high** where a mistake corrupts audio or a wire
  protocol: audio-thread/lock-free work (1a, 1b, 2), the shared type
  foundation everything builds on (3a), dual-firmware wire lockstep (5a),
  hardware (8). Part 2 is the single riskiest part (cache lifecycle) —
  use extra-high effort.
- **Opus, medium/high** for well-specified app/domain work (0, 3b, 4b, 5b,
  6b, 7, 9); `/fast` is fine for UI iteration loops (4b).
- **Sonnet** for mechanical parts: deletion (4a, low), extraction refactor
  (6a, medium).
- On `auto` parts the session merges itself once CI is green and
  `/code-review` is clean; if a judgment call appears it must stop and
  relabel (escalation is always allowed).

## Gates recap

- A PR is mergeable only when **CI is green AND `/code-review` is clean**
  (`ready-to-merge` label). `/code-review` is human-triggered.
- Docs PR [#367](https://github.com/tomassasovsky/loopy/pull/367) carries
  this guide + all plans; it must merge before part child-issues start.
