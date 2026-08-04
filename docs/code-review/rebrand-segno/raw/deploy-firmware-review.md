# Deploy / Firmware / Appliance Review — Loopy → Segno rebrand

**Branch**: working tree (rebrand in progress; staged renames `meta-loopy` →
`meta-segno`, `loopy-*` → `segno-*`)  
**Scope**: Deploy RPi build, Yocto (`meta-segno` / `segno-bundle` / Plymouth),
pedal firmware trees + contract tests, and GitHub appliance/CI workflows.
Product/package renames elsewhere are out of scope unless they break these
paths.  
**No fixes applied** — findings only.

---

## Checklist results

| # | Check | Result |
|---|--------|--------|
| 1 | `deploy/rpi/build/*` uses `SEGNO_CONSOLE`, `segno` binary, `segno-arm64-build`, `segno-build.sh` (not `loopy*`) | **PASS** |
| 2 | `meta-segno` / `recipes-segno` / `segno-bundle` / `plymouth-segno` paths consistent; ctl scripts match Dart clients | **PASS** |
| 3 | `firmware/test/run_tests.sh` paths to `firmware/segno_pedal` and `hardware/firmware/segno_pedal_32u4` exist | **PASS** |
| 4 | `.github/workflows` reference `packages/segno_engine` and `segno` paths | **PASS** |
| 5 | `git grep -i loopy -- ':!docs/plan/2026-08-04-rebrand-segno-plan.md'` empty for **source** | **PASS** (text: 0; binary: 4 — see Suggestion) |
| 6 | `bash firmware/test/run_tests.sh` | **PASS** (both protocol copies, all contract tests) |

---

## 1. `deploy/rpi/build/*`

Verified on disk:

| Artifact | Naming |
|----------|--------|
| `Dockerfile` | Image tag docs `segno-arm64-build`; copies `segno-build.sh` → `/usr/local/bin/segno-build`; example `--dart-define=SEGNO_CONSOLE=true` |
| `Dockerfile.arm64` | Inline entrypoint `/usr/local/bin/segno-build`; same `SEGNO_CONSOLE` story |
| `segno-build.sh` | Release build forwards `"$@"`; comments reference `SEGNO_CONSOLE` |
| `build-arm64-bundle.sh` | `IMAGE=segno-arm64-build`; defaults `--dart-define=SEGNO_CONSOLE=true`; verifies `$BUNDLE_REL/segno`; rsync to `~/segno/...` |

No `loopy*` filenames under `deploy/rpi/build/`. Linux binary name is `segno`
(`linux/CMakeLists.txt` `BINARY_NAME "segno"`), matching the bundle check and
`segno-kiosk-launch` (`exec /opt/segno/segno`).

Related RPi appliance units also renamed: `segno-kiosk.service`, install paths
under `~/segno/`, etc. No `loopy` text under `deploy/rpi/`.

---

## 2. Yocto / ctl helpers vs Dart clients

| Layer path | Present |
|------------|---------|
| `deploy/yocto/meta-segno/` | Yes (`BBFILE_COLLECTIONS += "segno"`) |
| `recipes-segno/segno-bundle/` | Yes (`segno-bundle.bb` + `files/` + `test/`) |
| `recipes-graphics/plymouth-segno-theme/` | Yes (`plymouth-segno-theme.bb`, `segno.plymouth` / `.script`, `segno-lockup.png`) |
| `kas-segno-rpi4.yml` | Layer `deploy/yocto/meta-segno`; targets `segno-kiosk-image` / `segno-update-bundle` |
| `RAUC_BUNDLE_COMPATIBLE` / `system.conf` | Both `segno-raspberrypi4` |

`deploy/yocto/meta-loopy` is **absent on disk** (rename complete; git status
shows `R`/`RM` from old paths into `meta-segno`).

Ctl install names in `segno-bundle.bb` (`SRC_URI` + `do_install` →
`${bindir}/…`) match Dart defaults:

| Helper | Recipe install | Dart `helperPath` |
|--------|----------------|-------------------|
| `segno-wifi-ctl` | `/usr/bin/segno-wifi-ctl` | `SystemWifiClient` |
| `segno-bt-ctl` | `/usr/bin/segno-bt-ctl` | `SystemBluetoothClient` |
| `segno-brightness-ctl` | `/usr/bin/segno-brightness-ctl` | `SystemBrightnessClient` |
| `segno-update-ctl` | `/usr/bin/segno-update-ctl` | `SystemApplianceEnv` / `AppliancePlatformBackend` |

Bundle install root `/opt/segno`, launcher `segno-kiosk-launch`, unit
`segno.service`, Plymouth theme `Theme=segno` — all consistent. No `loopy`
string under `deploy/yocto/meta-segno` (text sources).

---

## 3. Firmware trees + contract gate

`firmware/test/run_tests.sh` sets:

- `PRIMARY=firmware/segno_pedal`
- `MIRROR=hardware/firmware/segno_pedal_32u4`

Both trees exist with matching `pedal_protocol.{h,c}`. No `loopy` under
`firmware/` or `hardware/firmware/` (text).

`hardware/firmware/segno_pedal_32u4/build.sh` emits
`segno-pedal-<version>.hex` and reads protocol version from
`firmware/segno_pedal/pedal_protocol.h` — aligned with CI.

**Ran:** `bash firmware/test/run_tests.sh` → exit 0  
(`ALL PASSED` against both copies; drift gate clean.)

---

## 4. GitHub workflows

**`.github/workflows/main.yaml`** (`name: segno`):

- Native / fuzz / VST3 jobs use `packages/segno_engine/...`
- Pedal compile: `hardware/firmware/segno_pedal_32u4/build.sh`, artifact
  `segno-pedal-ci.hex`
- Bundle helper tests under
  `deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/`

**`.github/workflows/appliance-release.yml`**:

- `docker build -t segno-arm64-build deploy/rpi/build` +
  `--dart-define=SEGNO_CONSOLE=true`
- Artifacts `segno-app-bundle`, `segno-pedal-firmware`
- Prebuilt binary chmod `deploy/yocto/prebuilt/bundle/segno`
- `kas-segno-rpi4.yml` / `bitbake segno-update-bundle`
- Mirror `segno.aquiles.dev`

No `loopy` / `loopy_engine` / `packages/loopy_engine` references in
`.github/`.

---

## 5. Residual `loopy` grep

```text
git grep -i loopy -- ':!docs/plan/2026-08-04-rebrand-segno-plan.md'
```

- **Text sources (`-I`)**: 0 hits  
- **Binary**: 4 hits (Suggestion below)

Intentional feature vocabulary (`looper`, `Looper`, `test_looper_mode_*`) is
unchanged per rebrand plan and is out of scope for this “loopy” grep.

---

## Findings

### Critical

_None._

### Important

_None._ Deploy / Yocto / firmware / appliance path wiring for the rename is
consistent end-to-end for source and CI. No broken ctl↔Dart name mismatch, no
missing firmware trees, no workflow pointers left on `loopy*` / `loopy_engine`.

### Suggestion

1. **Fab / enclosure binary exports still embed `loopy_*` names**  
   `git grep -i loopy` (excluding the rebrand plan) only matches:
   - `hardware/kicad/fab/segno_pedal_main_gerbers.zip` — members named
     `loopy_pedal_main-*`
   - `hardware/kicad/fab/segno_pedal_ring_gerbers.zip` — members named
     `loopy_pedal_ring-*`
   - `hardware/led_strip/out/segno_led_strip_gerbers.zip` — members named
     `loopy_led_strip-*`
   - `hardware/enclosure/out/segno_pedal_tht.glb` — extras
     `pcb_name: "loopy_pedal_tht"` (and related source path strings)

   Zip **filenames** are already `segno_*`; contents were not regenerated after
   the KiCad project rename. Not an appliance/boot/firmware runtime break.
   Optional follow-up: re-export gerbers/GLB so archive members and metadata
   say `segno_*` and the grep gate is fully empty.

---

## Checks performed

1. Read `deploy/rpi/build/{Dockerfile,Dockerfile.arm64,segno-build.sh,build-arm64-bundle.sh}`
2. Confirmed `meta-segno` layer.conf, kas, image/bundle recipes, Plymouth theme,
   RAUC `compatible`, `segno-bundle.bb` SRC_URI/install, ctl script headers
3. Cross-checked Dart `helperPath` defaults against installed ctl names
4. Confirmed firmware primary/mirror trees + `run_tests.sh` paths; ran the script
5. Grepped `.github/workflows` for `segno_engine` / `segno` / `loopy`
6. `git grep -i loopy` (text + binary); inspected zip member lists and GLB
   `pcb_name` strings
7. Confirmed `meta-loopy` / `packages/loopy_engine` / old firmware dirs **absent
   on disk** (staged renames only in git status)
