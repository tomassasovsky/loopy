# CLAUDE.md

Guidance for any agent session in this repo. Keep it lean — it loads into every session.

## Build / test / environment

Canonical build, test, and environment gotchas live in **`docs/PROGRESS.md`** —
read its "How to build / test" section first (test runner, hand-authored FFI
plugin, macOS dylib loading, flavor schemes). They will bite otherwise.

### Verify loop — run these before declaring any change done

- Dart/Flutter tests: `/Users/Tomas/development/flutter/bin/flutter test`
  (bare `flutter test`/`dart test` are hook-blocked; the very_good MCP test
  tool is broken in this env)
- Native engine tests: `bash packages/loopy_engine/src/test/run_native_tests.sh`
- Static analysis: `dart analyze` must come back clean
- Formatting is automatic — a PostToolUse hook runs `dart format` on every
  edited `.dart` file, so never hand-format or commit format-only churn

## Work tracking (required)

Work is tracked as **GitHub Issues on a pipeline board**. Full contract:
**`docs/TRACKING.md`**. The pipeline is:

```
brainstorm → plan → plan-review → build → in-review (PR: CI + code-review) → merged
```

**Before starting _substantive_ work** — a feature, a multi-step change, anything
entering brainstorm/plan, or work spanning multiple files or sessions:

1. Find its existing issue, or **create one** if none exists.
2. Label it with one `stage:*` (pipeline position) + one `autonomy:*` (below).
3. Keep the `stage:*` label (or board Status) current as it moves.

**Trivial one-line fixes do NOT need an issue** — go straight to a PR. Don't
flood the board with ceremony for one-liners.

**On every PR:**
- Put `Closes #N` in the body so the merge auto-closes the issue.
- Label `stage:in-review`, the right `autonomy:*`, and the gate labels `ci:*` + `review:pending`.
- A PR is mergeable **only when CI is green AND `/code-review` comes back clean.**
  When both hold, add `ready-to-merge`.

### Autonomy — which gate needs a human (one label per issue, a ceiling not a mandate)

- `autonomy:auto` — verifiable here + reversible + narrow → take to green and **merge it** (`gh pr merge --squash`) once `ready-to-merge` (CI green + `/code-review` clean). No human click.
- `autonomy:merge-gate` — verifiable but taste / blast-radius → build, human merges.
- `autonomy:plan-gate` — needs a direction / architecture / licensing call → stop after the plan.
- `autonomy:blocked-verify` — hardware / device-gated; "green in CI" ≠ "works".

Decide with three questions in order: (1) verifiable end-to-end here? no →
`blocked-verify`. (2) needs a judgment you own? direction → `plan-gate`, taste on
the result → `merge-gate`. (3) reversible + narrow? no → `merge-gate`, yes → `auto`.

**Escalation is always allowed:** if an `auto` item turns out to need a design
call, stop and relabel it `plan-gate` rather than pushing through.
