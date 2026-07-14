---
date: 2026-07-13
topic: ci-package-format-analyze-coverage
---

# CI format + analyze coverage for packages/*

## What We're Building

`.github/workflows/main.yaml`'s `build` job calls VeryGoodOpenSource's reusable
`flutter_package.yml@v1` without overriding `format_directories` or
`analyze_directories`. Those inputs default to `"lib test"` (relative to
`working_directory: "."`), so `dart format --set-exit-if-changed lib test` and
`flutter analyze lib test` only ever look at the root app. None of the 13
packages under `packages/` (daw_export, performance_repository, wav_codec,
loopy_engine, controller_repository, local_storage_client, looper_repository,
midi_client, midi_device_repository, pedal_repository, routing_graph,
session_repository, settings_repository) get a format or analyze gate in CI.
Analyzer lints and `dart format` drift in package code can merge silently —
this already happened: `packages/looper_repository/test/looper_repository_test.dart`
is currently unformatted (see verification below) and nothing caught it.

The fix is to extend `format_directories` and `analyze_directories` on the
existing `build` job to also cover every package's `lib` and `test`
directories, and to fix the one pre-existing format violation that would
otherwise make the new gate fail on the very PR that adds it.

This is scoped to format + analyze only. It does not add a package unit-test
job (`test_recursion` staying `false` is a separate, already-known,
intentional gap per the issue), and it does not touch `license_check.yaml`
(a separate agent owns that file's path-filter fix).

## Why This Approach

### Verified how the reusable workflow actually consumes these inputs

Fetched `VeryGoodOpenSource/very_good_workflows`'s `flutter_package.yml` from
GitHub directly (`main` branch, matches the `@v1` tag's shape) to see exactly
how the inputs are used, rather than assuming:

```yaml
- name: ✨ Check Formatting
  run: dart format ... --set-exit-if-changed ${{inputs.format_directories}}

- name: 🕵️ Analyze
  run: flutter analyze ${{inputs.analyze_directories}}
```

Both inputs are plain strings spliced verbatim into a `run:` shell step on
`runs_on: ubuntu-latest` (our job doesn't override `runs_on`), which executes
via `bash`. That means:

- The string is **not** parsed by the reusable workflow at all — it's just
  interpolated into a bash command line. Whatever shell-glob expansion or
  word-splitting bash would normally do to that command line happens as usual.
- A space-separated list of paths, **including a shell glob such as
  `packages/*/lib`**, works exactly as it would if you typed the same
  `dart format`/`flutter analyze` invocation locally — bash expands the glob
  to the matching package directories before the binary ever sees the
  arguments.
- No special multi-dir syntax is needed beyond what `dart format` and
  `flutter analyze` already accept as positional arguments (both accept N
  directories/files and analyze/format each in the context of its own nearest
  `pubspec.yaml`/`analysis_options.yaml`).

### Verified empirically in this worktree (not just read the source)

Ran the real commands from repo root, exactly as the reusable workflow would:

1. `dart format --set-exit-if-changed lib test packages/*/lib packages/*/test`
   → found and fixed one real, previously-uncaught format violation in
   `packages/looper_repository/test/looper_repository_test.dart` (trailing-comma
   / line-wrapping drift, likely from local dart_style-version formatting
   before a later dart_style bump reformatted the same construct
   differently — matches the repo's documented recurring "ffigen format
   drift" class of gotcha but in hand-written package test code this time).
2. `flutter analyze packages/*/lib packages/*/test` and
   `flutter analyze lib test packages/*/lib packages/*/test` (after `flutter
   pub get` generated `AppLocalizations`, needed locally but already handled
   in CI by the reusable workflow's `very_good packages get --recursive`
   step) → **no analyzer issues** across any of the 13 packages. Confirms the
   packages are already lint-clean; turning the gate on doesn't create a
   backlog of lint fixes to make.
3. Deliberately introduced a lint + format violation
   (`packages/wav_codec/lib/wav_codec.dart`: badly-indented function with an
   unused local variable) and re-ran both commands with the multi-dir
   argument list — both **correctly caught it**:
   - `dart format --set-exit-if-changed ...` → non-zero exit, reformatted the
     file.
   - `flutter analyze packages/wav_codec/lib packages/wav_codec/test` →
     `unused_local_variable` warning + `very_good_analysis` info-level lints
     (`public_member_api_docs`, `prefer_final_locals`,
     `omit_local_variable_types`), using `wav_codec`'s own
     `analysis_options.yaml` (`package:very_good_analysis`), not the root
     app's — confirming per-package lint config is respected when analyzed
     via a shared invocation from the root working directory.
   - Reverted the deliberate violation afterward; confirmed `git status` is
     clean of it.

This directly satisfies the issue's ask to "verify this actually works
rather than assuming."

### Approaches considered

**A. Extend `format_directories`/`analyze_directories` with a glob on the
existing `build` job** — Recommended.

Add `packages/*/lib packages/*/test` to both inputs on the single existing
`build` job call in `main.yaml`. One-line-per-input change, no new job, no
new workflow file, and (per the verification above) confirmed to work with
this reusable workflow's actual implementation.

- Pros: minimal diff; single source of truth for format/analyze config;
  packages get exactly the same gate as the root app; new packages added
  under `packages/*` are automatically covered by the glob with zero further
  CI edits.
- Cons: one shell step now analyzes/formats 14 "roots" worth of directories
  in sequence — the two `run:` steps stay linear (not parallelized across
  packages), so a large future increase in package count could lengthen this
  step somewhat. Not a concern at 13 packages (~6s analyze locally).
- Best when: the reusable workflow accepts arbitrary space/glob-separated
  directory lists, which it does.

**B. Separate CI job that loops over `packages/*/` running its own
`dart format`/`flutter analyze` per package**

A new job (not using the reusable workflow, or calling it once per package
via a matrix) that iterates packages independently.

- Pros: per-package isolation (one package's failure is separately
  attributable in the Actions UI); could run in parallel via a matrix.
- Cons: meaningfully more YAML (a matrix job or a bash loop with its own
  `flutter`/`dart pub get` setup duplicated outside the reusable workflow);
  loses the reusable workflow's built-in `very_good packages get --recursive`
  step reuse; higher CI minutes from N separate Flutter-toolchain setups
  instead of one; overkill relative to the actual gap, which is just "these
  directories aren't in the existing command's argument list."
- Best when: packages need genuinely independent gating (e.g. different
  Flutter/Dart SDK versions per package, or wanting failure attribution
  per-package in the Actions summary) — not the case here; all packages
  share the monorepo's SDK constraints and are meant to move together.

**C. Explicit space-separated list of all 13 package paths (no glob)**

Same mechanism as A, but spell out `packages/daw_export/lib
packages/daw_export/test packages/wav_codec/lib ...` etc. instead of a glob.

- Pros: no reliance on shell glob semantics; greppable exact list.
- Cons: must be manually updated every time a package is added or removed
  (already happened 13 times and counting — this repo adds packages
  frequently per its multi-package architecture); glob was empirically
  verified to work, so the "avoid globs" caution doesn't apply here; more
  line noise in the workflow file for no behavioral benefit.
- Best when: the runner/shell doesn't support globbing reliably, or the set
  of packages is fixed and rarely changes — neither is true here.

Approach A is the one being carried forward: it is the least-invasive change
that satisfies the issue's ask, it was empirically verified against both the
reusable workflow's actual implementation and this repo's actual package
tree, and the glob keeps the workflow file maintenance-free as packages are
added or removed.

## Key Decisions

- **Use a glob (`packages/*/lib`, `packages/*/test`), not an explicit
  per-package list**: verified via `gh api`/`curl` against
  `VeryGoodOpenSource/very_good_workflows`'s actual `flutter_package.yml`
  source that `format_directories`/`analyze_directories` are spliced
  unmodified into a plain bash `run:` step on `ubuntu-latest`, so normal bash
  glob expansion applies — no special multi-dir support is required from the
  reusable workflow itself. This was confirmed to work locally, not assumed.
- **Fix the one pre-existing format violation
  (`packages/looper_repository/test/looper_repository_test.dart`) in the same
  PR**: turning on the new gate without this fix would make the adding PR's
  own CI run red on an unrelated pre-existing drift, which isn't acceptable
  to ship. The fix is purely a `dart format` re-run (no semantic change) and
  is the minimum necessary to make the new gate self-consistent at merge
  time. This is judged in-scope because it's mechanically required by this
  fix, not an unrelated finding from the review pass.
- **All 13 packages currently pass `flutter analyze` cleanly**: verified
  directly, so no analyzer-driven code changes are needed elsewhere in the
  monorepo to land this CI change.
- **Do not add a package test job / do not flip `test_recursion`**: explicitly
  out of scope per the issue text (a separate known-intentional gap) and per
  this task's instruction to stay narrowly scoped.
- **Do not touch `license_check.yaml`**: a separate agent owns that file's
  path-filter fix in a parallel worktree; no overlap with this change.
- **Leave `bloc lint .` (the reusable workflow's separate, hardcoded
  `run_bloc_lint` step) alone**: it already runs `bloc lint .` against the
  whole repo regardless of `format_directories`/`analyze_directories`, so it
  already covers packages today — nothing to change there, and out of scope
  for this issue (which is specifically about the `dart format`/`flutter
  analyze` steps).

## Open Questions

None blocking — the one open question from the issue description (does the
reusable workflow support glob/multi-dir input?) was resolved empirically
during brainstorming: yes, via ordinary bash glob expansion, confirmed
against both the upstream workflow source and this repo's actual package
tree/analysis configs.
