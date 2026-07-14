---
date: 2026-07-13
topic: session-cubit-isclosed-guard
---

# SessionCubit isClosed guard

## What We're Building

`SessionCubit` (`lib/session/cubit/session_cubit.dart`) is the only cubit in the
app whose post-`await` `emit` calls aren't guarded by `isClosed`. Its shared
`_run` envelope (backing `exportMixdown`, `exportStems`, `saveAs`, `save`,
`loadNamed`, `renameSession`, `deleteSession`, `duplicateSession`) awaits an
arbitrary async action and then unconditionally emits on the success path and
in both catch branches. `refreshSessions()` has the same problem with its
single unguarded emit. If the cubit is closed while one of these awaits is in
flight (e.g. the widget tree tears it down mid mixdown-export, or mid
`loadNamed`, which first awaits `_performance.disarmAndFinalize()`), `emit`
throws `StateError('Cannot emit new states after calling close')`. Since
`StateError` isn't a `SessionException`, it lands in the `on Object catch`
branch, which emits again — unguarded — and that second emit's exception
propagates out of the returned `Future` unhandled.

We're adding `isClosed` guards at every post-await emit site in this file, to
match the pattern already established in every other cubit (`pedal_cubit.dart`,
`control_cubit.dart`, `refresh_rate_cubit.dart`, etc.): `if (isClosed) return;`
immediately before the emit, as its own statement.

## Why This Approach

Two approaches were considered:

**Guard each emit site individually (recommended).** Add `if (isClosed)
return;` right before each of the four post-await emit sites: the success emit
in `_run`, the two catch-branch emits in `_run`, and the single emit in
`refreshSessions()`. This is a minimal, mechanical, line-level fix that matches
the exact idiom already used everywhere else in the codebase (verified via
`grep -rn "isClosed" lib/`, which returns 10+ hits across pedal, control,
looper, performance, and audio_setup cubits, always as `if (isClosed) return;`
immediately preceding the guarded emit, or occasionally `if (!isClosed)
emit(...)` inline). No new abstractions, no behavior change beyond "don't
throw when torn down mid-flight."

- Pros: smallest possible diff; zero new concepts; trivially reviewable;
  matches 10+ existing call sites exactly, so it reads as "the same bug, fixed
  the same way" rather than inventing a new house style.
- Cons: four near-identical one-line insertions (mild repetition), and it does
  nothing to prevent a *new* unguarded emit from being added to `_run` later.
- Best when: the fix is narrowly scoped to a single already-diagnosed
  correctness gap (this is exactly that case — the issue is pre-verified, and
  the task explicitly asks to match the existing idiom rather than invent one).

**Wrap `emit` itself with a private safe-emit helper (`_safeEmit`).** Add a
private `void _safeEmit(SessionState Function() build) { if (isClosed) return;
emit(build()); }` and route every emit in the file through it, guarded or not.

- Pros: impossible to add a future unguarded emit by accident; consolidates
  the check in one place.
- Cons: introduces a new abstraction that doesn't exist anywhere else in the
  app's ~11 other cubits — every one of them repeats the guard inline at each
  call site rather than wrapping `emit`. Adding a bespoke pattern here would
  make `SessionCubit` the one cubit that does it differently, which cuts
  against the review finding's own framing ("unlike every other cubit").
  Larger diff for a scope that's supposed to stay minimal.
- Best when: a codebase is establishing the guard pattern for the first time,
  or already has an existing safe-emit convention to extend. Neither is true
  here.

**Decision: guard each emit site individually**, matching the `if (isClosed)
return;`-before-emit idiom verbatim.

## Key Decisions

- **Guard placement**: `if (isClosed) return;` as its own statement
  immediately before each post-await emit — not `if (!isClosed) emit(...)`
  wrapping — to match the more common variant of the existing idiom (seen in
  `pedal_cubit.dart:72`, `control_cubit.dart:152`, `audio_setup_cubit.dart:355`,
  `performance_recorder_cubit.dart:366`, `monitor_cubit.dart:68`). The
  `if (!isClosed) emit(...)` variant also appears (e.g.
  `refresh_rate_cubit.dart:34`, `quantize_cubit.dart:30`) but the guard-then-
  return style is the majority pattern and reads more clearly for `_run`'s
  multi-line `emit(state.copyWith(...))` calls.
- **Scope**: only the 4 post-await emit sites in `session_cubit.dart` get the
  guard — `_run`'s success emit, `_run`'s two catch-branch emits, and
  `refreshSessions()`'s emit. The very first `emit(state.copyWith(status:
  SessionStatus.working))` in `_run` runs before any `await`, so per the
  issue's own guidance it needs no guard (the cubit can't have been closed
  between synchronous statements).
- **No new abstraction**: explicitly rejecting a `_safeEmit` helper (see
  "Why This Approach" above) to keep `SessionCubit` consistent with every
  other cubit's inline-guard style, and to keep the diff minimal per the
  task's narrow-scope instruction.
- **Test**: add a `blocTest` (or a plain `test` if `blocTest`'s `expect` shape
  doesn't fit a "close mid-flight" scenario) that closes the cubit while an
  action's repository call is still pending (e.g. a `Completer`-backed mock
  stub for `repository.exportMixdown`), then asserts the returned `Future`
  from the action method completes without throwing and no `StateError`
  propagates. Model the mocking/fake-repository conventions on the existing
  `test/session/cubit/session_cubit_test.dart` (mocktail mocks, `_MockSessionRepository`
  etc. already defined there).
- **`refreshSessions()` gets the same guard** even though it's not part of
  `_run` — the issue explicitly calls it out as sharing the identical gap.

## Open Questions

None blocking — this is a narrowly-scoped, pre-verified bug fix with an
established in-codebase idiom to copy. The only judgment call (guard style:
statement-before vs. inline `if (!isClosed) emit`) is resolved above by
majority-pattern matching, documented as an assumption since there is no live
reviewer to ask synchronously in this run.
