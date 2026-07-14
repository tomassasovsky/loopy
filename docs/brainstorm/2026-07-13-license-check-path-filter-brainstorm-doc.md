---
date: 2026-07-13
topic: license-check-path-filter
---

# license_check.yaml path filter misses package-level dependency changes

## What We're Building

`.github/workflows/license_check.yaml` currently only triggers (on both the
`pull_request` and `push` triggers) when `pubspec.yaml` (the root manifest) or
the workflow file itself changes. In this repo, dependencies are routinely
added via one of the 13 `packages/*/pubspec.yaml` manifests (e.g.
`loopy_engine`'s `ffi: ^2.1.3`), which resolve into the single committed root
`pubspec.lock` — the file the license checker actually reads from — without
ever touching the root `pubspec.yaml`. That means a PR that introduces a new,
possibly incompatibly-licensed dependency through a package can merge without
the license gate ever running.

The fix is a path-filter-only change to `.github/workflows/license_check.yaml`:
widen both triggers' `paths:` lists so the workflow fires on any change that
can alter the resolved dependency set, not just root-manifest edits.

## Why This Approach

This is a CI-configuration-only fix (no workflow logic, job definition, or
license policy changes). The only real design decision is *which paths* to
add. Three options were considered:

**Add `pubspec.lock` only** — Not chosen, but a close runner-up.
`pubspec.lock` is the single source of truth the license-check job reads from,
and it is the one file guaranteed to change for *every* dependency addition
regardless of whether it was declared in the root manifest or a package
manifest. Triggering on it alone would technically close the gap.

- Pros: minimal, and precisely matches "did the resolved dependency set
  change."
- Cons: doesn't signal *intent* as clearly in workflow config/diffs, and
  offers no safety net for the (out-of-scope, but plausible) case of a
  contributor editing a package `pubspec.yaml` without regenerating the lock
  file in the same commit — the gate would then silently miss it too, same as
  today.

**Add `packages/**/pubspec.yaml` only** — Not chosen.
Covers the specific gap called out in the issue (package-level manifests) but
leaves the same class of blind spot open for any other future source of
lockfile-only diffs (e.g. a dependency_override edited directly, or a future
package-of-packages layout change).

**Add both `packages/**/pubspec.yaml` and `pubspec.lock` (recommended).**
This is the issue's suggested fix direction and is what we're implementing.
Belt-and-suspenders: `pubspec.lock` is the authoritative trigger (catches
every case, including ones no one has thought of yet), and
`packages/**/pubspec.yaml` makes the intent legible in the workflow file
itself and guards the specific case the review flagged. The marginal cost of
listing both patterns in a `paths:` array is zero — it's a config-only change
with no runtime cost — so there's no real tradeoff to weigh against the
extra robustness.

## Key Decisions

- **Add two new path patterns** to both the `pull_request` and `push`
  triggers in `.github/workflows/license_check.yaml`:
  `packages/**/pubspec.yaml` and `pubspec.lock`. Root `pubspec.yaml` and the
  workflow file itself stay in the list unchanged.
- **No changes to job logic, `allowed` license list, or `skip_packages`** —
  strictly a trigger-path fix, matching the issue's narrow scope.
- **Validate YAML syntax before shipping.** Since GitHub Actions doesn't
  offer a full local "would this trigger" simulator for path filters, the
  plan will validate with a local YAML parser (e.g. `python3 -c "import
  yaml; yaml.safe_load(...)"` or `yq`) and, if available, `gh workflow view`
  / `actionlint` to confirm the workflow is still syntactically valid and
  schema-correct after the edit.
- **Autonomous run assumption**: since this run has no live user to
  interactively dialogue with, the "add both patterns" decision was made
  directly from the issue's own suggested fix direction and evidence,
  without an interactive brainstorm dialogue. This is documented here as the
  assumption in place of a blocking question.

## Open Questions

- None blocking. One minor note for the planning phase: confirm whether
  `paths:` glob syntax in this repo's GitHub Actions version supports `**`
  for arbitrary-depth matching under `packages/` (it does, per GitHub's
  documented path-filter glob syntax, but worth a quick confirmation during
  plan review since it's the crux of the fix).
