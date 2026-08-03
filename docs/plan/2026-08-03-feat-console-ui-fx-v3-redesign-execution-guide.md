---
title: "Console UI redesign — execution guide (living document)"
type: docs
date: 2026-08-03
issue: 442
---

# Console UI redesign — execution guide

> **Living document.** Any session that merges a part MUST update that part's
> Status cell (and the "Next up" line) before it ends — that is what keeps
> every future session auto-oriented. Model/effort cannot be switched by a
> running session; they are chosen at session start, which is why each part
> plan carries its recommendation in its own header.

**Epic:** [#442](https://github.com/tomassasovsky/loopy/issues/442) ·
**Plan index:** [2026-08-03-feat-console-ui-fx-v3-redesign-plan.md](2026-08-03-feat-console-ui-fx-v3-redesign-plan.md) ·
**Brainstorm:** [2026-08-02-console-ui-fx-v3-redesign-brainstorm-doc.md](../brainstorm/2026-08-02-console-ui-fx-v3-redesign-brainstorm-doc.md)

## How to start any part

1. Confirm the part's dependencies are **Merged** in the table below.
2. Split the part out of the index into its own
   `2026-08-03-feat-console-ui-fx-v3-redesign-part-<id>-plan.md` if it does not
   exist yet. Once the part file exists it is canonical.
3. Open a **fresh session** (clean context) on a new worktree/branch.
4. Pick the **model + effort from the table** in the model selector.
5. Say: `/build docs/plan/2026-08-03-feat-console-ui-fx-v3-redesign-part-<id>-plan.md`
6. The session creates the part's child issue (`stage:build` + the autonomy
   label below), builds to green, opens the PR (`Closes #<child>`,
   `stage:in-review`, gate labels), and — if labeled `autonomy:auto` — merges
   when CI is green and `/code-review` is clean.
7. **Before ending: update this table** (Status cell + Next up).

## Status

**Next up:** part 1 is MERGED (#480) and part 7 is in review (#485). **Part 3
(racks) is the next real work** — it is the long pole and has no in-epic
dependencies. Part 2 (7" readout) is also unblocked and independent.

Before starting part 3, land
[#389](https://github.com/tomassasovsky/loopy/issues/389): it rewrites the
same persistence paths and is a `plan-gate` direction call, so it is cheaper
to settle first than to unpick afterwards.

Two shapes parts 4/5 should copy from 1 and 7:
- The cubit has ONE destination entry point, `showDestination`. Part 1 dropped
  the Tuner *tile* (the rail item replaces it) and therefore needs no
  `openTuner()`; a per-destination opener with no production caller is dead
  code with a passing test in front of it.
- `_iconFor`, `_labelFor` and the panel's face switch are all exhaustive over
  `SettingsTrayDestination`, so adding a value breaks the build in every place
  that must change. Part 7 confirmed this works — keep it.

Part 1's split amended two index assumptions the code contradicted: the tray
is already near-fullscreen with a destination-keyed face switcher, and the
destination enum is **not** pre-populated with placeholders — each of parts 4,
5 and 7 adds its own enum value alongside its panel rather than shipping dead
rail items. Later part splits should expect the same: the index is source
material, the part file is canonical.

**Direction decisions D1–D7** are pinned in the index plan's "Key Decisions"
section and are not to be revisited by a part session. If a part discovers a
decision is wrong, stop and escalate to `plan-gate` rather than pushing
through.

**Protocol warning for part 8.** The v3 pedal mode field is 2 bits and value
`3` is explicitly reserved and rejected on decode
(`pedal_codec.dart:248`, `:303`). Custom mode needs **protocol v4**, not the
reserved slot. Do not start part 8 assuming a free value.

**Screenshot goldens.** `test/screenshots/` skips everywhere but the author's
machine and rots silently. Every UI part regenerates and eyeballs them;
part 9 is the backstop, not the only pass.

Related work that is **not** in this epic but touches the same code:
- [#389](https://github.com/tomassasovsky/loopy/issues/389) (`plan-gate`) — a
  session load never writes applied chains back to settings, so a cold boot
  resurrects the previous session's chains. Part 3 rewrites the same
  persistence paths; schedule #389 **before** part 3, not after.
- [#372](https://github.com/tomassasovsky/loopy/issues/372) — virtual slider
  pots on the 7″, overlapping part 2's surface.
- [#453](https://github.com/tomassasovsky/loopy/issues/453) — persistent
  device-lost / MIDI-lost surface, which needs a home in the new shell.
- [#198](https://github.com/tomassasovsky/loopy/issues/198) — accessibility
  audit; part 9's rail focus-order pass feeds it.

| Part | Scope | Model / effort | Autonomy | Depends on | Status |
|------|-------|----------------|----------|------------|--------|
| [1](2026-08-03-feat-console-ui-fx-v3-redesign-part-1-plan.md) | drawer navigation rail (shell only) | Opus · medium | `merge-gate` | — | merged (#480) |
| 2 | 7″ permanent performance readout | Opus · medium | `merge-gate` | — | in-review (#487) |
| 3 | rack domain + global library + migration | **Fable · high** | `merge-gate` | — | pending |
| 4 | FX panel: stage tabs + rack UI | Opus · high | `merge-gate` | 1, 3 | pending |
| 5 | Routing panel: stage tabs | Opus · high | `merge-gate` | 1, 4 | pending |
| 6 | three-state live-monitor control | Opus · high | `merge-gate` | 3, 4 | pending |
| [7](2026-08-03-feat-console-ui-fx-v3-redesign-part-7-plan.md) | Pedal panel as a rail destination (#440) | Sonnet · medium | `auto` | 1 | in-review (#485) |
| 8 | Custom pedal mode + protocol v4 | **Fable · high** | `merge-gate` (hardware slice `blocked-verify`) | 7 | pending |
| 9 | hardening: goldens, soak, docs | Opus · medium | `blocked-verify` | all | pending |

Status values: `pending` → `building (#issue)` → `in-review (#PR)` →
`merged (#PR)`.

## Why these autonomy labels

- **Part 7 is `auto`** — it re-mounts an existing page at a new location,
  verifiable here, reversible, narrow.
- **Parts 1–6 are `merge-gate`** — every one of them is a taste call on a
  surface the user performs on. Verifiable in CI, but "the tests pass" is not
  the bar for a redesign.
- **Part 8's hardware slice is `blocked-verify`** — a v3 pedal receiving a v4
  frame cannot be proven in CI.
- **Part 9 is `blocked-verify`** — appliance soak needs the console.
