---
title: "fix: performance-recording arm permanently refused after a completed capture"
type: fix
date: 2026-07-13
---

## fix: performance-recording arm permanently refused after a completed capture — Minimal

## Problem (root cause, verified against the code)

`PerformanceRecorderCubit.toggleArm()`
(`lib/performance/cubit/performance_recorder_cubit.dart:169-181`) only calls
`_performance.arm()` from the `PerformanceRecorderIdle(recoveryDirectory:
null)` case. Every other case — including `PerformanceRecorderCompleted()` —
falls into the switch's trailing `break`, a silent no-op:

```dart
Future<void> toggleArm() async {
  switch (state) {
    case PerformanceRecorderIdle(recoveryDirectory: null):
      await _performance.arm();
    case PerformanceRecorderArmed():
      await _performance.disarm();
    case PerformanceRecorderIdle():
    case PerformanceRecorderFinalizing():
    case PerformanceRecorderRendering():
    case PerformanceRecorderCompleted():
      break;
  }
}
```

Nothing in the cubit ever emits `PerformanceRecorderIdle()` after a capture
settles — the only two emission sites are the constructor's initial state and
`discardBootCapture()`. So after one full capture lifecycle (`idle -> armed ->
finalizing -> rendering -> completed`), `toggleArm()` is a permanent no-op
until the app restarts. Both call sites are affected identically:

- The toolbar button, `PerfRecordButton`
  (`lib/performance/view/perf_record_button.dart:29`): `enabled = !busy &&
  !recoveryPending` is `true` for `PerformanceRecorderCompleted`, so the button
  renders as pressable and silently does nothing.
- The `A` keyboard shortcut (`lib/looper/view/tracks_commands.dart:212-215`):
  calls the same `toggleArm()`.

The physical pedal's MODE long-press is unaffected —
`ControlCubit.togglePerformanceRecord()`
(`lib/control/cubit/control_cubit.dart:620-626`) calls
`_performance.arm()`/`disarm()` directly against its own `_performanceArmed`
bool (driven straight off the repository's status stream), bypassing this
cubit's state gate entirely. Out of scope; not touched by this fix.

## Why arming from `Completed` is safe (verified at the repository layer)

Read `packages/performance_repository/lib/src/performance_repository.dart` in
full. `arm()`'s only precondition is:

```dart
Future<EngineResult> arm({...}) async {
  if (_armedDir != null) return EngineResult.ok;
  ...
}
```

`_finalizeArmed` (the tail of both `disarm()` and `disarmAndFinalize()`) always
resets `_armedDir = null` and sets `_status = PerformanceCaptureStatus.done`
before returning — so by the time a cubit reaches `PerformanceRecorderCompleted`,
the repository is already in a state where `arm()` will succeed immediately.
The repository has no notion of a `done -> idle` reset being required first.

`arm()` succeeding sets `_status = PerformanceCaptureStatus.armed` and pushes
that onto `captureStatus`, which `PerformanceRecorderCubit._onStatus` already
handles unconditionally:

```dart
case PerformanceCaptureStatus.armed:
  ...
  _emit(PerformanceRecorderArmed(...));
```

That emission is not gated on the cubit's *prior* state, so calling
`_performance.arm()` from `PerformanceRecorderCompleted` drives the cubit
straight to `PerformanceRecorderArmed` through the exact same reactive path
`Idle -> Armed` already uses today. No new state, no new emission site, and no
explicit `Completed -> Idle` waypoint is needed.

## Decision — extend `toggleArm()`'s existing arm-case to include `Completed`

Stack `PerformanceRecorderCompleted()` onto the same case body as
`PerformanceRecorderIdle(recoveryDirectory: null)`, mirroring this file's own
existing style of stacking case labels before a shared body (see the trailing
no-op cases today):

```dart
Future<void> toggleArm() async {
  switch (state) {
    case PerformanceRecorderIdle(recoveryDirectory: null):
    case PerformanceRecorderCompleted():
      await _performance.arm();
    case PerformanceRecorderArmed():
      await _performance.disarm();
    case PerformanceRecorderIdle():
    case PerformanceRecorderFinalizing():
    case PerformanceRecorderRendering():
      break;
  }
}
```

`PerformanceRecorderCompleted()` as a bare-class pattern matches every
instance of the class, including ones built via the `.discardedShort()` named
constructor — so this one case transparently fixes both the "delivered
result, shown in the completion sheet" path and the "short/empty capture,
shown via a SnackBar" path (`onPerformanceRecorderState` in
`tracks_commands.dart`) without needing to discriminate on
`discarded`/`result`.

Also update the doc comment above `toggleArm()` (currently: "a no-op while
finalizing/rendering/completed (no queue)") to drop `completed` from that
list, since it is no longer refused there.

## Alternatives (rejected)

- **Explicit `acknowledgeCompletion()` transitioning `Completed -> Idle`,
  called when the completion sheet's route closes.** This was the "suggested
  fix direction" in the original finding, but it is strictly more surface area
  for no behavioral difference: a new cubit method, a call site in
  `showPerformanceCompletionSheet` after `showModalBottomSheet` resolves, *and*
  a second call site for the short-capture auto-discard path (which never
  opens the modal sheet at all, so it has no "route closed" event to hang the
  reset off of — it would need its own bespoke wiring). Rejected in favor of
  the one-switch-case fix, which covers both paths identically for free.
- **Reset to `Idle` immediately upon reaching `Completed`.** Would break
  `renameCompletedCapture()` and `reExport()`, both of which require `current
  is PerformanceRecorderCompleted` and read `current.result` — the completion
  sheet calls both while state is (and must stay) `Completed`.

## Must-verify while building

1. **No interaction with `renameCompletedCapture()` / `reExport()`.** Those
   fire from explicit sheet-button presses while the completion sheet's modal
   route is open. `showModalBottomSheet` pushes a route that owns primary
   focus, so `TracksCommands.handleKey`'s `A` shortcut (wired below that route,
   over `TracksView`) cannot fire while the sheet is showing, and the toolbar
   button sits behind the modal barrier, which absorbs taps — so `toggleArm()`
   is not reachable while the sheet is up in normal operation. `arm()` also
   always creates a brand-new capture directory (`performanceSlug(_now())`),
   never touching the just-completed bundle's directory those two methods
   read/write, so there is no shared-resource race even in a contrived case.
2. **`recoveryDirectory` is untouched.** It only ever appears on
   `PerformanceRecorderIdle`, populated once at boot by `load()`. A normal
   `Completed` transition never carries or implies a pending boot-recovery
   prompt; this fix does not touch that field or path.
3. **No other case in the switch changes behavior.** `Armed -> disarm`,
   `Idle(recoveryDirectory: non-null) -> no-op`, `Finalizing -> no-op`, and
   `Rendering -> no-op` must remain exactly as they are today — only the
   `Completed` no-op becomes an arm.

## Test plan

All new/changed tests live in the two files the finding calls out as the
testing-convention reference; no other test files change.

- **`test/performance/cubit/performance_recorder_cubit_test.dart`** (add to
  the existing `group('toggleArm', ...)`):
  - New test: reuse the file's existing `completedCubit()` helper (drives a
    cubit through `armWithLog` → `toggleArm()` → `waitForCompleted()` to a
    settled `PerformanceRecorderCompleted` with a `PerformanceRecordDone`
    result — already used by the `renameCompletedCapture`/`reExport` groups).
    Call `toggleArm()` again and assert the cubit reaches
    `PerformanceRecorderArmed` (`await pumpEventQueue()` then `expect(cubit.state,
    isA<PerformanceRecorderArmed>())`), plus `expect(engine.perfArmCalls, 2)`
    (1 from the original arm, 1 from the re-arm) to prove the repository's
    `arm()` was actually invoked a second time, not just that some state
    changed. This is the exact regression the original finding calls out as
    untested, and fails on pre-fix code (today `toggleArm()` from `Completed`
    is a no-op, so `engine.perfArmCalls` would stay at 1 and the state would
    stay `Completed`).
  - New test: drive a cubit to a `PerformanceRecorderCompleted.discardedShort()`
    state (mirror the existing `group('short-capture auto-discard', ...)`
    fixture: `toggleArm()` to arm, advance the clock under 2s, `toggleArm()` to
    disarm with no `events.log`, `waitForCompleted()`), then call `toggleArm()`
    again and assert it reaches `PerformanceRecorderArmed` — proving the fix
    covers the `discardedShort` variant of `PerformanceRecorderCompleted`, not
    just the delivered-result variant.
- **`test/performance/view/perf_record_button_test.dart`** (add alongside the
  existing per-state `testWidgets`):
  - New test: pump the button with a `PerformanceRecorderCompleted(
    PerformanceRecordDone('/exports/perf-x'))` state (mirrors this file's
    existing `_MockPerformanceRecorderCubit` + `pump()` helper pattern), assert
    `button.onPressed` is not null (enabled), then `tester.tap(...)` it and
    `verify(cubit.toggleArm).called(1)` — confirming the button is not just
    enabled-looking but actually wired to dispatch `toggleArm()` in this
    state, which is what the original bug report calls out specifically
    ("looks pressable... but does nothing").

No changes to `performance_completion_sheet.dart`, `perf_record_button.dart`'s
enabled logic, `tracks_commands.dart`, or the `performance_repository`
package — the fix is entirely inside `toggleArm()` in
`performance_recorder_cubit.dart`, plus the two test files above.

## Files (primary)

- `lib/performance/cubit/performance_recorder_cubit.dart` — `toggleArm()`'s
  switch statement (~line 169-181) and its doc comment (~line 161-168).
- `test/performance/cubit/performance_recorder_cubit_test.dart` — two new
  tests in `group('toggleArm', ...)`.
- `test/performance/view/perf_record_button_test.dart` — one new `testWidgets`
  case.

## Verification steps

- `/Users/Tomas/development/flutter/bin/flutter test test/performance/cubit/performance_recorder_cubit_test.dart test/performance/view/perf_record_button_test.dart`
  (absolute `flutter` path — the very_good CLI MCP test runner is known-broken
  in this repo; use the plain `flutter test` binary directly instead).
- `/Users/Tomas/development/flutter/bin/flutter analyze lib/performance/cubit/performance_recorder_cubit.dart test/performance/cubit/performance_recorder_cubit_test.dart test/performance/view/perf_record_button_test.dart`
  clean on the touched files.
- `/Users/Tomas/development/flutter/bin/flutter format` (or `dart format`)
  stable on the touched files (no diff after formatting).

## Acceptance criteria

- `toggleArm()` called while `PerformanceRecorderCompleted` (both the
  delivered-result and `discardedShort` variants) successfully arms a new
  capture — the toolbar button and the `A` shortcut both work again without an
  app restart.
  - `verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/cubit/performance_recorder_cubit_test.dart --plain-name "toggleArm"`
- No regression to the existing `Idle`/`Armed`/`Finalizing`/`Rendering`/
  recovery-pending behavior of `toggleArm()`.
  - `verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/cubit/performance_recorder_cubit_test.dart`
- The toolbar button is provably wired (not just visually enabled) to
  dispatch `toggleArm()` while `PerformanceRecorderCompleted`.
  - `verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/view/perf_record_button_test.dart`
- Full existing suites for both touched test files stay green; `flutter
  analyze` clean on the touched files; `dart format` stable (no diff).
  - `verify: /Users/Tomas/development/flutter/bin/flutter analyze lib/performance/cubit/performance_recorder_cubit.dart test/performance/cubit/performance_recorder_cubit_test.dart test/performance/view/perf_record_button_test.dart`

## Open questions

None blocking. This is a narrowly-scoped, single-root-cause bug fix; the fix's
correctness was verified against both the cubit and the repository's actual
`arm()`/status-stream semantics (not assumed). No user interaction was
available for this planning run; the design decisions above (in particular,
rejecting the originally-suggested `acknowledgeCompletion()` approach in favor
of the smaller switch-case fix) were made autonomously and are documented in
the companion brainstorm doc,
`docs/brainstorm/2026-07-13-fix-performance-recorder-arm-after-completed-brainstorm-doc.md`.
