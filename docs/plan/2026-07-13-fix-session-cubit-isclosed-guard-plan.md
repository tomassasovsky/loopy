---
title: SessionCubit emits after await with no isClosed guard
type: fix
date: 2026-07-13
---

## SessionCubit emits after await with no isClosed guard - Minimal

`SessionCubit` (`lib/session/cubit/session_cubit.dart`) is the only cubit in
the app whose post-`await` `emit` calls aren't guarded by `isClosed`. Its
shared `_run` envelope — backing `exportMixdown`, `exportStems`, `saveAs`,
`save`, `loadNamed`, `renameSession`, `deleteSession`, `duplicateSession` —
awaits an arbitrary async action, then unconditionally emits on the success
path and in both catch branches. `refreshSessions()` has the identical
unguarded single emit with no surrounding try/catch at all. If the cubit is
closed while one of these awaits is in flight, `emit` throws
`StateError('Cannot emit new states after calling close')`; since
`StateError` isn't a `SessionException`, it's caught by the
`on Object catch` branch, which emits again unguarded — and that second
emit's exception propagates out of the returned `Future` unhandled. Every
other cubit in the app (`PedalCubit`, `ControlCubit`,
`PerformanceRecorderCubit`, `TracksCubit`, `RefreshRateCubit`,
`QuantizeCubit`, `AudioRecoveryCubit`, `RecordOptionsCubit`,
`HighContrastCubit`, `AudioSetupCubit`, `MonitorCubit`) already guards every
post-await emit with `if (isClosed) return;` immediately before the emit.

This plan adds that same guard to the four post-await emit sites in
`session_cubit.dart` and adds a regression test that closes the cubit
mid-action and asserts no unhandled exception propagates.

## Success Criteria

```success-criteria
GOAL: SessionCubit never throws when it is closed while an async action (export, save, load, rename, delete, duplicate, or refreshSessions) is in flight — matching the isClosed-guard idiom used by every other cubit in the app.

SUCCESS CRITERIA:
- `_run`'s post-await success emit is guarded with `if (isClosed) return;` | verify: grep -A1 -n "final result = await action" lib/session/cubit/session_cubit.dart | grep -q "isClosed"
- `_run`'s `on SessionException` catch-branch emit is guarded with `if (isClosed) return;` | verify: manual 1. Open lib/session/cubit/session_cubit.dart 2. Confirm the `on SessionException catch (error)` block has `if (isClosed) return;` before its `emit(...)` call
- `_run`'s `on Object` catch-branch emit is guarded with `if (isClosed) return;` | verify: manual 1. Open lib/session/cubit/session_cubit.dart 2. Confirm the `on Object catch (error)` block has `if (isClosed) return;` before its `emit(...)` call
- `refreshSessions()`'s emit is guarded with `if (isClosed) return;` | verify: grep -A3 -n "Future<void> refreshSessions" lib/session/cubit/session_cubit.dart | grep -q "isClosed"
- A new test closes the cubit mid-action (while the mocked repository call is still pending) and asserts the action's Future completes without an unhandled StateError/exception | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- No regressions in the existing session cubit test suite | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- Static analysis is clean on the touched file | verify: /Users/Tomas/development/flutter/bin/flutter analyze lib/session/cubit/session_cubit.dart test/session/cubit/session_cubit_test.dart

NON-GOALS:
- Refactoring `_run`'s envelope structure or introducing a `_safeEmit`/wrapper abstraction (rejected in the brainstorm — every other cubit repeats the inline guard, so this stays consistent with that idiom).
- Touching any other cubit or file outside `lib/session/cubit/session_cubit.dart` and its test.
- Fixing any other finding from the same review pass (other agents own those in separate worktrees).

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter analyze lib/session/cubit/session_cubit.dart test/session/cubit/session_cubit_test.dart && /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
```

## Context

- **File**: `lib/session/cubit/session_cubit.dart`
- **`_run`** (~line 177): shared envelope for `exportMixdown`, `exportStems`,
  `saveAs`, `save`, `loadNamed`, `renameSession`, `deleteSession`,
  `duplicateSession`. Structure:
  ```dart
  Future<void> _run(Future<_ActionResult> Function() action) async {
    emit(state.copyWith(status: SessionStatus.working)); // before await — no guard needed
    try {
      final result = await action();
      emit(state.copyWith(status: SessionStatus.success, ...)); // NEEDS GUARD
    } on SessionException catch (error) {
      emit(state.copyWith(status: SessionStatus.failure, ...)); // NEEDS GUARD
    } on Object catch (error) {
      emit(state.copyWith(status: SessionStatus.failure, ...)); // NEEDS GUARD
    }
  }
  ```
- **`refreshSessions()`** (~line 64):
  ```dart
  Future<void> refreshSessions() async =>
      emit(state.copyWith(sessions: await _repository.listSessions())); // NEEDS GUARD
  ```
  Since this is a single expression-bodied function, it needs to become a
  block body to insert the guard:
  ```dart
  Future<void> refreshSessions() async {
    final sessions = await _repository.listSessions();
    if (isClosed) return;
    emit(state.copyWith(sessions: sessions));
  }
  ```
- **Established idiom** (verified via `grep -rn "isClosed" lib/`): the
  dominant pattern across the app's other ~11 cubits is a standalone guard
  statement immediately before the emit:
  ```dart
  if (isClosed) return;
  emit(...);
  ```
  Examples: `lib/pedal/cubit/pedal_cubit.dart:72`,
  `lib/control/cubit/control_cubit.dart:152`,
  `lib/audio_setup/cubit/audio_setup_cubit.dart:355`,
  `lib/performance/cubit/performance_recorder_cubit.dart:366`,
  `lib/audio_setup/cubit/monitor_cubit.dart:68`. This plan uses that exact
  style (not the less-common `if (!isClosed) emit(...)` inline variant) for
  consistency and because `_run`'s emits are multi-line
  `state.copyWith(...)` calls that read more clearly with a standalone guard
  above them.
- **Existing test file**: `test/session/cubit/session_cubit_test.dart` already
  uses `bloc_test`/`mocktail` with `_MockSessionRepository`,
  `_MockLooperRepository`, `_MockPerformanceRepository`, and a `build()`
  helper that wires them into a `SessionCubit`. The new regression test
  should reuse this `build()` helper and mocking convention rather than
  inventing a new setup.
- **Loopy test-runner gotcha** (from project memory): the `very_good` MCP
  test runner is broken for this repo; use the absolute Flutter binary path
  (`/Users/Tomas/development/flutter/bin/flutter test ...`) instead.

## MVP

1. In `lib/session/cubit/session_cubit.dart`:
   - Convert `refreshSessions()` to a block body; await into a local, guard,
     then emit.
   - In `_run`, add `if (isClosed) return;` immediately before each of the
     three post-await emits (success branch, `on SessionException` branch,
     `on Object` branch).
2. In `test/session/cubit/session_cubit_test.dart`, add a test (e.g. under a
   new `group('isClosed guard')`) that:
   - Stubs a repository method (e.g. `repository.exportMixdown` or
     `repository.listSessions`) to return a `Future` that doesn't complete
     until the test manually completes it (a `Completer<void>`/`Completer<List<SessionSummary>>`).
   - Calls the cubit action (e.g. `cubit.exportMixdown()` or
     `cubit.refreshSessions()`), capturing the returned `Future` without
     awaiting it yet.
   - Calls `await cubit.close()`.
   - Completes the `Completer` so the pending `await action()` resolves after
     close.
   - Asserts the captured action `Future` completes normally (`await
     expectLater(future, completes)` or a plain `await future;` with no
     exception) — i.e. no unhandled `StateError` propagates and the test
     doesn't fail/crash.
   - Covers both `_run`-backed actions (e.g. `exportMixdown`) and
     `refreshSessions()` if convenient, since both had the gap independently.

## References

- Issue source: multi-agent code review finding, re-verified against commit
  `f3f5b76` (origin/master HEAD).
- Brainstorm: `docs/brainstorm/2026-07-13-session-cubit-isclosed-guard-brainstorm-doc.md`
- Pattern reference: `lib/pedal/cubit/pedal_cubit.dart`,
  `lib/control/cubit/control_cubit.dart`
- `package:bloc`'s `BlocBase.emit` throws
  `StateError('Cannot emit new states after calling close')` once closed —
  the mechanism this guard prevents from ever firing.
