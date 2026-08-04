# Platform Identity / Icons / Flavors — Review

Scope: Loopy→Segno rebrand checklist for bundle IDs, Kotlin package path,
`FLAVOR_APP_NAME`, Icon Composer assets, Android mipmaps, Windows `.ico`,
Linux `APPLICATION_ID`, and stale `Flag.png` / `Environment.png` refs.

## Checklist summary

| # | Check | Result |
|---|--------|--------|
| 1 | Bundle/application IDs `dev.aquiles.segno` (+ `.dev` / `.stg` / `.RunnerTests`) | **FAIL** — macOS production still `com.example.myApp` |
| 2 | Android Kotlin path `dev/aquiles/segno` + matching package | **PASS** |
| 3 | `FLAVOR_APP_NAME` / Android `appName` Segno / `[DEV]` / `[STG]` | **PASS** |
| 4 | Icon Composer: prod Logo only; dev/stg Logo+Badge; fill black | **PASS** |
| 5 | Android mipmaps all flavors; white-on-black | **PARTIAL** — mipmap PNGs OK; adaptive icons still scaffold |
| 6 | Windows `app_icon.ico` updated; Linux `APPLICATION_ID` | **PASS** |
| 7 | No `Flag.png` / `Environment.png` refs in `icon.json` | **PASS** |

## Findings

### Critical

1. **macOS production bundle ID is still `com.example.myApp`**
   - `macos/Runner/Configs/AppInfo.xcconfig` sets `PRODUCT_BUNDLE_IDENTIFIER = com.example.myApp`.
   - Runner `Debug-production` / `Release-production` / `Profile-production` use that xcconfig as `baseConfigurationReference` and do **not** override `PRODUCT_BUNDLE_IDENTIFIER`.
   - Dev/stg correctly override to `dev.aquiles.segno.dev` / `.stg`; RunnerTests use `dev.aquiles.segno.RunnerTests`.
   - iOS / Android / Linux production IDs are `dev.aquiles.segno` as required.
   - Impact: production macOS builds ship under the scaffold identifier, not Segno.

2. **Android API 26+ launcher still shows scaffold (non-Segno) adaptive icon**
   - Legacy mipmaps under `main` / `development` / `staging` are present at all densities and sample as white-on-black Segno (dev/stg also have cyan banner pixels).
   - Adaptive icons (`mipmap-anydpi-v26` → `@drawable/ic_launcher_foreground` + `@color/ic_launcher_background`) still use scaffold vectors:
     - background `#FFFFFF` in all flavors
     - foreground is the old VGV/scaffold artwork (black on white; flavored variants keep `#13B9FD` accents), unchanged since scaffold commit
   - On API 26+, the adaptive icon wins over the updated mipmap PNGs, so the visible home-screen icon is not Segno white-on-black.

### Important

3. **macOS `RunnerTests` `TEST_HOST` still points at `my_app.app`**
   - All RunnerTests configs set `TEST_HOST = …/my_app.app/…/my_app`.
   - Runner `PRODUCT_NAME` is `$(FLAVOR_APP_NAME)` → `Segno` / `[DEV] Segno` / `[STG] Segno`, so the host product is no longer `my_app`.
   - Impact: macOS unit-test host path is broken relative to the rebranded product name.

### Suggestion

4. **`AppInfo.xcconfig` still carries scaffold identity leftovers**
   - `PRODUCT_NAME = my_app`, `PRODUCT_COPYRIGHT = Copyright © 2023 com.example. …`
   - Even after fixing production `PRODUCT_BUNDLE_IDENTIFIER`, copyright (and any un-overridden name) would remain wrong unless updated in the same pass.

## What looks correct

- **Android**: `namespace` / `applicationId` `dev.aquiles.segno` with `.dev` / `.stg` suffixes; `MainActivity` at `android/app/src/main/kotlin/dev/aquiles/segno/MainActivity.kt` with `package dev.aquiles.segno` (old `dev/loopy/loopy` path renamed away).
- **iOS**: all flavors `dev.aquiles.segno` (+ `.dev` / `.stg` / `.RunnerTests`); `FLAVOR_APP_NAME` Segno / `[DEV] Segno` / `[STG] Segno`.
- **macOS flavors (non-prod)**: bundle IDs and `FLAVOR_APP_NAME` match the checklist; Icon Composer names wired (`AppIcon` / `AppIcon-dev` / `AppIcon-stg`).
- **Icon Composer** (iOS + macOS): prod `Assets/` = `Logo.svg` only (white glyph); dev/stg = `Logo.svg` + `Badge.png`; all six `icon.json` fills are `extended-gray:0.00000,1.00000` (black); no `Flag.png` / `Environment.png` references anywhere.
- **Windows**: `windows/runner/resources/app_icon.ico` updated (white-on-black Segno); `ProductName` / window title Segno.
- **Linux**: `APPLICATION_ID` / `BINARY_NAME` = `dev.aquiles.segno` / `segno`.

## Counts

- **Critical**: 2
- **Important**: 1
- **Suggestion**: 1
