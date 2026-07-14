---
title: fix license_check.yaml path filter to catch package-level dependency changes
type: fix
date: 2026-07-13
---

## fix license_check.yaml path filter to catch package-level dependency changes - Minimal

`.github/workflows/license_check.yaml` only triggers (on `pull_request` and
`push`) when the root `pubspec.yaml` or the workflow file itself changes.
Dependencies are routinely added via one of the 13 `packages/*/pubspec.yaml`
manifests, which resolve into the committed root `pubspec.lock` — the file
the license-check job actually reads from — without ever touching root
`pubspec.yaml`. New, possibly incompatibly-licensed dependencies can
therefore merge without the license gate running at all. Widen the `paths:`
filters on both triggers so the workflow fires on any change that can alter
the resolved dependency set.

## Success Criteria

> **Post-review update:** the code-simplicity-review-agent (see Technical
> Review Update below) made a strong case that `pubspec.lock` alone fully
> closes the gap — it is the one file guaranteed to change for *every*
> dependency addition (root or package-level), and it's the exact file the
> license-check job reads. Adding `packages/**/pubspec.yaml` on top adds diff
> surface without adding real coverage (a package pubspec.yaml edit only
> matters once it's reflected in the committed lock file, which the
> `pubspec.lock` trigger already catches). Adopted: **`pubspec.lock` only**,
> not both patterns. This section reflects that final decision.

```success-criteria
GOAL: license_check.yaml's pull_request and push triggers fire whenever the
resolved dependency set changes (i.e. pubspec.lock changes) — including
package-level dependency additions in packages/*/pubspec.yaml, which land in
pubspec.lock without touching root pubspec.yaml — not just root pubspec.yaml
edits, while remaining valid GitHub Actions YAML.

SUCCESS CRITERIA:
- Both `pull_request.paths` and `push.paths` in .github/workflows/license_check.yaml
  include "pubspec.yaml", "pubspec.lock", and
  ".github/workflows/license_check.yaml" | verify: ruby -ryaml -e "d=YAML.load_file('.github/workflows/license_check.yaml'); on=d['on']||d[true]; %w[pull_request push].each{|t| paths=on[t]['paths']; %w[pubspec.yaml pubspec.lock .github/workflows/license_check.yaml].each{|p| raise \"missing #{p} in #{t}\" unless paths.include?(p)}}; puts 'ok'"
- The workflow file is syntactically valid YAML | verify: ruby -ryaml -e "YAML.load_file('.github/workflows/license_check.yaml'); puts 'valid yaml'"
- No other lines in the workflow (job config, `allowed`, `skip_packages`, concurrency, branches) are changed | verify: manual diff .github/workflows/license_check.yaml against origin/master and confirm the only changed lines are within the two `paths:` lists
- git diff for this change touches only .github/workflows/license_check.yaml | verify: test "$(git diff --name-only origin/master... -- . | grep -v '^docs/')" = ".github/workflows/license_check.yaml"

NON-GOALS:
- Adding CI coverage for the 13 packages' own format/analyze checks (separate, parallel effort by another agent).
- Changing the `allowed` license list, `skip_packages`, or any job logic in license_check.yaml.
- Auditing or fixing any actual license-incompatible dependency.
- Adding a `packages/**/pubspec.yaml` path pattern — considered and rejected as redundant with `pubspec.lock` (see post-review update above).

VERIFICATION COMMAND: ruby -ryaml -e "d=YAML.load_file('.github/workflows/license_check.yaml'); on=d['on']||d[true]; %w[pull_request push].each{|t| paths=on[t]['paths']; %w[pubspec.yaml pubspec.lock .github/workflows/license_check.yaml].each{|p| raise \"missing #{p} in #{t}\" unless paths.include?(p)}}; puts 'ok'" && ruby -ryaml -e "YAML.load_file('.github/workflows/license_check.yaml'); puts 'valid yaml'" && test "$(git diff --name-only origin/master... -- . | grep -v '^docs/')" = ".github/workflows/license_check.yaml"
```

## Context

- File: `.github/workflows/license_check.yaml` (32 lines total, both `on.pull_request.paths` and `on.push.paths` currently list only `pubspec.yaml` and `.github/workflows/license_check.yaml`, lines 11-13 and 17-19).
- The license-check job itself is a reusable workflow
  (`VeryGoodOpenSource/very_good_workflows/.github/workflows/license_check.yml@v1`)
  that reads the resolved `pubspec.lock` to enumerate transitive licenses — it
  is unaffected by this change; only the trigger paths change.
- Repo has 13 packages under `packages/*/pubspec.yaml`, each with their own
  `dependencies:` (e.g. `packages/loopy_engine/pubspec.yaml` declares
  `ffi: ^2.1.3`, absent from root `pubspec.yaml`). Adding or bumping any such
  dependency changes the committed root `pubspec.lock` without touching root
  `pubspec.yaml`.
- Brainstorm doc: `docs/brainstorm/2026-07-13-license-check-path-filter-brainstorm-doc.md`
  — originally proposed adding both `packages/**/pubspec.yaml` and
  `pubspec.lock`; superseded by the technical-review decision below to add
  `pubspec.lock` only.
- No local YAML/Actions linter is installed (`actionlint`, `yamllint`, `yq`
  all absent). Ruby's built-in `psych` (`ruby -ryaml`) is available on this
  macOS box and is used above purely as a **syntax + structural** validator —
  it does not simulate GitHub's actual path-filter matching, but confirms the
  file parses as valid YAML and that the expected literal strings are present
  in each `paths:` array.

## MVP

Edit `.github/workflows/license_check.yaml` lines 11-13 and 17-19 from:

```yaml
    paths:
      - "pubspec.yaml"
      - ".github/workflows/license_check.yaml"
```

to (both occurrences):

```yaml
    paths:
      - "pubspec.yaml"
      - "pubspec.lock"
      - ".github/workflows/license_check.yaml"
```

No other lines change.

## Technical Review Update

Ran `/plan-technical-review` (code-simplicity-review-agent, vgv-review-agent,
plan-splitting-agent, in parallel, autonomous run — no live user to consult).

- **plan-splitting-agent**: no split needed — single-file, ~6-line CI config
  change, tightly scoped, no split benefit.
- **vgv-review-agent**: no issues; `packages/**/pubspec.yaml` glob syntax is
  valid and idiomatic for this repo (matches glob style used elsewhere, e.g.
  `main.yaml`'s spell-check `includes: **/*.md`); plan otherwise ready as
  written.
- **code-simplicity-review-agent**: flagged `packages/**/pubspec.yaml` as an
  unnecessary YAGNI addition — `pubspec.lock` alone already guarantees
  coverage of every dependency-set change regardless of source, so the extra
  pattern adds diff surface without adding real detection capability.

**Decision**: adopted the simplicity-review recommendation. Final fix adds
only `pubspec.lock` to both `paths:` lists (not `packages/**/pubspec.yaml`).
Rationale: a package-level `pubspec.yaml` edit only becomes a real
dependency-resolution change once it's reflected in the committed
`pubspec.lock` (which the license-check job reads); the `pubspec.lock`
trigger alone therefore fully closes the gap described in the issue, and is
the smaller, more defensible diff. All plan sections above (Success Criteria,
Context, MVP) have been updated to reflect this.

## References

- Issue: license_check.yaml path filter misses dependency additions made in packages/*/pubspec.yaml (medium severity, ci category)
- Related repo docs: `docs/loopy-vst3-mit.md` context (VST3 SDK MIT relicensing) — motivates why license classification is load-bearing here
- Brainstorm: `docs/brainstorm/2026-07-13-license-check-path-filter-brainstorm-doc.md`
