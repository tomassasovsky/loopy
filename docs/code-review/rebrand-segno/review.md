# Code Review — rebrand/segno (Loopy → Segno)

0 open Critical/Important · 🔵 6 suggestions (hygiene / optional follow-ups)  
Agents: architecture, dart-wiring, deploy-firmware, empirical-verify, platform-identity, security, simplicity, test-quality, bugbot.  
**VGV review agent failed to complete** (retried twice; no `raw/vgv-review.md`).

Post-review fixes already applied before this consolidation (not re-listed as open findings):
- macOS `AppInfo.xcconfig` → `dev.aquiles.segno` / `Segno`; `TEST_HOST` per flavor
- Android adaptive-icon scaffold removed so mipmaps show Segno
- Path-pin tests for ctl helpers + `kFlashedPedalFirmwarePath`
- USB product cutover to `Segno Loopstation` + enclosure `vamp_*` → `segno_*`
- Flash-pedal bootstrap: GATE 1 still finds `VAMP_Loopstation`; GATE 4 requires `Segno_Loopstation`

## Findings Index

| ID | Severity | Rule | Location | Finding |
|----|----------|------|----------|---------|
| FINDING-01 | 🔵 Suggestion | `security/ota-channel-normalize` | `deploy/.../segno-ota-check`, `segno-update-ctl` | Mirror Dart channel normalization in shell |
| FINDING-02 | 🔵 Suggestion | `security/manifest-basename` | OTA download path | Reject `../` in bundle/hex names |
| FINDING-03 | 🔵 Suggestion | `security/data-path-migrate` | `/data/loopy` → `/data/segno` | No helper for appliances that keep `/data` across cutover |
| FINDING-04 | 🔵 Suggestion | `simplicity/ffi-prefix` | `packages/segno_engine` | Public `le_` / `LE_` / `lpw_*` prefixes left after package rename |
| FINDING-05 | 🔵 Suggestion | `tests/golden-freshness` | `test/screenshots/goldens/tracks_main_window.png` | Console tracks golden not re-captured in Segno wave |
| FINDING-06 | 🔵 Suggestion | `hygiene/stale-dylib` | `packages/segno_engine/build/test_lib/` | Local leftover `loopy_engine_test.dylib` (gitignored) |

## Suggestions

### FINDING-01 · `security/ota-channel-normalize` · shell OTA helpers
Mirror Dart `normalizeUpdateChannel` (`experimental` | `production` only) in `segno-ota-check` / `segno-update-ctl`.
- **Why**: Shell and Dart can disagree on channel strings.
- **Fix**: Same allow-list / normalize in both places.
- **Reported by**: security-review · [details](raw/security-review.md)

### FINDING-02 · `security/manifest-basename` · OTA artifact names
Reject `../` in published bundle/hex basenames before download.
- **Why**: Pre-existing path-traversal hygiene gap on artifact names.
- **Fix**: Basename allow-list / reject `..` segments.
- **Reported by**: security-review · [details](raw/security-review.md)

### FINDING-03 · `security/data-path-migrate` · appliance `/data`
Document or script `/data/loopy/*` → `/data/segno/*` for durable partition cutover.
- **Why**: App now reads `/data/segno/*`; old tree is orphaned if any units had `/data/loopy`.
- **Fix**: One-shot migrate in kiosk launch or a ctl helper (only if field units exist).
- **Reported by**: security-review · [details](raw/security-review.md)

### FINDING-04 · `simplicity/ffi-prefix` · `segno_engine` C ABI
`le_` / `LE_` / `lpw_*` remain inside the renamed package.
- **Why**: Dual mental model at the hottest boundary; intentional deferral, not a ship blocker.
- **Fix**: Optional later mechanical rename + ffigen regen.
- **Reported by**: code-simplicity-review · [details](raw/code-simplicity-review.md)

### FINDING-05 · `tests/golden-freshness` · console tracks golden
`tracks_main_window.png` was not re-captured with the Segno golden wave.
- **Why**: No Loopy text left, but may drift from current console UI.
- **Fix**: Regenerate under `--dart-define=SEGNO_CONSOLE=true` if console chrome changed.
- **Reported by**: test-quality-review · [details](raw/test-quality-review.md)

### FINDING-06 · `hygiene/stale-dylib` · local test lib
Gitignored `loopy_engine_test.dylib` may still sit next to `segno_engine_test.*`.
- **Why**: Confuses leftover searches; not shipped.
- **Fix**: Delete locally / rebuild test lib.
- **Reported by**: test-quality-review · [details](raw/test-quality-review.md)

## Why this matters

Ship blockers from the review pass are already fixed. What remains is optional hygiene and a deferred FFI prefix rename — none of it blocks merging the rebrand once you want a PR.
