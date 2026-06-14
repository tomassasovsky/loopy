---
title: ASIO-only Windows, UI consolidation, and monitoring fix
type: refactor
date: 2026-06-13
brainstorm: docs/brainstorm/2026-06-13-asio-only-windows-and-ui-consolidation-brainstorm-doc.md
---

## ASIO-only Windows, UI consolidation, and monitoring fix — Extensive

## Overview

A consolidation pass that commits Loopy fully to **ASIO on Windows** and removes
the redundant surfaces that have accumulated around the audio path. Five
loosely-coupled workstreams ship as **five sequenced PRs**:

1. **Monitoring fix** — delete the global passthrough monitor; unify on the
   per-input live-monitor routing graph (+ one-time courtesy migration).
2. **Desktop-view removal** — collapse `UiMode` to a single Big Picture mode.
3. **Wizard removal + auto-start** — delete the first-run wizard and `needsSetup`
   gate; the app always lands on the looper with the engine auto-started.
4. **License + SDK vendoring** — relicense MIT → GPLv3, vendor the Steinberg ASIO
   SDK, make `LOOPY_ENABLE_ASIO` default-ON for Windows.
5. **Windows ASIO-only UI** — remove the WASAPI/ASIO selector + WASAPI pickers on
   Windows, add the no-driver/ASIO4ALL message, remove `exclusive` end-to-end.

macOS/Linux keep the miniaudio backend unchanged; only the Windows device path
and the cross-cutting UI/monitoring changes are affected.

> **This is an umbrella plan.** Each phase below is an independently-mergeable PR
> with its own acceptance criteria. PRs 1–3 are order-independent; PR 5 depends
> on PR 4 (ASIO always-on). Build them in number order for the cleanest review.
>
> **Technical review applied (2026-06-13):** the plan-splitting agent confirmed the
> 5-PR split is correct (no split/merge). Simplicity + VGV findings folded in — D1
> cache interface named, D3 "startable" config defined, D6 migration given a concrete
> owner (`runMonitorMigration` in `runLoopy`) and a shared `LE_MAX_INPUTS` ceiling,
> `StoredAudioConfig` equality-member updates called out, mock-path test committed,
> and the `url_launcher` / `AudioSetupView` / `activeBackend` unknowns resolved.

## Problem Statement

Loopy's Windows story has converged on ASIO — the only path to a pro interface's
full channel count (proven on the user's Focusrite at 18 in / 20 out). Three
redundant surfaces remain, each duplicating config/monitor logic and breeding
"two systems disagree" bugs:

- **Two monitor mechanisms.** The "Monitor input" toggle sets `config.passthrough`,
  which at engine start auto-enables input 0's live monitor (`monitors[0]`) with a
  default stereo mask ([engine.c:1951](packages/loopy_engine/src/engine.c:1951)).
  That overlaps the per-input routing graph (`MonitorCubit` →
  `le_engine_set_monitor_input`), so input 0 is audible even with nothing routed,
  and can **double** when input 0 is also routed explicitly.
- **Two UI modes.** The deprecated "desktop" `LooperView`, the mode toggle, and
  `ui_mode` persistence duplicate the Big Picture layout that is now the only one
  worth shipping.
- **Two config surfaces.** The first-run wizard (`_Wizard`/`_EngineStep`/…) and the
  in-app `AudioSettingsSection` both assemble engine configs and both render
  status/error notes — they drift (the recently-fixed WASAPI-vs-ASIO bug was a
  symptom).

On top of that, **`exclusive` (WASAPI exclusive mode)** is dead code on its only
platform once Windows is ASIO-only (ASIO has no share-mode concept), and the ASIO
SDK currently must be supplied by the user at build time (gitignored, opt-in flag
OFF), making Windows builds non-reproducible.

## Proposed Solution

Collapse to **one audio surface** (`AudioSettingsSection`), **one UI mode** (Big
Picture), and **one monitoring path** (per-input). Hardwire ASIO on Windows,
vendor its SDK under GPLv3, and auto-start the engine on launch so there is no
manual Start/Stop and no first-run gate.

### Critical cross-cutting design decisions (surfaced by flow analysis)

Removing the wizard deletes more than a setup screen — it deletes the **only**
home for several behaviors. These must be re-homed, or the consolidation
regresses UX. Each is baked into the relevant phase below.

| # | Concern | Resolution (baked into plan) |
|---|---------|------------------------------|
| D1 | **ASIO driver picker goes empty while ASIO is live.** `_loadAsioDrivers` returns `[]` when `activeBackend == asio` (R1 re-entrancy guard, [audio_setup_cubit.dart:65](lib/audio_setup/cubit/audio_setup_cubit.dart:65)). After PR 3 the engine auto-starts on ASIO *before* the cubit is built → picker is invisible exactly when everything worked. | **Enumerate ASIO drivers once at process start, before auto-start; cache the list and never clear it while live.** Concrete interface: a new `AudioSetupState.cachedAsioDrivers` field, seeded via a new `AudioSetupCubit({… List<AudioDevice> initialAsioDrivers = const []})` constructor arg from the startup enumeration in `runLoopy`. `_loadAsioDrivers` falls back to `cachedAsioDrivers` when live instead of returning `[]`. Switching driver does stop→start (a normal reopen). (Field + constructor arg land in **PR 3**; the picker consumes them in **PR 5**.) |
| D2 | **All engine-error display lives in the wizard** (`_ErrorBanner`, `state.error`/`errorDetail`). `AudioSettingsSection` never renders errors. | **Port an error banner into `AudioSettingsSection`** rendering `state.error` + `errorDetail`, reusing the wizard's existing l10n keys (do not hardcode strings). (PR 3) |
| D3 | **No manual start = no recovery.** After a failed auto-start, status is `error`/`stopped`; `_persistAndApply` only reopens `if (status == running)`, so changing a setting can't start the engine. | **`_persistAndApply` (re)starts the engine from any non-running status _only when the config is startable_.** "Startable" = `sampleRate > 0 && bufferFrames > 0` **and** a resolvable device/driver (on Windows: a non-empty `asioDriver` present in `cachedAsioDrivers`; elsewhere: always, since empty id = system default). Persisting a setting with an incomplete config must **not** boot audio (negative test required). Delete `start()`/`stop()`. (PR 3) |
| D4 | **"Land stopped in settings" has no mechanism.** `openLoopySettings()` is menu/keystroke only; the looper has no stopped empty-state. | **On a stopped engine, the looper shows an inline "audio not running" affordance that opens settings**, and the no-driver case shows the ASIO4ALL message there. (PR 3 for the empty state; PR 5 for the ASIO4ALL copy.) |
| D5 | **Windows ASIO→WASAPI silent fallback.** The native dispatcher falls back to WASAPI if the saved ASIO driver is gone ([audio_bootstrap.dart:61](lib/app/audio_bootstrap.dart:61)); PR 5 removes the WASAPI UI, so the user could run 2-ch WASAPI with no disclosure. | **On Windows, surface the active backend; if ASIO was requested but WASAPI is active, show a visible "ASIO unavailable — running on system audio" note + the ASIO4ALL link.** (Port of the wizard `asioFallback_note`.) (PR 5) |
| D6 | **Monitoring migration has no owner / no idempotency.** `MonitorCubit.load()` only restores saved routes; it can't see the legacy flag, and re-running would re-enable input 0 after a user disables it. | **A named free function `runMonitorMigration(SettingsRepository)`** runs in `runLoopy` **unconditionally, before** the engine-start branch (so it is independent of `saved == null` and of the mock-vs-native path), guarded by a `monitor.migrated_v1` done-flag. Repository owns the new accessors (`loadLegacyMonitorInput()`, the flag get/set, the `audio.monitor_input` key). The orchestration is a standalone testable unit, not inlined. (PR 1) |

## Technical Approach

### Architecture

**Layers touched:** native C engine (`packages/loopy_engine/src`), the FFI binding
(`packages/loopy_engine/lib`), the settings persistence package
(`packages/settings_repository`), and the app presentation (`lib/`).

**Dependency direction is preserved** — presentation → repository → engine. OS
policy stays in the presentation layer (`audio_bootstrap.dart`), as today.

---

### Phase / PR 1 — Monitoring fix (unify on per-input)

**Goal:** one monitoring path. Delete the global passthrough; the per-input
routing graph becomes the single source of truth. Add a one-time courtesy
migration so existing users keep hearing their input.

**Native engine**
- [engine_private.h:297](packages/loopy_engine/src/engine_private.h:297) — remove
  `int passthrough;`.
- [loopy_engine_api.h:213](packages/loopy_engine/src/loopy_engine_api.h:213) —
  remove `int32_t passthrough;` from `le_config`.
- [engine.c:1918](packages/loopy_engine/src/engine.c:1918) — remove
  `engine->passthrough = …`.
- [engine.c:1951-1953](packages/loopy_engine/src/engine.c:1951) — remove the
  `monitors[0]` auto-enable block.

**FFI binding**
- [loopy_engine_bindings.dart:1617](packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart:1617)
  — regenerate (`external int passthrough;` drops out). Run the binding generator;
  do not hand-edit generated code beyond what the generator emits.
- [engine_config.dart:46](packages/loopy_engine/lib/src/engine_config.dart:46),
  [:73](packages/loopy_engine/lib/src/engine_config.dart:73) — remove
  `passthrough` field + constructor param; remove its write into the native struct.

**Settings persistence (remove the field; migration reads the raw key)**
- **Decision (resolved): remove `monitorInput` from `StoredAudioConfig`**
  ([settings_repository.dart:31](packages/settings_repository/lib/src/settings_repository.dart:31))
  — it no longer round-trips through the engine. This touches **four** members of
  the hand-rolled value type: the field, the constructor, `operator ==`, and
  `hashCode`/`props` ([settings_repository.dart:67-96](packages/settings_repository/lib/src/settings_repository.dart:67))
  — update all four or risk a silent equality bug. The default read at
  [settings_repository.dart:169](packages/settings_repository/lib/src/settings_repository.dart:169)
  (`monitorInput: … ?? true`) is **deleted from `loadAudioConfig`** and its intent
  moves into `loadLegacyMonitorInput()`.
- Read `audio.monitor_input` only inside the migration via a narrow
  `loadLegacyMonitorInput()` accessor on `SettingsRepository`. The existing
  "ignored key" test is updated to assert the migration reads it.

**Presentation**
- [audio_setup_cubit.dart:103-107](lib/audio_setup/cubit/audio_setup_cubit.dart:103)
  — remove `setMonitorInput`.
- [audio_setup_cubit.dart:229](lib/audio_setup/cubit/audio_setup_cubit.dart:229)
  + [audio_setup_cubit.dart:417-419](lib/audio_setup/cubit/audio_setup_cubit.dart:417)
  — remove `passthrough: state.monitorInput` and the `monitorInput` hydration.
- [audio_bootstrap.dart:43](lib/app/audio_bootstrap.dart:43) — remove
  `passthrough: saved.monitorInput` from the auto-start config (**grep-assert no
  `passthrough` remains in any config assembly**).
- `AudioSetupState` — remove the `monitorInput` field.
- [audio_settings_section.dart:125-134](lib/audio_setup/view/audio_settings_section.dart:125)
  — the master "Monitor input" toggle gated per-input routing. **Replace the gate:**
  always show the per-input monitor routing entry (the "Configure input monitoring"
  button + `_monitorRouting`). The per-input system has its own per-input enable, so
  the master toggle is redundant.
- [audio_setup_steps.dart:311-317](lib/audio_setup/view/audio_setup_steps.dart:311)
  — the wizard's monitor toggle is removed with the wizard (PR 3); if PR 1 lands
  first, just delete the toggle widget here.

**Courtesy migration (D6)** — `runMonitorMigration(SettingsRepository)`, called from
`runLoopy` **unconditionally before** the engine-start branch (so it runs on the
mock path and on a no-saved-config first run, not just inside `tryAutoStartEngine`
which early-returns when `saved == null`):
1. If `monitor.migrated_v1 == true` → skip.
2. Read legacy `audio.monitor_input`. If `true` **and** no per-input monitor has an
   *enabled output route* saved (scan inputs `0..LE_MAX_INPUTS-1` via
   `loadMonitorInput(i)`; "no routes" = no input with `enabled == true && outputMask != 0`),
   then persist input 0 → main out: `saveMonitorInput(0, enabled: true, outputMask: 0x3)`.
   - **Use the shared `LE_MAX_INPUTS` ceiling, not a duplicated literal `8`.**
     `MonitorCubit._maxInputs` ([monitor_cubit.dart:51](lib/audio_setup/cubit/monitor_cubit.dart:51))
     and this scan must reference one source of truth (hoist to a shared const that
     mirrors the engine's `LE_MAX_INPUTS`), or the two drift — exactly the bug class
     this plan exists to remove.
3. Set `monitor.migrated_v1 = true` regardless, so it never re-runs.
   - Edge: a user with saved monitor *effects* but no enabled route is treated as
     "no routes" and migrated (acceptable — they had no audible monitor).
   - Edge: applied routing is persisted, then `MonitorCubit.load()` applies it to the
     engine on launch; it survives the first real device open.

**Tests (PR 1)**
- `mock_audio_engine_test.dart` / engine: no `monitors[0]` auto-enable; passthrough
  symbol gone.
- `settings_repository_test.dart`: legacy key read by migration; `migrated_v1`
  flag set; field removal.
- New `monitor_migration_test.dart`: (a) `monitorInput=true` + no routes → input 0
  enabled once; second run is a no-op (flag set); (b) `monitorInput=true` + existing
  routes → no change; (c) `monitorInput=false` → no monitoring.
- `audio_setup_cubit_test.dart`: `setMonitorInput`/`monitorInput` removal.
- `audio_settings_section_test.dart`: per-input routing always shown.

---

### Phase / PR 2 — Desktop-view removal (collapse `UiMode`)

**Goal:** Big Picture is the only mode. Delete the desktop layout, the toggle, and
`ui_mode` persistence. `WaveformWindowCubit` is independent and stays.

- [ui_mode_cubit.dart:5](lib/ui_mode/cubit/ui_mode_cubit.dart:5) — delete the
  `UiMode` enum + `UiModeCubit` + `_restore`. Remove the provider wiring.
- [looper_view.dart:20](lib/looper/view/looper_view.dart:20) — delete `LooperView`
  (desktop layout) and its mode-toggle button
  ([:127-132](lib/looper/view/looper_view.dart:127)).
- [big_picture_settings_page.dart:120-139](lib/looper/view/big_picture_settings_page.dart:120)
  — delete the "view section" mode toggle.
- [app.dart:318-321](lib/app/view/app.dart:318) — remove the `UiModeCubit`
  BlocListener; [app.dart:332-339](lib/app/view/app.dart:332) — replace the
  `BlocBuilder<UiModeCubit>` + ternary theme with a hardcoded
  `theme: AppTheme.bigPicture`. Delete `AppTheme.desktop`.
- **`_syncWindow`** is currently triggered by `UiModeCubit` changes
  ([app.dart:318](lib/app/view/app.dart:318)). Confirm the waveform window sync
  still fires on `WaveformWindowCubit` alone (it does — [:322](lib/app/view/app.dart:322))
  and drop the `UiMode` listener.
- Persistence: [settings_repository.dart:129](packages/settings_repository/lib/src/settings_repository.dart:129)
  `_uiModeKey`, `loadUiMode` ([:136](packages/settings_repository/lib/src/settings_repository.dart:136)),
  `saveUiMode` ([:146](packages/settings_repository/lib/src/settings_repository.dart:146))
  — remove. **Stale config:** a saved `ui_mode=desktop` is simply never read after
  removal (no crash; no migration needed).

**Tests (PR 2)**
- Delete `ui_mode` cubit/view tests; update app/widget tests that pump `UiModeCubit`.
- App golden: single Big Picture theme; no mode toggle present.

---

### Phase / PR 3 — Wizard removal + auto-start (the cross-cutting one)

**Goal:** no first-run gate, no manual Start/Stop; the app always lands on the
looper with the engine auto-started, and `AudioSettingsSection` is the only audio
surface — now carrying the error/recovery affordances the wizard used to own.

**Delete the wizard**
- [audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart) — delete
  `_Wizard` (:5), `_EngineStep` (:153), `_InputStep` (:281), `_ReadyStep` (:323),
  `_RunningPanel` (:366), `_ErrorBanner`, and the per-step notes.
- **Delete `AudioSetupView`** ([audio_setup_view.dart:18](lib/audio_setup/view/audio_setup_view.dart:18))
  and `AudioSetupPage` ([audio_setup_page.dart:27](lib/audio_setup/view/audio_setup_page.dart:27))
  — verified they only host the wizard (the sole remaining `AudioSetupView` usage is
  the deleted `_RootView` at [app.dart:388](lib/app/view/app.dart:388)).
- [app.dart:361-391](lib/app/view/app.dart:361) — delete `_RootView`/`_RootViewState`
  and the `needsSetup`/`_inSetup` gate; `home:` renders `LooperPage` directly.
- [app.dart:38](lib/app/view/app.dart:38),[:55](lib/app/view/app.dart:55),[:162-166](lib/app/view/app.dart:162)
  + [run_loopy.dart:57](lib/app/run_loopy.dart:57) — remove the `needsSetup` param
  threading.

**Remove manual lifecycle (D3)**
- [audio_setup_cubit.dart:274-304](lib/audio_setup/cubit/audio_setup_cubit.dart:274)
  — delete `start()` and `stop()`.
- [audio_setup_cubit.dart:206-221](lib/audio_setup/cubit/audio_setup_cubit.dart:206)
  — `_persistAndApply` becomes "persist, then (re)start the engine whenever a valid
  config exists" — not only when already running. So a setting change recovers from
  a stopped/error state. Set `error` status with `AudioSetupError` on failure (as
  today).

**Auto-start defaults (first run, D1 plumbing)**
- [audio_bootstrap.dart:25](lib/app/audio_bootstrap.dart:25) — `tryAutoStartEngine`
  gains a first-run path: when `saved == null`,
  - **Windows:** enumerate ASIO drivers (`repository.asioDrivers()`) **before opening
    any device** (R1); if ≥1, start on the first at its reported rate/buffer and
    persist that as the new saved config; cache the enumerated list for the cubit
    (D1). If 0 drivers, return "stopped, no driver" (engine not started).
  - **macOS/Linux:** start miniaudio on the system default by opening a zero-config
    `EngineConfig()` (the same default the wizard's first start used). **Verify** the
    zero-config open succeeds during build (it mirrors the mock `defaultConfig` path);
    if the open fails, set `error` status (surfaced by D2's banner).
- The enumerated-driver cache (D1) is passed into `AudioSetupCubit` via the new
  `initialAsioDrivers` constructor arg and held in `AudioSetupState.cachedAsioDrivers`,
  so the picker is populated even while ASIO is live. `_loadAsioDrivers` returns
  `cachedAsioDrivers` (instead of `[]`) when the backend is already active.

**Re-home wizard-only UI into `AudioSettingsSection` (D2, D4)**
- Add an **error banner** rendering `state.error` + `errorDetail`.
- Add a **"engine not running" empty state**: when stopped, the looper shows an
  inline affordance ("Audio isn't running — open settings") that calls
  `openLoopySettings()`. (The no-driver/ASIO4ALL copy is added in PR 5.)
- Port any keep-worthy status notes (loopback note, ASIO input note) as needed;
  the live status table already exists ([:204-233](lib/audio_setup/view/audio_settings_section.dart:204)).

**Tests (PR 3)**
- `audio_setup_cubit_test.dart`: `start`/`stop` removed; `_persistAndApply`
  (re)starts from `stopped`/`error` **when startable**; **negative case** — persisting
  a setting with an incomplete/non-startable config does **not** start the engine;
  error status on failed open; `_loadAsioDrivers` returns `cachedAsioDrivers` while live.
- New `audio_bootstrap_test.dart`: first-run Windows (drivers present → starts on
  first; absent → stopped); first-run mac/Linux (starts on zero-config default;
  open-fail → error surfaced).
- The **mock path** ([run_loopy.dart:42](lib/app/run_loopy.dart:42)) is now the only
  remaining first-launch surface for tests (both wizard and gate gone) — add a **named
  test** asserting the mock flavor lands directly on `LooperPage` with the engine
  started via `defaultConfig` and `App` constructed without `needsSetup`.
- `app_test.dart`: no `_RootView`/`needsSetup`; app lands on `LooperPage`.
- `audio_settings_section_test.dart`: error banner renders; stopped empty-state
  opens settings.

---

### Phase / PR 4 — License + SDK vendoring (relicense + ASIO default-ON)

**Goal:** GPLv3 repo with the Steinberg ASIO SDK vendored, ASIO built by default on
Windows. Riskiest change; reviewable on its own. **No app-behavior change.**

- **`LICENSE`** ([LICENSE:1](LICENSE)) — replace MIT with GPL-3.0-or-later full text.
- **Vendor the SDK** — commit `asiosdk_2.3.3_2019-06-14` (~5.5 MB, 39 files) with its
  Steinberg license file intact, under a stable path (e.g.
  `packages/loopy_engine/third_party/asiosdk/`). Pin the exact version in a README
  note next to it.
- **`.gitignore`** ([.gitignore:122-130](.gitignore:122)) — remove the
  `asiosdk/`/`ASIOSDK*/` exclusions and the "must not be vendored" comment.
- **CMake** — [packages/loopy_engine/src/CMakeLists.txt:77](packages/loopy_engine/src/CMakeLists.txt:77)
  flip `option(LOOPY_ENABLE_ASIO … OFF)` → **ON** for Windows (or default ON when
  `WIN32`), pointing the include/source paths at the vendored SDK. Keep the env-var
  override. Verify [windows/flutter/CMakeLists.txt](windows/flutter/CMakeLists.txt)
  picks it up.
- **License gate** — [.github/workflows/license_check.yaml:27](.github/workflows/license_check.yaml:27)
  scans **Dart deps only**, allow-list `MIT,BSD-3-Clause,…` — confirm it does **not**
  assert the repo license and needs no change. (If it inspects the repo `LICENSE`,
  add `GPL-3.0-or-later`.)
- **pubspec** — decide whether to add `license: GPL-3.0-or-later` to root
  [pubspec.yaml](pubspec.yaml) and [packages/loopy_engine/pubspec.yaml](packages/loopy_engine/pubspec.yaml)
  (no `license:` field today). **Recommendation:** add it for clarity; it's metadata
  only. SPDX headers on first-party sources are optional — defer unless desired.
- **cspell** — [.github/cspell.json](.github/cspell.json) already lists ASIO terms;
  add any new SDK identifiers that trip the spell check (e.g. `Steinberg`, `asiosys`).
- **MIT-string sweep** — grep the whole repo (root **and** every package pubspec:
  `loopy_engine`, `settings_repository`, `looper_repository`, `controller_repository`,
  `session_repository`, etc.) for any `MIT` assertion; the relicense is incomplete if
  any package still declares MIT.

**Tests / CI (PR 4)**
- Windows CI builds with ASIO compiled in by default (no user-supplied SDK step).
- `license_check` stays green.
- No Dart/Flutter test changes expected (no runtime behavior change).

---

### Phase / PR 5 — Windows ASIO-only UI (remove selector, pickers, exclusive)

**Goal:** Windows shows only ASIO controls. Remove the backend selector + WASAPI
pickers on Windows; add the no-driver/ASIO4ALL message; delete `exclusive`
end-to-end. **Depends on PR 4** (ASIO always-on). macOS/Linux UI unchanged.

**Hardwire ASIO on Windows**
- `platformAsioSelectable`/backend selection ([audio_bootstrap.dart:18](lib/app/audio_bootstrap.dart:18))
  — on Windows, force `backend = AudioBackend.asio` always; ignore a saved
  `backend=wasapi` (coerce to ASIO). Drop the selector:
  - [audio_settings_section.dart:36-58](lib/audio_setup/view/audio_settings_section.dart:36)
    (backend `SetupOptionRow`) — remove on Windows; mac/Linux keep their device
    pickers (they never showed a backend row).
- WASAPI device pickers on Windows ([audio_settings_section.dart:71-89](lib/audio_setup/view/audio_settings_section.dart:71))
  — on Windows, always render the **ASIO driver picker** branch
  ([:62-70](lib/audio_setup/view/audio_settings_section.dart:62)) using the cached
  driver list (D1). Keep WASAPI pickers for macOS/Linux.
- `setBackend` ([audio_setup_cubit.dart:122](lib/audio_setup/cubit/audio_setup_cubit.dart:122))
  — keep for mac/Linux; ensure it's never reachable on Windows.

**No-driver / ASIO4ALL message (D4 copy)**
- New l10n strings: a clear "No ASIO driver found" message + a link to
  `https://asio4all.org` (download a generic ASIO driver). Use **`url_launcher`**
  to open the external link (do not bundle ASIO4ALL — license forbids redistribution).
  **`url_launcher` is not yet a dependency (verified) — add it to the app `pubspec.yaml`.**
  Render it in `AudioSettingsSection` and in the looper stopped empty-state (D4) when
  Windows + 0 drivers.

**Surface the WASAPI fallback (D5)**
- When Windows requested ASIO but `engineStatus.activeBackend == wasapi`, show a
  visible "ASIO unavailable — running on system audio" note + the ASIO4ALL link
  (a **port** of the wizard `asioFallback_note` at
  [audio_setup_steps.dart:460](lib/audio_setup/view/audio_setup_steps.dart:460) — not
  net-new behavior). `EngineStatus.activeBackend` already reports the *negotiated*
  backend end-to-end (verified: [engine_snapshot.dart:440](packages/loopy_engine/lib/src/engine_snapshot.dart:440),
  mapped from native `active_backend`), so the precondition is satisfiable. Do **not**
  let it run silently.

**Remove `exclusive` end-to-end**
- Native: [loopy_engine_api.h:227](packages/loopy_engine/src/loopy_engine_api.h:227)
  `le_config.exclusive`; [:338](packages/loopy_engine/src/loopy_engine_api.h:338)
  `le_snapshot.exclusive_active`; [engine.c:1958](packages/loopy_engine/src/engine.c:1958)
  publish; the share-mode fallback —
  [engine_internal.h:55-60](packages/loopy_engine/src/engine_internal.h:55) enum,
  [engine.c:1692-1696](packages/loopy_engine/src/engine.c:1692) `le_decide_share_fallback`,
  [engine_miniaudio.c:158-177](packages/loopy_engine/src/engine_miniaudio.c:158)
  exclusive setup + retry. **Caution:** miniaudio share-mode is a macOS/Linux concern
  too — confirm removing `exclusive` doesn't break the default shared-mode open on
  those platforms (it should default to shared with no toggle).
- FFI: regenerate bindings —
  [loopy_engine_bindings.dart:1649](packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart:1649),
  [:1838](packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart:1838);
  remove `EngineConfig.exclusive`
  ([engine_config.dart:51](packages/loopy_engine/lib/src/engine_config.dart:51),[:98](packages/loopy_engine/lib/src/engine_config.dart:98))
  and `EngineStatus.exclusiveActive`.
- Settings: `StoredAudioConfig.exclusive`
  ([settings_repository.dart:19](packages/settings_repository/lib/src/settings_repository.dart:19),[:55](packages/settings_repository/lib/src/settings_repository.dart:55)),
  `audio.exclusive` key ([:156](packages/settings_repository/lib/src/settings_repository.dart:156)),
  `loadAudioExclusive` ([:192](packages/settings_repository/lib/src/settings_repository.dart:192)),
  save ([:207](packages/settings_repository/lib/src/settings_repository.dart:207)) —
  remove. As in PR 1, removing the `exclusive` field also touches the constructor,
  `operator ==`, and `hashCode`/`props` of `StoredAudioConfig` — update all of them.
  A saved `audio.exclusive=true` is simply ignored (no migration).
- Presentation: `platformDefaultExclusive`
  ([audio_bootstrap.dart:11](lib/app/audio_bootstrap.dart:11)), the cubit's
  `_defaultExclusive`/`setExclusive`/`exclusive` state
  ([audio_setup_cubit.dart:19](lib/audio_setup/cubit/audio_setup_cubit.dart:19),[:112](lib/audio_setup/cubit/audio_setup_cubit.dart:112),[:423](lib/audio_setup/cubit/audio_setup_cubit.dart:423)),
  the toggle + fallback note
  ([audio_setup_steps.dart:268-274](lib/audio_setup/view/audio_setup_steps.dart:268),[:451-456](lib/audio_setup/view/audio_setup_steps.dart:451)
  — already gone if PR 3 landed) — remove.

**Stale config coercion (D5)**
- On Windows: saved `backend=wasapi` → ASIO; saved `exclusive=true` → ignored;
  saved `asioDriver` absent from current enumeration → fall back to first enumerated
  driver, or the no-driver message if none. Implemented where the cubit hydrates
  ([audio_setup_cubit.dart:437-442](lib/audio_setup/cubit/audio_setup_cubit.dart:437)).

**Tests (PR 5)**
- `audio_settings_section_test.dart` (Windows): no backend selector; ASIO driver
  picker shown with channel-count labels from cache; no-driver → ASIO4ALL message;
  WASAPI-active → fallback note. mac/Linux: WASAPI pickers unchanged.
- `audio_setup_cubit_test.dart`: Windows coerces `backend`→ASIO and ignores
  `exclusive`; stale `asioDriver` → first driver.
- Engine/binding tests: `exclusive`/`exclusive_active` symbols gone; shared-mode
  open still works on mac/Linux.
- url_launcher invocation mocked for the ASIO4ALL link.

## Alternative Approaches Considered

- **Monitoring:** (B) keep a simple toggle that drives the per-input path; (C) gate
  passthrough so it can't double. **Rejected** — (A) unify-on-per-input deletes a
  whole subsystem instead of papering over the overlap (brainstorm decision).
- **WASAPI on Windows:** keep it selectable. **Rejected** — it's the redundant
  surface causing drift; ASIO is the only path to full channel count.
- **ASIO4ALL:** bundle the installer. **Rejected** — its license restricts
  bundled/commercial redistribution and it's closed freeware (unclean in a GPLv3
  repo). Link-to-download gives the same UX with no legal/packaging risk.
- **Trimmed ASIO SDK** vs full. **Full chosen** for completeness (sample + docs).
- **Single mega-PR.** **Rejected** — five loosely-coupled changes; separate PRs keep
  the risky relicense reviewable in isolation and let the high-value monitoring fix
  ship first.

## Acceptance Criteria

### Functional Requirements

**Monitoring (PR 1)**
- [ ] Input 0 is **not** audible unless explicitly routed via the per-input system.
- [ ] No double-monitoring when input 0 is routed.
- [ ] `monitorInput=true` + zero enabled routes → input 0 → main out enabled
      **exactly once**; re-run is a no-op (done-flag).
- [ ] `monitorInput=true` + existing routes → no change. `monitorInput=false` → no
      monitoring.
- [ ] No config assembly passes `passthrough` to the engine (grep-asserted).

**Desktop removal (PR 2)**
- [ ] Only Big Picture mode exists; no mode toggle anywhere; saved `ui_mode=desktop`
      loads without error.

**Wizard removal + auto-start (PR 3)**
- [ ] App always lands on the looper; no first-run gate.
- [ ] Windows + ≥1 ASIO driver: auto-starts on the first at its rate/buffer.
- [ ] Windows + 0 drivers: lands stopped; looper shows "open settings" affordance.
- [ ] macOS/Linux: auto-starts miniaudio on system default; open-fail shows an error.
- [ ] Changing any audio setting from a stopped/error state **(re)starts** the engine.
- [ ] `state.error`/`errorDetail` renders in `AudioSettingsSection`.

**License + SDK (PR 4)**
- [ ] `LICENSE` is GPL-3.0; SDK vendored with its license; Windows CI builds ASIO by
      default with no user-supplied step; `license_check` green.

**Windows ASIO-only (PR 5)**
- [ ] Windows: no backend selector, no WASAPI pickers; ASIO driver picker populated
      (even while live) with channel-count labels.
- [ ] Windows + 0 drivers: ASIO4ALL message with a working external link.
- [ ] Windows ASIO requested but WASAPI active: visible disclosure (no silent 2-ch).
- [ ] `exclusive` gone end-to-end; saved `backend=wasapi`/`exclusive=true` coerced;
      shared-mode open still works on mac/Linux.

### Non-Functional Requirements

- [ ] No added audio-thread work; the `monitors[0]` removal is a net reduction.
- [ ] External link opens via `url_launcher` (no in-app navigation to web); link is
      clearly labeled.
- [ ] Accessibility: new banners/empty-states have semantic labels; toggles removed
      cleanly (no orphaned keys).

### Quality Gates

- [ ] Coverage holds at the branch gate (per `194de18`); new logic (migration,
      auto-start, coercion) has unit tests. **Caveat:** the deletion-heavy PRs (2, 4)
      remove tested code and shift the coverage denominator — if the gate is an
      absolute percentage it may report a false drop; confirm the gate tolerates
      net-LOC reduction or adjust it in those PRs.
- [ ] `very_good test --coverage` + `dart analyze` clean across root + packages.
- [ ] Each PR independently green and independently revertable.
- [ ] Binding regeneration (not hand-edits) for both `passthrough` and `exclusive`
      removals.

## Success Metrics

- Zero monitoring "ghost/double" reports after PR 1.
- Windows users reach full channel count with no manual SDK or Start step.
- Net LOC reduction (one monitor path, one UI mode, no wizard, no `exclusive`).

## Dependencies & Prerequisites

- **PR 5 depends on PR 4** (ASIO always-on). PRs 1–3 are mutually order-independent.
- `url_launcher` (PR 5) — confirm it's already a dependency or add it.
- Native binding generator available locally to regenerate
  `loopy_engine_bindings.dart` (PRs 1 & 5).
- Windows toolchain for CMake/ASIO build verification (PRs 4 & 5).

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|------|----------|-----------|
| **D1 driver picker empty while live** ships an unusable Windows build | High | Cache enumerated drivers at process start; plumbed in PR 3, consumed in PR 5. Verified by a Windows widget test. |
| **Lost error/recovery UI** (wizard-only) | High | D2/D3/D4 explicitly re-home error banner, restart-from-stopped, and the stopped empty-state into `AudioSettingsSection`/looper. |
| **Silent WASAPI fallback** on Windows | Med | D5 surfaces the active backend + ASIO4ALL link. |
| **Removing `exclusive` breaks mac/Linux shared open** | Med | Default to shared with no toggle; regression test the default open on mac/Linux. |
| **GPLv3 relicense correctness** (SDK license file, no MIT assertions left) | Med | Keep Steinberg license intact; audit `license_check.yaml`, cspell, pubspec, and any MIT string; relicense PR reviewed in isolation. |
| **Binding regen drift** if hand-edited | Low | Regenerate via the generator; diff-review the generated file. |
| **Mock path bypasses auto-start logic** | Low | Add mock-path coverage or assert intentional divergence ([run_loopy.dart:42](lib/app/run_loopy.dart:42)). |

## Future Considerations

- macOS CoreAudio aggregate-device support could reuse the same single-surface
  settings UI.
- The per-input monitor graph is now the only monitor path — future per-input FX or
  metering extends cleanly.
- SPDX headers on first-party sources (deferred in PR 4) can be a follow-up sweep.

## Documentation Plan

- Update `README` build instructions: ASIO now builds by default on Windows; SDK is
  vendored (no user step). Note the GPLv3 license change.
- Add a short `third_party/asiosdk/README` pinning the SDK version.
- Update any contributor docs referencing the wizard, `UiMode`, or `exclusive`.

## References & Research

### Internal References

- Brainstorm: [docs/brainstorm/2026-06-13-asio-only-windows-and-ui-consolidation-brainstorm-doc.md](docs/brainstorm/2026-06-13-asio-only-windows-and-ui-consolidation-brainstorm-doc.md)
- Passthrough auto-enable: [engine.c:1951](packages/loopy_engine/src/engine.c:1951)
- Per-input monitor cubit: [monitor_cubit.dart](lib/audio_setup/cubit/monitor_cubit.dart)
- Auto-start path: [audio_bootstrap.dart:25](lib/app/audio_bootstrap.dart:25)
- First-run gate: [run_loopy.dart:42](lib/app/run_loopy.dart:42), [app.dart:361-391](lib/app/view/app.dart:361)
- Wizard: [audio_setup_steps.dart:5](lib/audio_setup/view/audio_setup_steps.dart:5)
- Single audio surface: [audio_settings_section.dart](lib/audio_setup/view/audio_settings_section.dart)
- `UiMode`: [ui_mode_cubit.dart:5](lib/ui_mode/cubit/ui_mode_cubit.dart:5)
- ASIO CMake flag: [packages/loopy_engine/src/CMakeLists.txt:77](packages/loopy_engine/src/CMakeLists.txt:77)
- `.gitignore` SDK exclusions: [.gitignore:122](.gitignore:122)
- License gate: [.github/workflows/license_check.yaml:27](.github/workflows/license_check.yaml:27)
- `exclusive` end-to-end: [loopy_engine_api.h:227](packages/loopy_engine/src/loopy_engine_api.h:227), [engine_miniaudio.c:158](packages/loopy_engine/src/engine_miniaudio.c:158), [audio_bootstrap.dart:11](lib/app/audio_bootstrap.dart:11)

### External References

- Steinberg ASIO SDK 2.3.3 (vendored; license included)
- ASIO4ALL — https://asio4all.org (linked, not bundled; redistribution restricted)
- GPL-3.0-or-later — https://www.gnu.org/licenses/gpl-3.0.html

### Related Work

- Recent commit `89853dd` — "feat: ASIO duplex audio backend on Windows" (the work
  this consolidation builds on).
- Branch: `feat/windows-native-support`.

## Open Questions (decide before/within the noted PR)

Resolved during technical review (folded into the phases above): D1 cache interface
(named field + constructor arg), D3 "startable" config definition,
`StoredAudioConfig.monitorInput` removal, `url_launcher` not-yet-a-dependency,
`AudioSetupView` deletion, `activeBackend` end-to-end availability. Remaining genuinely-open
calls:

1. **Windows WASAPI fallback** — surface-and-keep (D5, recommended) vs fail-loudly
   (suppress the native fallback so a missing ASIO driver errors instead of opening
   2-ch WASAPI). (PR 5)
2. **pubspec `license:` field + SPDX headers** — add metadata (recommended) vs
   `LICENSE`-only. (PR 4)
3. **macOS/Linux zero-config open** — the plan commits to opening a zero-config
   `EngineConfig()` on first run; this needs a one-time real-device confirmation on a
   Mac/Linux box during PR 3 build (mirrors the mock `defaultConfig` path, so low risk). (PR 3)
4. **Full vs trimmed ASIO SDK** — the brainstorm chose the full ~5.5 MB SDK for
   completeness; the simplicity review flags it as repo-size overhead. Honor the
   brainstorm decision unless the team prefers a minimal header/source subset. (PR 4)
