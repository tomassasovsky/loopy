# Test Quality Review — Loopy → Segno Rebrand

**Scope**: Test imports, goldens/fixtures, and rename-sensitive coverage after the Loopy→Segno rebrand  
**Date**: 2026-08-04  
**Workspace**: `/Users/Tomas/Documents/Work/opensource/loopy`  
**Verdict**: Mostly solid — no broken `package:loopy` / stale Loopy fixtures; fix 2 Important coverage gaps before treating rename-sensitive paths as locked

---

## Test Quality Review

### Coverage Summary

- **Test run** (focused rename-sensitive suites): **Pass** — `+408 ~29` (skips are expected `SEGNO_ENGINE_LIB` / FFI self-skips)
  - Suites: `test/l10n`, `test/wifi/wifi_error_message_test.dart`, `test/window/window_chrome_test.dart`, `test/update/appliance`, `packages/session_repository/test`, `packages/update_repository/test/update_manifest_test.dart`, `packages/wifi_client|bluetooth_client|brightness_client|midi_client|segno_engine/test`
- **Coverage %**: Not measured (rebrand review scoped to rename-sensitive quality, not line %)
- **Import health**:
  - `package:segno/` in app tests: present across the suite (~96 `_test.dart` files under `test/`)
  - `package:segno_engine` in package/app tests: present (~35 `_test.dart` files)
  - `package:loopy` / `package:loopy_engine` in any `_test.dart`: **0**
- **Stale Loopy fixtures in tests**: **None** found under `test/`, `packages/*/test/`, or Yocto `segno-bundle/test/`
- **Goldens**: Brand-bearing settings / control-center goldens show **Segno** (OCR); **no** golden contains “Loopy”
- **Missing test files (rename-sensitive production defaults)**:
  - `packages/wifi_client/lib/src/system_wifi_client.dart` — default `helperPath` untested
  - `packages/bluetooth_client/lib/src/system_bluetooth_client.dart` — default `helperPath` untested
  - `packages/brightness_client/lib/src/system_brightness_client.dart` — default `helperPath` untested
  - `lib/pedal/flashed_firmware.dart` — `kFlashedPedalFirmwarePath` constant untested

### What looks good

| Area | Status | Evidence |
|------|--------|----------|
| Dart package imports in tests | Pass | All surveyed tests import `package:segno/...` and/or `package:segno_engine/...`; `fake_loopy_engine_bindings.dart` → `fake_segno_engine_bindings.dart` with matching imports |
| Display / l10n branding | Pass | `test/l10n/app_localizations_test.dart` expects `appMenuLabel == 'Segno'`; pedal/BT fixtures use “Segno Pedal” / alias `Segno` |
| Screenshot goldens (brand UI) | Pass | Working-tree updates to settings + `control_center_bluetooth` goldens; OCR reads “Segno”; no “Loopy” in any `test/screenshots/goldens/*.png` |
| `SEGNO_CONSOLE` gating | Pass | `test/window/window_chrome_test.dart` and `test/screenshots/tracks_screenshots_test.dart` gate on `kConsoleMode` / document `--dart-define=SEGNO_CONSOLE=true` |
| Appliance update ctl + paths | Pass | `test/update/appliance/appliance_platform_backend_test.dart` pins `/usr/bin/segno-update-ctl`, `/etc/segno/*`, `/data/segno/update-channel` |
| Wifi error mapping | Pass | `test/wifi/wifi_error_message_test.dart` uses `segno-wifi-ctl:` process text matching production `wifiErrorMessage` |
| Update manifest fixtures | Pass | `packages/update_repository/test` + update cubit/view tests use `segno-appliance-*.raucb` / `segno-pedal-*.hex` |
| Yocto shell ctl tests | Pass | `deploy/yocto/.../segno-bundle/test/*.sh` point at `files/segno-*` helpers (wifi/bt/mark-good/update-ctl/regdom) |
| Env / CI rename | Pass | `SEGNO_ENGINE_LIB` + `build_test_lib.sh` → `segno_engine_test.$EXT`; CI/workflows use Segno names |

### State Management / Repository Test Quality

- **session_repository tests**: Pass for behavior; **gap** on public “`.segno` bundle” naming (see Suggestions). Layout under test is `sessions/<slug>/session.json` (no filesystem `*.segno` / `*.loopy` suffix in code).
- **update / appliance backend tests**: Pass — rename-sensitive absolute paths asserted.
- **wifi/bluetooth/brightness client tests**: Models / unsupported clients covered; **production System\* default binary paths not pinned**.
- **flashed_firmware_test**: Pass for parse/read behavior with injected paths; **does not lock** `kFlashedPedalFirmwarePath`.

### UI Component / Golden Test Quality

- **settings / control_center goldens**: Pass for Segno branding where the brand string is visible.
- **tracks_main_window.png**: Console tracks layout (no brand word); **not** in the rebrand golden diff set (still older mtime / last commits predate this rebrand wave). No Loopy text, but not re-captured with the Aug 4 Segno golden refresh.

### Anti-Patterns Found

- None of the rebrand-scoped anti-patterns (tautologies, mocking the SUT, empty expects) stood out in the rename-sensitive suites reviewed.
- Local **stale build artifact** `packages/segno_engine/build/test_lib/loopy_engine_test.dylib` (Jul 30) sits beside the script’s new `segno_engine_test.*` name — gitignored, not referenced by current tests, but obsolete residue.

---

## Findings

### Important

1. **Missing default ctl binary path tests (wifi / bt / brightness)**  
   - **Rule**: Rename-sensitive public defaults must be pinned  
   - **Location**: `packages/wifi_client/lib/src/system_wifi_client.dart`, `packages/bluetooth_client/lib/src/system_bluetooth_client.dart`, `packages/brightness_client/lib/src/system_brightness_client.dart` (defaults `/usr/bin/segno-{wifi,bt,brightness}-ctl`); tests under `packages/*/test/` only cover models / unsupported clients  
   - **Why**: A typo reverting to `loopy-*-ctl` would not fail CI; only `segno-update-ctl` and wifi error *string* mapping are locked today  
   - **Fix**: Add narrow unit tests asserting each `System*Client().helperPath` (and optionally `create*Client` unsupported fallback on non-Linux)

2. **`kFlashedPedalFirmwarePath` not asserted**  
   - **Rule**: Rename-sensitive path constants need a direct expect  
   - **Location**: `lib/pedal/flashed_firmware.dart` (`/data/segno/pedal-firmware-version`); `test/pedal/flashed_firmware_test.dart` always injects a temp `path:`  
   - **Why**: Rebrand moved appliance data under `/data/segno/…`; parse/read tests never lock the production default, so a silent rename regression is possible  
   - **Fix**: One expect that `kFlashedPedalFirmwarePath == '/data/segno/pedal-firmware-version'` (and/or default-arg documentation test)

### Suggestion

3. **Console tracks golden not refreshed with rebrand goldens**  
   - **Rule**: Brand/layout goldens should be regenerated in the same rename wave when practical  
   - **Location**: `test/screenshots/goldens/tracks_main_window.png` (gated by `SEGNO_CONSOLE` in `test/screenshots/tracks_screenshots_test.dart`)  
   - **Why**: Five brand-visible goldens were updated in the working tree; this console golden was not. No “Loopy” text, but drift risk if console chrome changed during rebrand  
   - **Fix**: Regenerate with `flutter test --tags screenshots --dart-define=SEGNO_CONSOLE=true --update-goldens test/screenshots/tracks_screenshots_test.dart` if console UI was touched

4. **Stale local `loopy_engine_test.dylib` artifact**  
   - **Rule**: Obsolete rename residue should not linger next to current tooling  
   - **Location**: `packages/segno_engine/build/test_lib/loopy_engine_test.dylib` (local; gitignored). Current emitter: `packages/segno_engine/tool/build_test_lib.sh` → `segno_engine_test.$EXT`  
   - **Why**: Not a CI failure (ignored + env path from script), but confuses anyone grepping the tree for “loopy” leftovers  
   - **Fix**: Delete the old dylib locally / rebuild so only `segno_engine_test.*` remains

### Non-findings (explicit)

- **Session “`.segno` extension”**: Bundle type is documentation naming for a directory + `session.json`; there is no `*.segno` / `*.loopy` filesystem filter in production code. Session tests correctly exercise the slug-directory layout. No obsolete `.loopy` fixture remains. Not flagged as a missing extension-string test.
- **Broken / obsolete `package:loopy` test imports**: None.
- **SEGNO_CONSOLE define**: Comments and skip gates updated; compile-time `fromEnvironment('SEGNO_CONSOLE')` cannot be unit-tested without a separate define run (already handled via skip branches).

---

## Recommendations

1. Pin `SystemWifiClient` / `SystemBluetoothClient` / `SystemBrightnessClient` default `helperPath` values in package tests.
2. Pin `kFlashedPedalFirmwarePath` (and keep appliance backend path fixtures as the second line of defense).
3. Optionally refresh `tracks_main_window.png` and scrub the stale `loopy_engine_test.dylib` artifact.

## Verdict

**Fix 2 Important coverage gaps before treating ctl/data-path renames as fully locked.** Imports, goldens (no Loopy), session fixtures, `SEGNO_CONSOLE` gating, and update-ctl coverage are in good shape; focused suites pass.
