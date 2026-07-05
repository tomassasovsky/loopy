---
title: "feat: named sessions — part 2: current session + CRUD (bloc layer)"
type: feat
date: 2026-07-04
---

## feat: named sessions — part 2: current session + CRUD (bloc layer) — Standard

> **Split note:** part 2 of 3 of the named-sessions plan (see
> `2026-07-04-feat-named-sessions-plan.md`). This PR is the **bloc layer only**:
> the document-editor current-session concept and CRUD orchestration on
> `SessionCubit`, on top of part 1's repository catalog. Verified entirely
> through cubit bloc tests — no UI consumer yet (the menu can stay on the old
> single-bundle path until part 3).

## Overview

Give `SessionCubit` / `SessionState` a tracked **current session** and CRUD
orchestration (`saveAs`, `save`, `loadNamed`, `renameSession`, `deleteSession`,
`refreshSessions`) over part 1's catalog. The cubit resolves name→path via
`repository.bundlePath(name)` and passes the path into the unchanged
path-addressed `read`/`save`. It also generalizes the session-directory resolver
to a sessions **root**.

The load-bearing correctness item: the existing `_run` helper emits a fresh
`const SessionState(...)` every call, which would wipe the new durable fields —
so `SessionState` gains a `copyWith` and `_run` is converted to preserve
`currentSessionName` + `sessions` across transitions.

## Context / findings

- `lib/session/cubit/session_cubit.dart` — composes `SessionRepository` +
  `LooperRepository`; `_run` emits a **fresh `const SessionState(...)`** and
  switches **exhaustively** over the sealed `SessionException`.
- `lib/session/cubit/session_state.dart` — `Equatable`, no `copyWith` today.
- `lib/session/session_mapping.dart` — `chainsFromLooper` / `rigFromBundle`
  (from #112), reused unchanged.
- `packages/session_repository/...` — part 1's `bundlePath` / `listSessions` /
  `renameSession` / `deleteSession` + `SessionNameCollision`.
- `lib/session_directory.dart` — `defaultSessionDirectory()` → generalize to
  `defaultSessionsRoot()` returning `<documents>/sessions`.

## Acceptance Criteria

- [ ] `SessionState` has a `copyWith`; every action transition preserves
      `currentSessionName` and `sessions` (a save/load/export never wipes them).
- [ ] `saveAs(name)` writes a new named bundle, sets it current, and refreshes
      the list; a duplicate slug emits `SessionError.nameCollision` (the
      repository is the authority) and writes nothing.
- [ ] `save()` writes back to `currentSessionName` with no name prompt; with no
      current session it signals the UI to open Save-As (does not silently pick
      a name).
- [ ] `loadNamed(name)` reads the bundle, applies it through
      `LooperRepository.applySession(rigFromBundle(...))`, sets it current, and
      refreshes the list.
- [ ] `renameSession(from, to)` renames via the repository; if `from` was the
      current session, `currentSessionName` updates to `to`.
- [ ] `deleteSession(name)` removes the bundle; if it was current, the pointer
      is cleared and the **rig is untouched** (`applySession` is not called).
- [ ] `flutter analyze` clean; `dart format` stable; cubit bloc tests green;
      coverage ≥ 90.

## Tasks

- [ ] `SessionState`: add a `copyWith`; add `currentSessionName` (nullable) and
      `sessions: List<SessionSummary>`; add `SessionError.nameCollision`.
- [ ] Convert `_run` to `emit(state.copyWith(status: …, outcome: …, error: …))`
      so durable fields survive; add the mandatory
      `SessionNameCollision => SessionError.nameCollision` arm to the exhaustive
      switch.
- [ ] `SessionCubit` orchestration (resolves name→path via
      `repository.bundlePath`, calls path-addressed `read`/`save`):
      `refreshSessions()`, `saveAs(name)`, `save()` (write-back / signal
      Save-As), `loadNamed(name)`, `renameSession(from, to)` (inline
      `current == from ? to : current`), `deleteSession(name)` (clears the
      pointer when current; rig untouched).
- [ ] `lib/session_directory.dart` → `defaultSessionsRoot()` (same
      `Future<String> Function()` shape).
- [ ] Tests (`test/session/cubit/session_cubit_test.dart`): a save **preserves**
      `currentSessionName` + `sessions`; each action's working→success/failure
      transitions with the right outcome/error; `save` with no current routes to
      the Save-As signal; a collision emits `SessionError.nameCollision`;
      `deleteSession` of the current clears the pointer and
      `verifyNever(applySession)`; `loadNamed` applies the rig AND sets current
      AND refreshes; `renameSession` of the current updates the shown name.

## Files touched (primary)

`lib/session/cubit/{session_cubit,session_state}.dart`,
`lib/session_directory.dart`, `test/session/cubit/session_cubit_test.dart`.

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed` stable.
2. `flutter test test/session/cubit` + coverage ≥ 90.

## Dependencies

- **Part 1** (session catalog) — uses `bundlePath` / `listSessions` /
  `renameSession` / `deleteSession` + `SessionNameCollision`.
- Transitively **PR #112** (`applySession`, `read`/`save`, `session_mapping`).

## Notes / accepted trade-offs

- The current-session pointer is **cubit-only state, never persisted** (no
  "last opened session" in prefs).
- Collision authority is the **repository** (atomic FS check → typed error); the
  cubit only surfaces it. Part 3's dialog adds a fast-feedback inline check that
  is never the enforcement point.
