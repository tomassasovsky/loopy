---
title: "feat: named sessions — part 3: manager dialog + wiring (presentation)"
type: feat
date: 2026-07-04
---

## feat: named sessions — part 3: manager dialog + wiring (presentation) — Standard

> **Split note:** part 3 of 3 of the named-sessions plan (see
> `2026-07-04-feat-named-sessions-plan.md`). This PR is the **user-visible**
> layer: the Sessions-manager dialog, quick Save + shortcut, the current-session
> name in the top bar, l10n, and threading the sessions-root resolver through the
> app shell. It lands once parts 1 (catalog) and 2 (cubit) are proven by their
> own suites.

## Overview

Build the **Sessions manager** — one `showDialog` with a list of sessions
(load-on-tap, per-row rename/delete, a "Save as…" action, an empty state) — and
wire it into the top bar in place of the old Save/Load menu items. Add a quick
**Save** action + **Cmd/Ctrl+S** that writes back to the current session (falls
back to Save-As), show the current session name (or "Unsaved"), and thread the
sessions-root resolver through the app shell, removing the dead single-bundle
path.

## Context / findings

- `lib/looper/view/tracks_chrome.dart` — the `SessionMenu` popup (Save / Load /
  export) to restructure; export items stay.
- `lib/looper/view/rename_track_dialog.dart` — `showDialog` + `AlertDialog` +
  `TextField` name-input precedent for save-as / rename.
- `lib/looper/view/signal_graph/plugin_browser.dart` — searchable-list picker
  precedent for the manager list.
- `lib/session/cubit/session_cubit.dart` — part 2's `saveAs` / `save` /
  `loadNamed` / `renameSession` / `deleteSession` / `refreshSessions` +
  `currentSessionName` / `sessions` in state.
- `lib/app/view/app.dart` (~L42/99/280/595), `lib/app/run_loopy.dart` (~L126),
  `lib/looper/view/looper_page.dart` (~L21/41), `lib/main_mock.dart` — the
  `sessionDirectory` resolver chain to rename to a sessions root (and update the
  stale doc comments).

## Acceptance Criteria

- [ ] The top-bar folder button opens `SessionsManagerDialog`: an alphabetical
      list of sessions with load-on-tap, per-row rename/delete, a "Save as…"
      action, and an empty state when there are none. Export stays a separate
      action.
- [ ] Save-As / rename use a name-input dialog with an **inline** sanitize +
      slug-collision error (fast feedback only — the cubit/repository stays the
      authority; a collision still emits `SessionError.nameCollision`).
- [ ] Delete shows a confirm dialog, then calls `deleteSession`; deleting the
      current session keeps the rig playing and the top bar shows "Unsaved".
- [ ] A quick **Save** action and **Cmd/Ctrl+S** call `save()` (write-back);
      with no current session it opens the Save-As name dialog.
- [ ] The top bar shows the current session name (or "Unsaved").
- [ ] The sessions-root resolver is threaded through the app shell; the legacy
      single-bundle Save/Load path and `defaultSessionDirectory` references are
      removed; the old `loopy_session/` folder is left on disk.
- [ ] en/es l10n at parity (no untranslated keys); load failures (sample-rate /
      version) still surface through the SnackBar.
- [ ] `flutter analyze` clean; `dart format` stable; full suite green; manager
      widget tests included; coverage ≥ 90.

## Tasks

- [ ] `SessionsManagerDialog` (`lib/session/view/sessions_manager_dialog.dart`):
      list of `SessionSummary` rows (load-on-tap), trailing rename/delete, a
      header "Save as…", an empty state.
- [ ] Name-input dialog (save-as / rename) mirroring `rename_track_dialog.dart`
      with an inline sanitize + slug-collision error.
- [ ] Delete-confirm `AlertDialog` before `deleteSession`.
- [ ] `tracks_chrome.dart`: replace the Save/Load menu items with a **Sessions…**
      entry (keep export); add a quick **Save** action + **Cmd/Ctrl+S**
      shortcut; show the current session name / "Unsaved".
- [ ] Thread `defaultSessionsRoot` through `run_loopy.dart` / `app.dart` /
      `looper_page.dart` / `main_mock.dart`; rename the `sessionDirectory` param
      and fix the stale doc comments (LooperPage + the cubit `directory` param).
      Remove the dead single-bundle path and `defaultSessionDirectory`
      references.
- [ ] l10n: add the keys (Sessions…, Save as…, Rename, Delete, delete-confirm
      title/body, New session, name hint, duplicate-name error, empty-state,
      "Unsaved") to `app_en.arb` **and** `app_es.arb`; regenerate; keep parity.
- [ ] Widget tests (`test/session/view/sessions_manager_dialog_test.dart` +
      tracks_chrome additions): list renders rows + empty state; tapping a row
      loads; rename/delete fire the cubit (delete via the confirm); save-as
      shows the inline duplicate error; the quick Save action + shortcut invoke
      `save()`; the top bar shows the current name / "Unsaved".

## Files touched (primary)

`lib/session/view/sessions_manager_dialog.dart` (new) + the name-input dialog,
`lib/looper/view/tracks_chrome.dart`, `lib/app/view/app.dart`,
`lib/app/run_loopy.dart`, `lib/main_mock.dart`,
`lib/looper/view/looper_page.dart`, `lib/l10n/arb/app_{en,es}.arb`,
`test/session/view/*`, `test/looper/view/tracks_chrome_test.dart` (if present).

## Verification

1. `flutter analyze` clean; `dart format --set-exit-if-changed` stable.
2. `flutter test` + coverage ≥ 90.
3. Manual: Save-As "A" and "B"; edit the rig; quick Save (writes back, no
   prompt); open the manager, load "A" (rig swaps, name updates); rename "A" →
   collision with "B" rejected inline; rename to "C"; delete the open session
   (confirm → music keeps playing, "Unsaved", next Save prompts); relaunch →
   both sessions listed; old `loopy_session/` untouched.

## Dependencies

- **Part 2** (current session + CRUD cubit) — consumes `saveAs` / `save` /
  `loadNamed` / `renameSession` / `deleteSession` / `refreshSessions` and the
  `currentSessionName` / `sessions` state.
- Transitively **part 1** and **PR #112**.

## Notes / accepted trade-offs

- The dialog's inline collision check is a fast-feedback affordance only; the
  cubit/repository remains the collision authority.
- No migration of the legacy `loopy_session/` (sibling of the new root, never
  listed).
