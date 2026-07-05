---
title: "feat: named sessions — part 1: session catalog (data layer)"
type: feat
date: 2026-07-04
---

## feat: named sessions — part 1: session catalog (data layer) — Standard

> **Split note:** part 1 of 3 of the named-sessions plan (see
> `2026-07-04-feat-named-sessions-plan.md`). This PR is the **data layer only**:
> a name-keyed catalog on `SessionRepository`. No bloc or UI consumer — it lands
> and is verified entirely through repository unit tests, leaving the existing
> single-bundle flow untouched.

## Overview

Add a **named-session catalog** to `SessionRepository`: enumerate, resolve,
rename, and delete `.loopy` bundles under a `sessions/<name>/` root, plus a
`SessionSummary` list model and a slug/validate helper. The existing pure
path-addressed `read(dir)` / `save(dir, {chains})` / `exportMixdown/
exportStems(path)` are **left exactly as they are** — the catalog is added
beside them, so #112's tested contract and the arbitrary-path export flow are
untouched. The cubit (part 2) will resolve name→path via `bundlePath` and feed
the path into those unchanged methods.

## Context / findings

- `packages/session_repository/lib/src/session_repository.dart` — `read`/`save`/
  `export*` are path-addressed pure I/O (from #112); the catalog methods are
  additive and do not re-key them.
- `packages/session_repository/lib/src/models/session.dart` — v2 `Session`
  manifest (`manifestName == 'session.json'`); models are `@immutable` with
  **hand-rolled** `==`/`hashCode` (no Equatable in this package).
  `SessionSummary` matches that style.
- `packages/session_repository/lib/src/session_exception.dart` — sealed
  `SessionException`; add one variant.
- `lib/session_directory.dart` — the sessions root `<documents>/sessions` is a
  *sibling* of the legacy `<documents>/loopy_session`, so the old bundle is
  never enumerated. (The resolver rename lands in part 2/3; part 1's catalog is
  handed a root path in tests.)

## Acceptance Criteria

- [ ] `listSessions(root)` returns a `SessionSummary` (name only) for every
      `root/*/` folder that contains a `session.json`, **alphabetically**; a
      folder without one is skipped.
- [ ] A present-but-newer-version (or otherwise unparseable) manifest is still
      LISTED — enumeration is a `stat` for `session.json`, never a manifest
      parse, so it cannot throw at list time.
- [ ] `bundlePath(name)` folds a name to a folder-safe slug and resolves it
      under the root; the stored name IS the slug (no separate display name).
- [ ] `renameSession(from, to)` renames the bundle folder; a target-**slug**
      collision throws `SessionNameCollision`; two inputs that fold to one slug
      collide.
- [ ] `deleteSession(name)` removes the bundle folder; a missing folder is a
      no-op (no exception).
- [ ] Empty / whitespace-only / unsanitizable names are rejected by the slug
      helper.
- [ ] `flutter analyze` clean; `dart format` stable; `session_repository`
      package suite green; coverage ≥ 90.

## Tasks

- [ ] `SessionSummary` (name only) in
      `packages/session_repository/lib/src/models/session_summary.dart` —
      `@immutable`, hand-rolled `==`/`hashCode`. Barrel-export it.
- [ ] Slug/validate helper (folder-safe fold; reject empty/whitespace/
      unsanitizable). The stored name IS the slug; collisions are slug
      collisions.
- [ ] `SessionRepository` catalog methods (leaving `read`/`save`/`export*`
      path-addressed and untouched): `String bundlePath(String name)`,
      `Future<List<SessionSummary>> listSessions()` (scan root for folders with
      a `session.json`, alphabetical, no parse), `renameSession(from, to)`
      (throws `SessionNameCollision` on target slug collision),
      `deleteSession(name)` (missing → no-op). The repository takes the sessions
      root (constructor arg or resolver) so tests can point it at a temp dir.
- [ ] `SessionException` gains **only** `SessionNameCollision` (sealed). No
      `SessionNotFound`.
- [ ] Tests (`packages/session_repository/test/`): list includes a folder with a
      `session.json`, skips one without; a newer-version manifest is still listed
      (parse-free); create/rename/delete round-trip on a temp dir; rename into an
      existing slug throws `SessionNameCollision`; delete-missing is a no-op;
      slug helper edges incl. two-inputs-fold-to-one-slug; `SessionSummary`
      value equality.

## Files touched (primary)

`packages/session_repository/lib/src/{session_repository,session_exception,models/session_summary}.dart`
(+ the package barrel), `packages/session_repository/test/*`.

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed` stable.
2. `flutter test packages/session_repository` + coverage ≥ 90.

## Dependencies

- **PR #112 (FX state robustness).** Reuses the #112 `SessionRepository` shape
  (`read`/`save`/`export*`). Base this branch on `fix/fx-state-robustness` (or
  master once #112 merges), then rebase onto master after #112 lands.

## Notes / accepted trade-offs

- **List is a `stat`, not a validation** — an unloadable (newer/corrupt)
  manifest is listed; its typed error surfaces on load (part 2/3), keeping
  enumeration cheap and parse-free.
- No `SessionNotFound`: single-user desktop app, no concurrent-mutation race to
  model; delete-missing is a no-op and rename-missing is a generic failure.
