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

**Next up:** merge gate on part 1b (PR #382, build green — human merges);
then 2 and 3a in parallel. 4a / 5a / 6a have no in-epic dependencies and can
run in parallel any time.

| Part | Scope | Model / effort | Autonomy | Depends on | Status |
|------|-------|----------------|----------|------------|--------|
| 0 | arm() fix (standalone bug) | Opus · medium | `auto` | — | merged (#375) |
| 1a | engine bypass + ramp | **Fable · high** | `merge-gate` | — | merged (#379) |
| 1b | track bus + master insert | **Fable · high** | `merge-gate` | 1a | merged (#382) |
| 2 | loop-stage wet cache | **Fable · extra-high** | `merge-gate` | 1a, 1b | pending |
| 3a | domain model + shared types + CI jobs | **Fable · high** | `merge-gate` | 1a, 1b | building (#384) |
| 3b | session v5 migration + manifest stages | Opus · medium | `merge-gate` | 3a, 0 | pending |
| 4a | delete dead FX code | Sonnet · low | `auto` | — | pending |
| 4b | four-stage Signal surface | Opus · medium | `merge-gate` | 3a, 4a | pending |
| 5a | protocol v3 wire + version discovery | **Fable · high** | `merge-gate` | — (#331 prereq) | pending |
| 5b | FX interaction mode (app) | Opus · high | `merge-gate` (physical slice `blocked-verify`) | 5a, 3a, 1a | pending |
| 6a | faceplate presentational extraction | Sonnet · medium | `auto` | — | pending |
| 6b | remap bindings + momentary | Opus · high | `merge-gate` | 6a, 5b, 3a | pending |
| 7 | expression + external MIDI | Opus · high | `merge-gate` | 3a, 6b | pending |
| 8 | TRS jack hardware (non-gating child) | Fable · high (at bench) | `blocked-verify` | 7 | pending |
| 9 | hardening + export + soak | Opus · medium | `blocked-verify` | all | pending |

Status values: `pending` → `building (#issue)` → `in-review (#PR)` →
`merged (#PR)`.

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
