# Brainstorm: Pin Flutter version in the `fuzz` CI job

## Context

This is an autonomous, narrowly-scoped fix for a single issue found by a multi-agent
code review pass on `.github/workflows/main.yaml` (verified against commit `f3f5b76`).
There is no live user to dialogue with for this run, so this document records the
problem, the (single, obvious) fix approach, and the assumptions made instead of
blocking on questions.

## Problem

`.github/workflows/main.yaml` has five jobs that invoke `subosito/flutter-action@v2`:
`build`, `build-windows`, `build-linux`, `build-macos`, and `fuzz`. Four of them
(`build`, `build-windows`, `build-linux`, `build-macos`) pin both:

```yaml
flutter-version: "3.44.x"
channel: stable
```

with comments explaining the pin exists "so the matrix can't silently drift" to a
newer stable release.

The `fuzz` job (currently at lines 123-139 of `main.yaml`) sets only:

```yaml
channel: stable
```

with no `flutter-version`. Since `pubspec.yaml` constrains `flutter: ^3.41.0` (any
newer stable accepted), the fuzz job will silently start running on whatever the
latest stable Flutter release is whenever one ships past 3.44 — while every other
job in the same workflow stays pinned to 3.44.x. This defeats the anti-drift intent
of the other jobs' pins: the fuzzer (a native-engine + bloc/cubit invariant fuzz
test) could start failing (or start passing when it shouldn't) purely because of an
SDK mismatch versus the rest of the CI matrix, not because of an actual regression.

## Approach considered

Only one reasonable approach exists for a fix this narrow:

**Add `flutter-version: "3.44.x"` to the `fuzz` job's `flutter-action@v2` step** —
Recommended, and the only approach considered.

- Change: add one line (`flutter-version: "3.44.x"`) alongside the existing
  `channel: stable` line in the `fuzz` job's `subosito/flutter-action@v2` step.
- Pros: matches the exact pin used by the other four jobs; zero behavior change
  today (3.44.x is already what CI resolves to); restores the anti-drift guarantee
  for the fuzz job; minimal, obviously-correct diff.
- Cons: none identified — this is a one-line consistency fix, not a design decision.
- Alternatives rejected:
  - Leaving `fuzz` floating on `stable` deliberately (e.g. as an early-warning
    canary for upcoming Flutter releases) — rejected because there is no code
    comment, doc, or commit message anywhere in the repo indicating this was an
    intentional choice; every signal (adjacent jobs' comments, the issue write-up)
    points to it being an oversight, not a design decision. If the maintainer
    wants a floating "canary" job in the future, that would be a deliberate new
    job, not a silent gap in this one.
  - Un-pinning the other four jobs to match `fuzz` — rejected because those jobs
    explicitly document the pin as intentional ("so the matrix can't silently
    drift"); loosening them would spread the drift risk instead of removing it.

## Assumptions (documented per autonomous-run instructions)

1. `"3.44.x"` is still the correct/current pin value as of this commit — verified
   via `grep -n "flutter-version" .github/workflows/main.yaml`, which shows all
   four other occurrences using `"3.44.x"` as of commit `f3f5b76`. No newer pin
   bump is in flight in this worktree.
2. The fix should match the existing jobs' pin exactly (same string value, same
   key ordering convention: `flutter-version` then `channel`) rather than
   introducing a new pinning scheme, per the "boring pattern / consistency"
   principle.
3. No CI behavior change is expected from this fix beyond removing the drift
   risk — 3.44.x is presumably still within `stable` today, so the fuzz job's
   resolved Flutter version should not change immediately.
4. Scope is strictly this one job/step. Other findings from the same review pass
   are being handled by other agents in parallel worktrees and are out of scope
   here.

## Decision

Add `flutter-version: "3.44.x"` to the `fuzz` job's flutter-action step in
`.github/workflows/main.yaml`, matching the other four Flutter-invoking jobs.
