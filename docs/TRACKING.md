# Tracking system — how work is tracked in this repo

One place to answer "what's done / in-flight / blocked / next" without reading
prose or reverse-engineering git. **GitHub Issues are the status layer; `docs/`
stay the deep intent.** Each issue is a thin skin over work that already lives in
the repo and links to its brainstorm/plan doc.

This file is the contract. **Any session — human or agent — keeps it current.**

## The pipeline

Every thread moves along one line, mirrored by the `stage:*` label on its issue:

```
brainstorm → plan → plan-review → build → in-review (PR: CI + code-review) → merged (issue closed)
```

Each transition leaves an artifact, so the stage advances off signals we already
produce — no separate status update needed:

| Stage label        | Advanced by                    | Proof artifact                     |
|--------------------|--------------------------------|------------------------------------|
| `stage:brainstorm` | `brainstorm` skill             | `docs/brainstorm/*.md` committed   |
| `stage:plan`       | brainstorm lands               | `docs/plan/*.md` committed         |
| `stage:plan-review`| `plan-technical-review` skill  | review notes / approval            |
| `stage:build`      | branch pushed / first commit   | branch + commits                   |
| `stage:in-review`  | PR opened with `Closes #N`     | PR + `gh pr checks`                |
| (closed)           | PR merges                      | merged PR auto-closes the issue    |

**Rule:** PR bodies must contain `Closes #N` so merges auto-close the issue. The
agent writes that line, not the human.

## The autonomy criteria — which gate needs a human

Each issue carries exactly one `autonomy:*` label. It's a *ceiling*, not a mandate.
Decide it with three questions, in order:

1. **Can it be verified end-to-end here?** (native C tests + Dart tests + `analyze`
   + the `/code-review` skill can prove it). If **no** → `autonomy:blocked-verify`
   (hardware/device-gated: "green in CI" ≠ "works"). Park until on-hardware.
2. **Does it need a judgment you own?** Direction/product/architecture/licensing →
   `autonomy:plan-gate` (stop after the plan; human approves direction). Taste on
   the *result* (UX/visual) → `autonomy:merge-gate`.
3. **Reversible + narrow blast radius?** No (irreversible/outward/wide) →
   `autonomy:merge-gate`. Yes → `autonomy:auto`.

| Label                    | Agent does                              | Human touches it        |
|--------------------------|-----------------------------------------|-------------------------|
| `autonomy:auto`          | brainstorm → build → green → **merge**   | never (audit after)     |
| `autonomy:merge-gate`    | build → green → stop                     | clicks merge            |
| `autonomy:plan-gate`     | brainstorm → plan → stop                 | approves direction      |
| `autonomy:blocked-verify`| build → green in CI, but can't prove it  | validates on hardware   |

**Auto-merge is ON** for the `auto` class — an `autonomy:auto` PR is **merged by
the agent** (`gh pr merge --squash`) the moment it reaches `ready-to-merge`. No
human click for that class; `merge-gate` and above still end on a human merge.

**Escalation is always allowed:** if an `auto` item turns out to need an
architecture/direction call, stop and relabel it `plan-gate` rather than pushing
through.

## The merge gate — "clean = CI AND code-review"

A PR is only mergeable when **both** are green. Two labels track it:

- `ci:red` → `ci:green` — from `gh pr checks`.
- `review:pending` → `review:clean` — after the `/code-review` skill runs and comes
  back empty.

Only when both are green does the PR get `ready-to-merge`. CI green alone is not
enough — the code-review skill must also be clean.

## Keeping it current (agent responsibilities each session)

- Starting a thread? Find or open its issue; set `stage:*` + `autonomy:*`.
- Opening a PR? Add `stage:in-review`, `Closes #N`, `ci:*` + `review:pending`.
- After running `/code-review` on a PR: set `review:clean` (or leave `pending` if
  it has findings). If `ci:green` too, add `ready-to-merge`.
- Finished a part of an `epic`? Tick its checklist box.
- Merged? The `Closes #N` closes the issue automatically.

## Auto-merge (ON)

Agents **merge `autonomy:auto` PRs** with `gh pr merge --squash` the moment they
reach `ready-to-merge` (CI green AND `/code-review` clean). No human click for
that class. Everything `merge-gate` and above still ends on a human merge — those
labels *mean* "a human owns this call" (taste, blast radius, direction).

To pause auto-merge on a specific PR, relabel it `autonomy:merge-gate`.
