---
title: Pin Flutter version in the fuzz CI job
type: fix
date: 2026-07-13
---

## Pin Flutter version in the fuzz CI job - Minimal

`.github/workflows/main.yaml`'s `fuzz` job (lines 123-139) invokes
`subosito/flutter-action@v2` with only `channel: stable` — no `flutter-version`.
Every other Flutter-invoking job (`build`, `build-windows`, `build-linux`,
`build-macos`) pins `flutter-version: "3.44.x"` alongside `channel: stable`,
specifically "so the matrix can't silently drift". Because `pubspec.yaml`
constrains `flutter: ^3.41.0` (any newer stable accepted), the fuzz job will
silently move to a newer stable Flutter release out of step with the rest of
CI the moment one ships past 3.44 — defeating the other jobs' anti-drift pin.

Fix: add `flutter-version: "3.44.x"` to the fuzz job's flutter-action step,
matching the other four jobs exactly.

## Success Criteria

```success-criteria
GOAL: All Flutter-invoking jobs in .github/workflows/main.yaml pin the same
Flutter version, so the fuzz job can no longer silently drift onto a newer
stable SDK than the rest of the CI matrix.

SUCCESS CRITERIA:
- The fuzz job's subosito/flutter-action@v2 step sets flutter-version: "3.44.x" alongside channel: stable | verify: grep -A2 "fuzz:" -A20 .github/workflows/main.yaml | grep -q 'flutter-version: "3.44.x"'
- Every flutter-action@v2 step in the file now has an adjacent flutter-version line (count of flutter-version occurrences == count of flutter-action@v2 occurrences) | verify: test "$(grep -c 'flutter-action@v2' .github/workflows/main.yaml)" -eq "$(grep -c 'flutter-version:' .github/workflows/main.yaml)"
- main.yaml remains valid YAML | verify: python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/main.yaml'))"
- No other lines in the workflow file changed besides the one insertion | verify: manual run `git diff --stat .github/workflows/main.yaml` and confirm only main.yaml changed with a 1-line insertion (+1/-0)

NON-GOALS:
- Changing the pinned version value itself (stays "3.44.x", matching the other jobs as of this commit)
- Touching any other job, step, or file
- Re-litigating whether floating fuzz on latest stable was intentional (brainstorm doc concluded it was an oversight)

VERIFICATION COMMAND: grep -A20 "fuzz:" .github/workflows/main.yaml | grep -q 'flutter-version: "3.44.x"' && test "$(grep -c 'flutter-action@v2' .github/workflows/main.yaml)" -eq "$(grep -c 'flutter-version:' .github/workflows/main.yaml)" && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/main.yaml'))"
```

## Context

- File: `.github/workflows/main.yaml`
- Current fuzz job flutter-action step (as of commit `f3f5b76`, lines 131-133):
  ```yaml
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
  ```
- The other four jobs' matching step, e.g. `build-macos` (lines 152-156):
  ```yaml
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: "3.44.x"
          channel: stable
          cache: true
  ```
- Brainstorm doc: `docs/brainstorm/2026-07-13-pin-fuzz-ci-flutter-version-brainstorm-doc.md`
- No test coverage is applicable — this is a CI YAML config change, verified by
  grep/YAML-parse checks above plus a subsequent real CI run on the PR.

## MVP

Single edit to `.github/workflows/main.yaml`:

```yaml
  fuzz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Install C build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: "3.44.x"
          channel: stable
      - name: Build the engine test library
        ...
```

(only the `flutter-version: "3.44.x"` line is new, inserted immediately before
the existing `channel: stable` line, matching key ordering used elsewhere in
the file)

## References

- Issue found via multi-agent code review pass against commit `f3f5b76`
  (origin/master HEAD)
- Related file: `.github/workflows/main.yaml`
