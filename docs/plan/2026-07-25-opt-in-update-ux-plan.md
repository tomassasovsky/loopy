# Plan — Opt-in in-app software updates (appliance + desktop)

Tracking: **#306** (epic). This is Phase 4 ("Update UX") of
`docs/plan/2026-07-24-appliance-ab-updates-plan.md`, now that the transport
(RAUC A/B + mirror + channels) is proven end-to-end on the Pi.

## Goal
User-facing, **opt-in** updates. Nothing downloads or installs without an
explicit action. A passive read-only check powers a dismissible startup notice;
Settings holds the controls; applying is **stage-then-restart** so a live session
is never interrupted.

## Locked decisions (from the user)
1. **Passive check** = automatic but read-only (reads the tiny manifest only),
   with a Settings toggle "Check for updates automatically" (default on). Fully
   manual = toggle off + "Check now".
2. **Apply = stage-then-restart.** "Download & install" writes the inactive slot
   in the background; a separate "Restart to apply" reboots when the user chooses.
   Never a one-shot immediate reboot; the restart control is guarded while a loop
   or live session is active. (This is a live instrument.)
3. **Startup notification**, dismissible **per version** (a persisted `Set<int>`).
4. **Scope**: appliance (Pi/RAUC) **and** desktop (macOS/Windows) behind one
   shared abstraction.

## Architecture

Loopy is VGV-layered: `bloc` + `RepositoryProvider` DI, `packages/*_repository`,
`shared_preferences` behind a `KeyValueStore`. The update feature mirrors those.

### Shared core — `packages/update_repository/` (pure Dart)
- `UpdateManifest` — `{version:int, bundle, sha256, channel, size:int, notes}`.
- `UpdateState` (equatable) — phase `{idle, checking, upToDate, available,
  downloading(progress), staged, error}` + `currentVersion`, `available`
  manifest, `dismissed` set.
- `UpdateRepository` (abstract) over a `PlatformUpdateBackend`:
  - `Future<int> currentVersion()`
  - `Future<UpdateManifest?> check()`  — read-only manifest fetch + compare
  - `Stream<double> download()`        — stage to inactive slot / background DL
  - `Future<void> applyAndRestart()`   — reboot (Pi) / relaunch (desktop)
- Backends: `AppliancePlatformBackend`, `DesktopPlatformBackend`,
  `UnsupportedPlatformBackend` (generic dev Linux → feature hidden).

### State — `UpdateCubit` (mirrors `HighContrastCubit`)
`load()` (provided `lazy:false` at app root, like `MonitorCubit`): read
`currentVersion`, `dismissed`, `autoCheck`; if `autoCheck`, call `check()`.
Methods: `check()`, `startDownload()`, `applyAndRestart()`,
`dismiss(version)`, `setAutoCheck(bool)`. (Cubit methods, per `bloc_lint`.)

### Persistence — extend `SettingsRepository`
- `updates.auto_check` → `getBool/setBool` (default true).
- `updates.dismissed` → CSV of ints via `getString/setString` (same idiom as the
  encoded lane-effects string), decoded to `Set<int>`.

### UI
- **Settings → Updates** (`lib/looper/view/settings_page.dart`): add `updates` to
  the `_Section` enum + `_SectionTab` label + `_updatesSection(context)`, built
  from `lib/setup/setup_surface.dart` widgets (`SetupGroupLabel`,
  `SetupToggleRow`, `SetupOptionRow`). Shows current version + channel, the
  auto-check toggle, "Check now", and — when available — version/notes/size,
  "Download & install" (progress), "Restart to apply" (guarded).
- **Startup banner** (`lib/app/view/app.dart`): new `_showUpdateBanner` using the
  existing `_messengerKey` `ScaffoldMessenger` (same pattern as
  `_showAudioRecoveryBanner`), triggered once via a `BlocListener<UpdateCubit,…>`
  when `available && !dismissed`. "Update…" → `openLoopySettings()` (lands on the
  Updates section); "Not now" → `cubit.dismiss(version)`.
- **Restart guard**: "Restart to apply" checks the looper/session state and
  warns/disables while recording or a non-empty session is loaded.
- l10n: new keys in `app_en.arb` **and** `app_es.arb`, used via `context.l10n`.

### App→OS boundary
- **Appliance**: keep all privileged RAUC work in the **systemd service**, not in
  Dart. Refactor `loopy-ota-check` into two verbs: `check` (read-only; the app can
  call this itself over HTTP, no privilege) and `install <version>`
  (download+stage). The app requests an install by launching a root oneshot
  (`loopy-ota-install@<v>.service`) through a **narrow polkit/sudoers rule** for
  the kiosk user, and polls a status file for progress; it reads
  `/run/loopy-update-pending` + `/data/.ota-staged-version` for staged state, and
  triggers reboot via logind (same polkit rule). No setuid, no in-Dart D-Bus.
  Convert the current auto-timer into an **opt-in check-only** unit (governed by
  the app's toggle) — no more silent auto-staging.
- **Desktop**: the `auto_updater` plugin (Sparkle/WinSparkle) behind
  `DesktopPlatformBackend`; its "download in background, install on quit" is the
  same stage-then-restart model. Appcasts at `/updates/{macos,windows}/appcast.xml`.

### CI / manifest
- Manifest gains `notes` + `size` (already added to the hand-built v2 manifest —
  make CI emit them). Generate per-channel appcasts for desktop.

## Phases (each an independently-mergeable PR)
1. **Core** — `update_repository` (models, interface, `UpdateCubit`, fakes) +
   `SettingsRepository` persistence. Pure Dart, fully unit-tested, no UI/platform.
   `autonomy:merge-gate`.
2. **UI** — Settings → Updates section + startup banner + restart guard + l10n,
   wired to a fake backend. `autonomy:merge-gate`.
3. **Appliance backend** — `AppliancePlatformBackend`; `loopy-ota-check` split
   into check/install; `loopy-ota-install@.service` + polkit/sudoers rule (Yocto);
   timer → opt-in check-only. `autonomy:blocked-verify` (device).
4. **Desktop backend** — `auto_updater` + `DesktopPlatformBackend` + appcast
   publishing. `autonomy:merge-gate` (signing is a hard prerequisite: macOS
   Developer ID + notarization + Sparkle EdDSA; Windows Authenticode).
5. **CI** — manifest `notes`/`size` + per-channel appcast generation.
   `autonomy:merge-gate`.

## Dependencies / notes
- Phases 1–2 are pure app work, testable with no hardware — land first.
- Phase 3 depends on the RAUC branch (`feat/appliance-data-partition`) and should
  fold in the robustness fixes #307 (auto mark-good), #308 (build-version stamp),
  #309 (per-slot SSH keys) so a committed update is truly hands-off.
- Phase 4 is gated on the Apple/Windows signing identities (out of our control).
- No new state-management lib; no `go_router`; `package_info_plus` is added only
  for desktop's self-version (Pi reads `/etc/loopy/build-version`).
