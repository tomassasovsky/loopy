# Code Simplicity Review — Loopy → Segno rebrand

**Branch**: `rebrand/segno`  
**Scope**: YAGNI / leftover compatibility shims, dual-name indirection, dead
paths, and unnecessary abstraction introduced or left incomplete by the rename.  
**Plan**: `docs/plan/2026-08-04-rebrand-segno-plan.md` (Closes #247).  
**Note**: Feature vocabulary `Looper` / `looper_repository` and hardware product
brand **Segno** are intentional and out of scope unless they create dual-name
indirection for the software rename.

---

## Simplification Analysis

### Core Purpose

Finish a hard cutover of the product/package identity from Loopy to Segno:
package names, bundle IDs, session extension, appliance units, display strings,
and (per #247) USB-MIDI identity — with **no** backward-compat layers
(`AGENTS.md`, plan: `.loopy` → `.segno` with no dual-read).

### Unnecessary Complexity Found

- **`kPedalUsbProductNames` gained `Segno Loopstation` without a firmware
  cutover** (`lib/common/pedal_device.dart`). Firmware
  `hardware/firmware/segno_pedal_32u4/build.sh` still sets
  `build.usb_product="Segno Loopstation"`. The list comment says “newest first,”
  but the new name was appended after Segno, so nothing ships that string.
  Result: accept-list dual-name machinery for a name that does not exist on the
  wire.
- **Public C/Dart FFI surface still branded `LE_` / `le_*`** inside package
  `segno_engine` and header `segno_engine_api.h` (~132 `LE_*` macros, ~182
  `le_*` identifiers in the public header alone). Paths/package renamed;
  symbols did not. No `#define` shim layer — just dual mental models at the
  hottest boundary in the monorepo.
- **`lpw_*` native editor-window ABI** (`native_window_controller.h` / `.mm`)
  retains a Loopy-era prefix inside an otherwise `SEGNO_HOST_*`-guarded module.
- **Stale local build artifact**
  `packages/segno_engine/build/test_lib/loopy_engine_test.dylib` (gitignored);
  `tool/build_test_lib.sh` already emits `segno_engine_test.$EXT`.

### Code to Remove

- `lib/common/pedal_device.dart`: drop unused `'Segno Loopstation'` **or**
  complete the cutover (firmware `usb_product` + newest-first order) and keep
  Segno only as a true field-compat entry if required — Estimated LOC: ~1–5
  net once firmware/docs aligned; complexity saved is conceptual, not LOC.
- Optional follow-up (large): rename `LE_`/`le_*` → `SE_`/`se_*` (and `lpw_` →
  something neutral) with ffigen regen — large diff, not a small delete.
- Delete stale `loopy_engine_test.dylib` locally — Estimated LOC: 0 (binary).

### Simplification Recommendations

1. **Finish or revert the USB product rename**
   - Current: Dart list has both names; firmware/docs/tests still treat Segno as
     the only real product string; `Segno Loopstation` is dead.
   - Proposed: Either (a) change `build.usb_product` to `Segno Loopstation`, put
     it first, keep `Segno Loopstation` as the sole legacy entry, and align
     README/tests — or (b) remove `'Segno Loopstation'` until a real firmware
     rename ships (YAGNI).
   - Impact: removes dual-name indirection that does nothing today.

2. **Decide C ABI prefix policy explicitly**
   - Current: `segno_engine` package + `le_*` symbols.
   - Proposed: document “`le_` stays (looper engine)” in the plan as intentional,
     **or** schedule a single mechanical `le_`→`se_` rename with no compatibility
     macros (per `AGENTS.md`). Do not leave the dual brand unspoken.
   - Impact: clarity; large LOC churn only if renaming.

3. **Rename `lpw_*` with the ABI pass (or sooner)**
   - Current: `lpw_window_*` in an otherwise Segno-named host module.
   - Proposed: `se_host_window_*` / `segno_window_*` — no dual aliases.
   - Impact: small, localized cleanup.

### YAGNI Violations

- **Forward-looking USB accept-list entry for `Segno Loopstation`** with no
  producer — classic “add the new name before the rename ships.”
- **No Loopy session dual-read found** (good): `.loopy` does not appear outside
  docs; no compatibility shim for sessions.
- **No dual packages** (`loopy_engine` / `meta-loopy` gone from the worktree).
- **SPM header forwarder** (`macos/.../include/segno_engine_api.h`) is a
  pre-existing CocoaPods/SPM constraint, not rebrand-added indirection.

### Final Assessment

Total potential LOC reduction: **&lt;1%** if only dead USB alias + `lpw_` /
stale dylib; **large** only if C ABI is renamed.  
Complexity score: **Low–Medium** (rename is mostly clean; residual dual brands
are concentrated at USB product + FFI prefixes).  
Recommended action: **Minor tweaks** for USB product list/firmware alignment;
treat `LE_`/`lpw_` as an explicit follow-up or documented keep — do not add
compatibility macros.

---

## Findings

### 1. Important — Dead USB product dual-name (incomplete cutover)

- **Rule**: YAGNI / incomplete cleanup / dual-name indirection
- **Location**: `lib/common/pedal_device.dart` (`kPedalUsbProductNames`);
  `hardware/firmware/segno_pedal_32u4/build.sh` (`build.usb_product`);
  `hardware/firmware/segno_pedal_32u4/README.md`; `firmware/mocolufa-segno-rename.patch`
- **Why**: Issue #247 scoped renaming USB-MIDI device name strings. Manufacturer
  cut over to `segno`, but the product string still ships as `Segno Loopstation`
  while Dart appended `'Segno Loopstation'` to the accept list. Comment requires
  “newest first”; the new name is last and has no firmware producer — a
  compatibility-list entry for a string that never appears.
- **Fix**: Complete the firmware/`usb_product` rename and put the new name first
  (keep Segno only as real field legacy), **or** delete `'Segno Loopstation'`
  until that cutover is real. Align match tests with the production list.

### 2. Important — `segno_engine` package still exposes `LE_`/`le_*` ABI

- **Rule**: Dual-name indirection / incomplete rename cleanup
- **Location**: `packages/segno_engine/src/core/segno_engine_api.h` (and
  generated `lib/src/generated/segno_engine_bindings.dart`); scattered `le_*`
  sources (e.g. `le_device_backend.h`)
- **Why**: Paths, package name, dylib/`libsegno_engine.so`, and header filename
  say Segno; every public C symbol remains `LE_*` / `le_*`. There is no shim
  macro layer — just an unfinished identity cut at the FFI boundary. Plan
  mapping listed package rename only, so this may be deferred, but as shipped
  it is dual branding without an explicit “keep `le_`” decision.
- **Fix**: Either document `le_` as the stable internal prefix (looper engine)
  in the rebrand plan, or do one mechanical rename to `se_`/`SE_` with ffigen
  regen and **no** dual `#define` aliases (`AGENTS.md`).

### 3. Suggestion — `lpw_*` Loopy-era window prefix

- **Rule**: Leftover old-name branding
- **Location**: `packages/segno_engine/src/host/native_window_controller.h`,
  `.mm`, call sites in `host_vst3.cpp` / `host_clap.cpp`
- **Why**: Module guards/comments use Segno; API is still `lpw_window_*`
  (Loopy plugin window). Small, local dual name.
- **Fix**: Rename to a Segno-neutral prefix in the same pass as any ABI cleanup;
  no compatibility typedefs.

### 4. Suggestion — Stale `loopy_engine_test.dylib` build artifact

- **Rule**: Dead path
- **Location**: `packages/segno_engine/build/test_lib/loopy_engine_test.dylib`
  (ignored by `build/` in `.gitignore`); producer is
  `packages/segno_engine/tool/build_test_lib.sh` → `segno_engine_test.$EXT`
- **Why**: Pre-rename test dylib left on disk; scripts already use the new name.
  Not in git, but confuses local `SEGNO_ENGINE_LIB` / manual opens if someone
  points at the old filename.
- **Fix**: Delete the stale file (or wipe `packages/segno_engine/build/`).

---

## Checks performed

- Working-tree `rg` for `loopy` / `Loopy` / `dev.loopy` / `loopy_engine` outside
  `docs/` and `third_party/`: **no product-code hits** (rename string-clean).
- Confirmed no dual package dirs (`packages/loopy_engine`, `meta-loopy` absent).
- Confirmed no `.loopy` session dual-read in `session_repository` / app code.
- Entrypoints are solely `runSegno` / `segno_navigator` (no `run_loopy` shim).
- Cross-checked architecture review: package/layer rename complete; this review
  focuses on residual dual brands the architecture pass did not treat as
  structural defects.
