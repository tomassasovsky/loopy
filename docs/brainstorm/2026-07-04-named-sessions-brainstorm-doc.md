# Named sessions — brainstorm

**Date:** 2026-07-04
**Topic:** Turn the single fixed-bundle save/load into named, multiple session
bundles with full CRUD and a document-editor UX.
**Status:** decisions locked; ready for `/plan`.

> **Dependency:** builds on PR #112 (FX state robustness), which split
> `SessionRepository` into a pure `read(dir)` + `save(dir, {chains})`, made
> `LooperRepository.applySession(SessionRig)` the one apply path, and added
> `lib/session/session_mapping.dart`. The build branch must be based on #112
> (or on master once #112 merges), **not** plain master.

## Problem / motivation

Today loopy has exactly one session slot. `defaultSessionDirectory()`
(`lib/session_directory.dart`) resolves a single `loopy_session/` folder under
the app documents dir, injected into `SessionCubit` as the `directory`
resolver. "Save session" overwrites it in place; "Load session" reloads it.
There is no way to keep more than one arrangement, name them, or manage them —
every save destroys the previous one.

Users want to keep multiple named arrangements and manage them (rename, delete,
switch between them) like documents.

## Decisions (locked with the user)

| Decision | Choice |
| --- | --- |
| **Storage layout** | Each session is its own `.loopy` bundle directory under a top-level `sessions/<name>/` folder in the app documents dir (not flat). |
| **Operations** | Full CRUD: list, load, save-as (new name), rename, delete. |
| **Session model** | **Document-editor**: a "current session" is tracked. Loading or saving-as sets it; plain **Save** writes back to it silently; the UI shows its name. |
| **Migration** | **None.** The old `loopy_session/` bundle is left on disk but not shown; new work lives under `sessions/`. Fresh start. |
| **Picker UI** | The folder button opens **one Sessions-manager dialog**: a list with load-on-tap, per-row rename/delete, and a "Save as…" action. Export (mixdown / stems) stays a separate action. |
| **Naming & collisions** | Free-text name, sanitized to a folder-safe slug; a **duplicate name is rejected** with an inline error (no silent overwrite, no auto-suffix). |
| **Quick save** | A toolbar **Save** action (and Ctrl/Cmd+S) writes back to the current session silently; falls back to **Save-As** when no session is open. The manager handles Save-As / rename / delete / load. |
| **Active-session edges** | **Keep the rig, update the pointer.** The live audio never stops: rename just updates the current-session name; deleting the open session clears the "current session" pointer (rig keeps playing; the next Save becomes Save-As). |
| **Catalog ownership** | **`SessionRepository` owns the catalog** — it knows the `sessions/<name>/` layout and exposes name-keyed `list / create / rename / delete`; the cubit tracks the current session and orchestrates. |

## Chosen approach

**Repository owns the catalog; cubit tracks the current session; one manager
dialog.**

### Data layer — `SessionRepository` (packages/session_repository)

The repository is handed the **sessions root** (`<documents>/sessions`) instead
of a single bundle dir, and owns the `sessions/<name>/` layout:

- `Future<List<SessionSummary>> listSessions()` — enumerate `sessions/*/` that
  contain a valid manifest; each summary carries the name, maybe a saved-at
  timestamp and track count read cheaply from the manifest. Ignores stray
  folders without a manifest.
- `Future<void> renameSession(String from, String to)` — rename the bundle
  directory; throws a typed error on a name collision or a missing source.
- `Future<void> deleteSession(String name)` — remove the bundle directory.
- Name → path resolution lives here (`_bundlePath(name)` == `<root>/<slug>`).
  A single **slug/sanitize** helper (folder-safe, trims, collapses separators)
  is the one place names become paths.
- `read` / `save` / `exportMixdown` / `exportStems` keep their current shape but
  are addressed by **session name** (the repo resolves the path) rather than a
  raw directory. Existing `SessionException` grows collision / not-found kinds.

`SessionSummary` is a new immutable model (name + metadata) in
`session_repository/lib/src/models/`.

### Domain / apply — unchanged

`LooperRepository.applySession` and `session_mapping.dart` are reused verbatim
(#112). Named sessions add **no** new engine or looper-repository surface.

### Bloc layer — `SessionCubit`

`SessionCubit` gains the current-session concept and CRUD orchestration:

- State grows: `currentSessionName` (nullable), the `List<SessionSummary>` for
  the manager, plus the existing working/success/failure + outcome/error.
- `save()` — write back to `currentSessionName`; if none, delegate to a
  save-as flow (the UI collects a name first).
- `saveAs(String name)` — validate (reject duplicate), create, save, set
  current.
- `loadSession(String name)` — read → `applySession(rigFromBundle(...))` → set
  current.
- `renameSession`, `deleteSession`, `refreshList`. Delete of the current
  session clears `currentSessionName` (rig untouched).
- Still composes `SessionRepository` + `LooperRepository` (repositories never
  import repositories). The `directory` resolver becomes a **sessions-root**
  resolver (`lib/session_directory.dart` → `defaultSessionsRoot()` returning
  `<documents>/sessions`).

### Presentation — the Sessions manager

- Replace the `SessionMenu` popup's Save/Load items with a **"Sessions…"**
  entry (and keep export). It opens a **SessionsManagerDialog** (`showDialog`,
  following `rename_track_dialog.dart` / `plugin_browser.dart` precedents):
  a scrollable list of `SessionSummary` rows (name + metadata), each row
  load-on-tap with trailing rename / delete affordances, and a header
  **"Save as…"** button that opens a name-input dialog (sanitize + inline
  duplicate error, reusing the rename-dialog pattern).
- A **quick Save** action in the toolbar + **Ctrl/Cmd+S** writes back to the
  current session (falls back to opening the Save-As name dialog when none is
  open). The top bar shows the current session name (or "Unsaved").
- Outcomes/errors keep flowing through the existing `SessionState` +
  BlocListener SnackBar.

## Alternatives considered (and rejected)

- **Cubit owns the layout, repository stays path-only** — the cubit builds
  `sessions/<name>` paths and the repo only gains a directory-lister. Rejected:
  the storage-layout convention would leak into the bloc layer; path-building
  belongs in the data layer that owns file I/O.
- **Flat bundles named by directory** (no wrapping `sessions/`) — rejected in
  favour of a dedicated `sessions/` root so listing is a single well-known
  folder and future non-session bundles don't get mixed in.
- **Migrate the old `loopy_session/`** — rejected for now (simplest to start
  fresh); the folder is harmless on disk and can be surfaced later if anyone
  misses it.
- **Silent overwrite / auto-suffix on duplicate names** — rejected in favour of
  an explicit rejection so a save-as can never clobber another session or
  quietly rename itself.

## Edge cases to cover in the plan

- No sessions yet → manager shows an empty state; Save with no current session
  opens Save-As.
- Invalid / empty / whitespace-only name after sanitize → inline error, no
  write.
- Duplicate name on save-as **and** on rename → typed collision error, inline.
- Delete the currently-open session → pointer cleared, rig keeps playing.
- A `sessions/<name>/` folder missing/corrupt manifest → skipped in `list`,
  and `load` surfaces the existing typed failures (sample-rate mismatch,
  unsupported version) through the SnackBar.
- Sample-rate-mismatch / unsupported-version on load are unchanged (already
  classified in #112).

## Out of scope

- Migrating or importing the legacy single bundle.
- Cloud / cross-device sync, session thumbnails/waveform previews, tags/search.
- Multi-lane session stems (still lane-0-only — a separate documented
  follow-up) and lane routing in the manifest (chains + monitor routing only,
  per #112).
- Duplicating a session, or "recent sessions" ordering beyond a simple sort.

## References

- PR #112 — FX state robustness (the session infrastructure this builds on).
- `packages/session_repository/lib/src/session_repository.dart` — `read` /
  `save` split.
- `lib/session/cubit/session_cubit.dart`, `lib/session/session_mapping.dart` —
  bloc-layer composition + bundle mapping.
- `lib/looper/view/tracks_chrome.dart` — the `SessionMenu` popup to replace.
- `lib/session_directory.dart` — the single-bundle resolver to generalize.
- `lib/looper/view/rename_track_dialog.dart` — name-input dialog precedent.
- `lib/looper/view/signal_graph/plugin_browser.dart` — searchable-list picker
  precedent.
