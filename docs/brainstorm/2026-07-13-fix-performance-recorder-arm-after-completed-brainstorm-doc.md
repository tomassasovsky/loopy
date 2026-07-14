---
date: 2026-07-13
topic: fix-performance-recorder-arm-after-completed
---

# Fix: performance-recording arm permanently refused after the first completed capture

## What We're Building

`PerformanceRecorderCubit.toggleArm()` (`lib/performance/cubit/performance_recorder_cubit.dart`,
~line 169) only arms from `PerformanceRecorderIdle(recoveryDirectory: null)`.
Every other state — including `PerformanceRecorderCompleted()` — falls through
the exhaustive switch's trailing `break`, a silent no-op. Nothing in the cubit
ever emits `PerformanceRecorderIdle()` after a capture settles (the only two
emission sites are the constructor's initial state and
`discardBootCapture()`), so once one full capture lifecycle finishes
(`idle -> armed -> finalizing -> rendering -> completed`), the toolbar record
button (`PerfRecordButton`, key `tracks_perfRecord`) and the `A` keyboard
shortcut (`TracksCommands.handleKey` in `lib/looper/view/tracks_commands.dart`)
are permanently dead until the app restarts — even though the button renders
`enabled: true` the whole time (its guard is only
`!busy && !recoveryPending`), so it looks pressable and silently isn't.

This is a single-file, single-method fix: extend `toggleArm()`'s switch so
`PerformanceRecorderCompleted()` arms exactly like
`PerformanceRecorderIdle(recoveryDirectory: null)` does today, plus a
regression test covering arm-after-completed.

## Why This Approach

Approaches considered:

- **Chosen: let `toggleArm()` arm directly from `Completed`, same case body as
  `Idle(recoveryDirectory: null)`.** Verified against
  `packages/performance_repository/lib/src/performance_repository.dart`:
  `arm()`'s only guard is `if (_armedDir != null) return EngineResult.ok;` —
  after a full capture settles, `_finalizeArmed` has already reset
  `_armedDir = null` and set `_status = PerformanceCaptureStatus.done`. The
  repository itself is never "stuck" at `done`; it has no notion of needing an
  explicit `idle` reset before the next `arm()`. Calling `arm()` again
  immediately succeeds, creates a fresh `perf-YYYYMMDD-HHMMSS/` directory, and
  emits `PerformanceCaptureStatus.armed` on the status stream — which
  `PerformanceRecorderCubit._onStatus` already reacts to by emitting
  `PerformanceRecorderArmed(...)` unconditionally, regardless of the state it
  is superseding. So the cubit's `Completed -> Armed` transition falls out of
  the *existing* reactive plumbing for free; no new state, no new emission
  site, no explicit `Completed -> Idle` waypoint needed at all.
- **Rejected: explicit `acknowledgeCompletion()` transitioning
  `Completed -> Idle`, called when the completion sheet's route closes.** This
  is the "suggested fix direction" in the original finding, but on inspection
  it is strictly more work for no behavioral benefit: it requires a new cubit
  method, a call site in `showPerformanceCompletionSheet`
  (`lib/performance/view/performance_completion_sheet.dart`) after
  `showModalBottomSheet` resolves (covers close-button/barrier-tap/swipe/back
  uniformly, since all of those resolve that one awaited `Future`), *and* a
  second call site for the short-capture auto-discard path
  (`PerformanceRecorderCompleted.discardedShort()`, surfaced via
  `_showPerformanceDiscarded`'s `SnackBar` in `tracks_commands.dart` — that
  path never opens the modal sheet at all, so it has no equivalent "route
  closed" event to hang the reset off of; discardedShort completions hit the
  exact same permanent-stuck bug and need the exact same fix). Two UI call
  sites plus a new cubit method is materially more surface area than one
  switch-case edit, for an outcome that is behaviorally identical to the
  chosen approach in every case that matters.
- **Rejected: reset to `Idle` immediately upon reaching `Completed`.** Would
  break `renameCompletedCapture()` and `reExport()`, both of which explicitly
  require `current is PerformanceRecorderCompleted` and read `current.result`
  — the completion sheet calls both while state is (and must stay) `Completed`.

## Key Decisions

- **`toggleArm()`'s switch grows one stacked case**: `case
  PerformanceRecorderIdle(recoveryDirectory: null): case
  PerformanceRecorderCompleted():` sharing the existing `await
  _performance.arm();` body — mirroring the file's own existing style of
  stacking case labels before a shared body (see the trailing no-op cases
  today).
- **`PerformanceRecorderCompleted()` as a bare-class pattern covers both
  outcomes uniformly.** The pattern matches every instance of the class,
  including ones built via the `.discardedShort()` named constructor, so this
  one case transparently fixes both the "delivered result, shown in the sheet"
  path and the "short/empty capture, shown via SnackBar" path without needing
  to discriminate on `discarded`/`result`.
- **No new guard needed against re-arming while the completion sheet is still
  open.** `showModalBottomSheet` pushes a new route that owns primary focus;
  `TracksCommands.handleKey` is wired below that route (over `TracksView`), so
  the `A` shortcut cannot fire while the sheet is showing, and the toolbar
  button sits behind the modal barrier, which absorbs taps. In the
  never-actually-reachable case that `arm()` did fire while the sheet was
  still up, the sheet's own `build()` already guards on `state is!
  PerformanceRecorderCompleted() => SizedBox.shrink()`, so the sheet would
  just go empty rather than crash — a pre-existing, harmless guard, not
  something this fix needs to add.
- **No interaction with `renameCompletedCapture()` / `reExport()`.** Those
  fire from explicit sheet-button presses while the sheet is open (i.e. while
  `toggleArm()` is unreachable per the point above); `arm()` also always
  writes to a brand-new capture directory, never touching the just-completed
  bundle's directory those two methods read/write — no shared-resource race
  either way.
- **`recoveryDirectory` is irrelevant here.** A normal `Completed` transition
  never carries or implies a pending boot-recovery prompt — that field only
  ever appears on `PerformanceRecorderIdle`, populated once at boot by
  `load()`. Nothing about this fix touches that path.
- **Testing**: add a `blocTest` (matching this file's existing conventions in
  `test/performance/cubit/performance_recorder_cubit_test.dart`) that drives a
  cubit through a full capture lifecycle to `PerformanceRecorderCompleted`,
  calls `toggleArm()` again, and asserts `_performance.arm()` is invoked /
  the cubit reaches `PerformanceRecorderArmed` — the exact gap the original
  finding called out as untested. Also extend
  `test/performance/view/perf_record_button_test.dart` with a case showing the
  button is both `enabled` and functionally wired (tap dispatches
  `toggleArm()`) when state is `PerformanceRecorderCompleted`, not just
  enabled-looking.

## Success Criteria

- `toggleArm()` called while `PerformanceRecorderCompleted` (delivered or
  discarded-short) successfully arms a new capture — both the toolbar button
  and the `A` shortcut work again without an app restart.
- No regression to the existing Idle/Armed/Finalizing/Rendering/recovery-
  pending behavior of `toggleArm()` — every other case in the switch is
  untouched.
- New test(s) fail on the pre-fix code and pass after the fix, isolating the
  exact regression this closes.

## Open Questions

None blocking — this is a narrowly-scoped, already-verified bug fix with a
single clear root cause and a minimal correct fix, confirmed against the
repository's actual `arm()`/status-stream semantics rather than assumed. No
user interaction was available for this run; the above reflects an autonomous
review of the fix's design space and a decision on the smallest-surface-area
correct option.

## Inputs

- Multi-agent code review finding (this session), independently re-verified
  against `f3f5b76` by reading `performance_recorder_cubit.dart`,
  `performance_recorder_state.dart`, `performance_completion_sheet.dart`,
  `perf_record_button.dart`, and `tracks_commands.dart` in full, plus the
  `PerformanceRepository` implementation (`arm()`/`disarm()`/status-stream
  semantics) to confirm the chosen fix is correct at the repository layer, not
  just at the cubit layer.
