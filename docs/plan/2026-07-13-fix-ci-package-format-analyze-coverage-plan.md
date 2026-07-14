---
title: CI format + analyze steps must cover packages/*, not just root lib/test
type: fix
date: 2026-07-13
---

## CI format + analyze steps must cover packages/*, not just root lib/test - Minimal

`.github/workflows/main.yaml`'s `build` job invokes VeryGoodOpenSource's
reusable `flutter_package.yml@v1` without overriding `format_directories` or
`analyze_directories`. Both default to `"lib test"` relative to
`working_directory: "."`, so `dart format --set-exit-if-changed lib test` and
`flutter analyze lib test` only ever check the root app. None of the 13
packages under `packages/` (daw_export, performance_repository, wav_codec,
loopy_engine, controller_repository, local_storage_client,
looper_repository, midi_client, midi_device_repository, pedal_repository,
routing_graph, session_repository, settings_repository) get any format or
analyze gate in CI, so analyzer lints and `dart format` drift in package code
can merge silently (confirmed in brainstorming: this already happened —
`packages/looper_repository/test/looper_repository_test.dart` is currently
unformatted).

Fix: extend `format_directories`/`analyze_directories` on the existing
`build` job to also glob every package's `lib` and `test` directories, and
fix the one pre-existing format violation so the new gate is green on
merge.

## Success Criteria

```success-criteria
GOAL: Every package under packages/ is format-checked and analyzed by the
existing CI `build` job, the same way the root app already is, with no new
job and no change to test execution (test_recursion stays false) or to
license_check.yaml.

SUCCESS CRITERIA:
- main.yaml's build job passes explicit format_directories and analyze_directories inputs to flutter_package.yml@v1 that include both the root ("lib test") and every package's lib+test via a glob | verify: grep -A2 'format_directories' .github/workflows/main.yaml | grep -q 'packages/\*/lib' && grep -A2 'analyze_directories' .github/workflows/main.yaml | grep -q 'packages/\*/lib'
- dart format --set-exit-if-changed over root + all packages' lib/test exits 0 (no formatting drift left in the tree) | verify: cd /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/agent-a7e71863edb276596 && dart format --set-exit-if-changed lib test packages/*/lib packages/*/test
- flutter analyze over root + all packages' lib/test exits 0 (no analyzer issues) | verify: cd /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/agent-a7e71863edb276596 && flutter analyze lib test packages/*/lib packages/*/test
- The workflow YAML is still valid YAML | verify: cd /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/agent-a7e71863edb276596 && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/main.yaml'))"
- A deliberately-introduced lint/format violation in a package is demonstrated to be caught by the new directory list (already proven once during brainstorming; re-confirm after the final diff is in place) | verify: manual 1) temporarily add a badly-formatted function with an unused local variable to any packages/*/lib file 2) run the two dart format / flutter analyze commands above with the new directory args and confirm non-zero exit + the issue reported 3) revert the temporary change and re-run to confirm clean exit 0 again
- license_check.yaml is untouched | verify: git diff --name-only master... | grep -qv 'license_check.yaml' && ! git diff --name-only master... | grep -q 'license_check.yaml'

NON-GOALS:
- Adding a package-level unit-test job or flipping test_recursion to true (separate, already-known intentional gap).
- Touching license_check.yaml's path filter (owned by a separate parallel fix).
- Any refactor of package source beyond the one mechanical dart-format fix required to make the new gate pass at merge time.
- Parallelizing or matrix-izing per-package CI (out of scope; see brainstorm doc's Approach B rejection).

VERIFICATION COMMAND: cd /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/agent-a7e71863edb276596 && dart format --set-exit-if-changed lib test packages/*/lib packages/*/test && flutter analyze lib test packages/*/lib packages/*/test && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/main.yaml'))"
```

## Context

- Brainstorm doc: `docs/brainstorm/2026-07-13-ci-package-format-analyze-coverage-brainstorm-doc.md`
  — contains the full investigation: fetched the reusable workflow's actual
  source (`VeryGoodOpenSource/very_good_workflows/.github/workflows/flutter_package.yml`)
  and confirmed `format_directories`/`analyze_directories` are spliced
  unmodified into plain bash `run:` steps, so a glob like `packages/*/lib`
  expands normally — no special multi-dir support needed from the reusable
  workflow. This was verified empirically in this worktree, not assumed:
  - `dart format --set-exit-if-changed lib test packages/*/lib packages/*/test`
    surfaced one real pre-existing violation in
    `packages/looper_repository/test/looper_repository_test.dart`.
  - `flutter analyze lib test packages/*/lib packages/*/test` found **zero**
    issues across all 13 packages (they're already lint-clean).
  - A deliberately-introduced violation in `packages/wav_codec/lib/wav_codec.dart`
    was correctly caught by both commands, using that package's own
    `analysis_options.yaml` (`package:very_good_analysis`) — proving
    per-package lint config is respected — then reverted.
- Current `build` job (`.github/workflows/main.yaml` lines ~19-27):
  ```yaml
  build:
    uses: VeryGoodOpenSource/very_good_workflows/.github/workflows/flutter_package.yml@v1
    with:
      flutter_version: "3.44.x"
      run_bloc_lint: true
      min_coverage: 90
      coverage_excludes: "**/window_chrome.dart **/waveform_window*.dart **/run_loopy.dart **/bootstrap.dart **/session_directory.dart"
  ```
- `run_bloc_lint: true` runs a separate, hardcoded `bloc lint .` step in the
  reusable workflow that already scans the whole repo regardless of
  `format_directories`/`analyze_directories` — untouched by this fix.
- All 13 packages under `packages/` have both a `lib/` and a `test/`
  directory (verified via `ls`), so a bare `packages/*/lib
  packages/*/test` glob covers every package uniformly with no dangling
  literal-glob edge case.
- Institutional gotcha (`loopy-ffigen-format-drift` memory): ffigen
  regeneration in `packages/loopy_engine/lib/src/generated/` is a known
  recurring source of format drift; this fix is what would have caught it in
  CI going forward.

## MVP

Two-part change:

1. **`.github/workflows/main.yaml`** — add `format_directories` and
   `analyze_directories` inputs to the `build` job's `with:` block:

   ```yaml
   build:
     uses: VeryGoodOpenSource/very_good_workflows/.github/workflows/flutter_package.yml@v1
     with:
       flutter_version: "3.44.x"
       run_bloc_lint: true
       format_directories: "lib test packages/*/lib packages/*/test"
       analyze_directories: "lib test packages/*/lib packages/*/test"
       # Keep the 90% gate for real logic, but exclude platform / entrypoint glue
       # that can't be meaningfully unit-tested: the custom window chrome
       # (window_manager), the desktop_multi_window output-waveform sub-window,
       # and the app bootstrap/entrypoint. Coverage on the remainder stays ~91%.
       min_coverage: 90
       coverage_excludes: "**/window_chrome.dart **/waveform_window*.dart **/run_loopy.dart **/bootstrap.dart **/session_directory.dart"
   ```

   A short comment above the two new inputs should explain why they exist
   (extends format/analyze to packages/*, since the reusable workflow's
   defaults only cover the root app) so a future reader doesn't mistake it
   for redundant boilerplate.

2. **`packages/looper_repository/test/looper_repository_test.dart`** — run
   `dart format` to fix the one existing violation (pure whitespace/line-wrap
   change around the `'a reconnect re-applies the remembered rig (lanes +
   monitors)'` test's `test(...)` call — trailing-comma multi-line style).
   No semantic change; purely mechanical so the new gate is green at merge.

No other files change. No new CI job. No change to `test_recursion`,
`min_coverage`, `coverage_excludes`, or `license_check.yaml`.

## References

- Issue evidence: `.github/workflows/main.yaml` build job passes only
  `flutter_version`/`run_bloc_lint`/`min_coverage`/`coverage_excludes` to
  `flutter_package.yml@v1`; that reusable workflow's own defaults are
  `format_directories="lib test"`, `analyze_directories="lib test"`,
  `working_directory="."`.
- Upstream reusable workflow source (fetched during brainstorming):
  `https://raw.githubusercontent.com/VeryGoodOpenSource/very_good_workflows/main/.github/workflows/flutter_package.yml`
- Brainstorm doc: `docs/brainstorm/2026-07-13-ci-package-format-analyze-coverage-brainstorm-doc.md`
