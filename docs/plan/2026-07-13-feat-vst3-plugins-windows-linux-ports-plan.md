# feat: Windows & Linux VST3 plugin ports (loopy-fx-vst3-plugins parts 13–14)

**Status:** Planned · **Date:** 2026-07-13 · **Type:** enhancement (build/packaging + CI)
**Series:** `loopy-fx-vst3-plugins` 17-part umbrella — this is **parts 13 (Windows)
and 14 (Linux)**. Part 12 (macOS notarization) and parts 15–17 (undefined) are
**out of scope**.

> The umbrella plan docs were never committed to `master`. This plan was
> reconstructed from git history + the breadcrumbs in
> `packages/loopy_engine/vst3/CMakeLists.txt` (verified against `origin/master@ad24a50`).

---

## Summary

The seven Loopy FX plugins (Delay, Reverb, Echo, Drive, Filter, Tremolo, Octaver)
ship as real `.vst3` bundles built by a standalone, hand-rolled CMake project at
`packages/loopy_engine/vst3/CMakeLists.txt` against the vendored SDK
(`packages/loopy_engine/third_party/vst3sdk`). That CMake **hard-fails off macOS**:

```cmake
if(NOT APPLE)
  message(FATAL_ERROR "... Windows/Linux ports land in parts 13-14.")
endif()
```

The **DSP is already portable C++17** — every `processor.cpp` reuses
`loopy_dsp_core` (the same engine kernels the app uses). Only three things are
macOS-bound, and all three have first-class SDK equivalents already vendored:

| macOS-bound today | Windows | Linux |
|---|---|---|
| `sdk` compiles `public.sdk/source/main/**macmain.cpp**` | `dllmain.cpp` (vendored ✅) | `linuxmain.cpp` (vendored ✅) |
| per-plugin link `-exported_symbols_list macexport.exp` | **none** — `SMTG_EXPORT_SYMBOL` = `__declspec(dllexport)` | **none** — `SMTG_EXPORT_SYMBOL` = `visibility("default")` |
| `sdk_common` links `-framework CoreFoundation` | drop it | drop it (add `-ldl -lpthread`) |
| `loopy_vst3_add_bundle`: `Contents/MacOS/<name>` + `Info.plist` + `PkgInfo` + `codesign` | `Contents/x86_64-win/<name>.vst3` (DLL) | `Contents/x86_64-linux/<name>.so` |

**Secondary gap this plan also closes:** the 16 parity/ID test files are built
today **only** by `run_native_tests.sh` behind an `if [ "$(uname -s)" = "Darwin" ]`
guard (`run_native_tests.sh:55`), and the `native-tests` CI job runs on
`ubuntu-latest` (`main.yaml:105`) — so they compile-and-run **nowhere in CI**. The
plugins have *zero* automated CI coverage today. This plan makes the `vst3/` CMake
project the **single** build+test definition via CTest, **migrating and deleting**
that Darwin-gated shell block (`run_native_tests.sh:105-320`) so the two can never
drift, and that CTest gate becomes the **invisibility gate** for the cross-platform
CMake refactor.

---

## Goals / Non-goals

**Goals**
- All 7 plugins build as loadable `.vst3` on **Windows** (MSVC) and **Linux** (gcc/clang).
- Correct per-OS `.vst3` bundle layout that hosts scan (`Contents/x86_64-win/*.vst3`,
  `Contents/x86_64-linux/*.so`).
- The parity/ID tests run in CI on **all three** OSes via CTest — the real correctness gate.
- **macOS bundle content and behavior are unchanged** (invisibility — bundle-tree
  `diff -r` sans signature/mtimes).

**Non-goals**
- Part 12: Developer-ID signing / hardened runtime / **notarization** (macOS distribution).
- Parts 15–17 (undefined — installer/packaging, CLAP, pluginval, extra DAW targets — needs its own brainstorm).
- Any change to the DSP, the plugin GUIDs, the `.als` export (`packages/daw_export/`),
  or the Flutter app.
- Bundling the built `.vst3`s into a release artifact (that's downstream of part 12).

---

## Current-state reference (verified file:line)

- `packages/loopy_engine/vst3/CMakeLists.txt`
  - `:23-27` the `if(NOT APPLE) FATAL_ERROR` guard to remove.
  - `:70-86` `sdk_common` — `:86` `-framework CoreFoundation` (macOS-only).
  - `:88-100` `sdk` — `:97` compiles `macmain.cpp` (the swap point).
  - `:102-138` `loopy_vst3_add_bundle()` — macOS bundle + `:123` `codesign`.
  - `:140-327` seven `loopy_vst3_<fx>` MODULE targets, each with
    `PREFIX "" SUFFIX ""` (`:149-150`) and `-exported_symbols_list macexport.exp` (`:163`).
- SDK entry/export (all vendored under `third_party/vst3sdk/public.sdk/source/main/`):
  `macmain.cpp`, `dllmain.cpp`, `linuxmain.cpp`, `macexport.exp`. **No** `winexport.def`
  / `linuxexport.lds` exist — and none are needed (`SMTG_EXPORT_SYMBOL` handles export;
  confirmed `dllmain.cpp:48` `InitDll`, `linuxmain.cpp:30` `ModuleEntry`).
- 16 tests: `vst3/{delay,drive,echo,filter,octaver,reverb,tremolo}/test_vst3_*_ids.cpp`,
  `vst3/{delay,reverb}/test_vst3_*_wrapper.cpp`, `vst3/test/test_*_parity.cpp`. **These
  ARE built** — by `run_native_tests.sh:105-320`, but **only** under
  `if uname = Darwin` (`:55`). Since `native-tests` runs on `ubuntu-latest`, they run in
  no CI. Link facts to reuse when wiring CTest: `test_vst3_*_ids` are standalone (only
  `ids.h`); `test_*_parity` need `pluginfactory.cpp` (already in the `sdk` target,
  `CMakeLists.txt:96`); the two `*_wrapper` tests additionally need
  `public.sdk/source/common/**memorystream.cpp**` (included at
  `test_vst3_delay_wrapper.cpp:31`) which the shell block compiles but **`sdk_common`
  does not** (`CMakeLists.txt:70-83`).
- CI: `.github/workflows/main.yaml` — `build-macos:148`, `build-windows:35`,
  `build-linux:48`, `native-tests:104`. **No job builds the `vst3/` CMake project.** Each
  multi-OS concern is a **discrete named job** (not a matrix) — comments explicitly note
  "so the matrix can't silently drift."
- Windows MSVC / `loopy_dsp_core`: `src/CMakeLists.txt:38-43` **already** applies
  `/experimental:c11atomics` to `loopy_dsp_core` under MSVC, and `vst3/CMakeLists.txt:49`
  pulls that target in via `add_subdirectory(../src)`. Because the flag is `PRIVATE` and
  the lib's TU compiles inside that sub-build, it propagates automatically — **no MSVC
  block needed in `vst3/CMakeLists.txt`**. (`core_plugin_disabled_stub` is C11 with no
  atomics — it includes only the FFI ABI header, no `_Atomic`.)

---

## Technical approach

### PR split (3 PRs, each independently mergeable, in order)

Splitting keeps each PR reviewable and puts the risky refactor behind a green
macOS gate before any new-OS complexity lands.

#### PR 1 — Portable CMake foundation + CTest gate (single source) + macOS CI *(enabling; part-13 pre-work)*
Behavior-preserving on macOS. No new OS yet.
- Refactor `vst3/CMakeLists.txt` to isolate the OS-specific layer behind
  `if(APPLE)/elseif(WIN32)/else()` blocks **without changing macOS output**:
  - `set(LOOPY_VST3_MODULE_ENTRY <macmain|dllmain|linuxmain>.cpp)` fed into `sdk`.
  - `sdk_common` platform link: `-framework CoreFoundation` only `if(APPLE)`.
  - A **per-OS variable** (`LOOPY_VST3_PLUGIN_LINK_OPTS`, not a function — smaller
    blast radius) so `-exported_symbols_list macexport.exp` is applied **only** `if(APPLE)`.
  - **Add `public.sdk/source/common/memorystream.cpp` to `sdk_common`** (the wrapper
    tests need `MemoryStream`; unreferenced by the plugin MODULE targets, so macOS
    bundles stay unchanged — invisibility holds).
  - Generalize `loopy_vst3_add_bundle()` with a per-OS body (macOS branch identical
    to today: `Contents/MacOS` + `Info.plist` + `PkgInfo` + `codesign`).
  - Per-OS MODULE `SUFFIX` (macOS `""`, Windows `.vst3`, Linux `.so`) — variablized now,
    exercised later.
- **Keep the `if(NOT APPLE) FATAL_ERROR`** for now (so PR 1 truly ships no behavior
  change) — PR 2/3 remove it. (Smaller blast radius than stubbing the new-OS branches.)
- **Make CTest the single test definition:** `enable_testing()` + an `add_executable`
  + `add_test` per test. Link sets are now known (see current-state): `*_ids` standalone;
  `*_parity` link `loopy_dsp_core` + plugin `processor.cpp` + `sdk`(has `pluginfactory.cpp`)
  + `sdk_common`; `*_wrapper` additionally rely on `memorystream.cpp` in `sdk_common`.
  Then **migrate and delete the Darwin-gated vst3 block** (`run_native_tests.sh:105-320`)
  so there is one build definition, not two that drift.
- **New CI job `vst3-plugins-macos` on `macos-latest`** (a discrete named job, matching
  the repo's per-OS convention — PRs 2/3 add sibling jobs, NOT a matrix):
  `cmake -S packages/loopy_engine/vst3 -B build && cmake --build build &&
  ctest --test-dir build --output-on-failure`. First CI coverage of the plugins ever.
- **Load smoke (required, not optional):** add one tiny `dlopen`+`GetPluginFactory`
  CTest that loads an **assembled bundle** (the parity tests link `factory.cpp`
  in-process and never exercise the bundle/export table — this is the only check that
  proves the shipped `.vst3` actually loads). macOS form here; PRs 2/3 add
  `LoadLibrary`/`dlopen` per OS.
- **Acceptance (invisibility):** assembled macOS `.vst3` bundle **tree content** is
  unchanged vs pre-PR — `diff -r` excluding the code-signature and mtimes (a literal
  byte diff is fragile: ad-hoc `codesign -s -` cdhash is content-stable but mtimes are
  not); all `ctest` targets green in the new job.

#### PR 2 — Windows VST3 port *(part 13)*
- Remove/loosen the `if(NOT APPLE)` guard for `WIN32`.
- `LOOPY_VST3_MODULE_ENTRY = dllmain.cpp`; MODULE `SUFFIX ".vst3"`, `PREFIX ""`.
- Drop the `macexport.exp` link option on Windows (export via `SMTG_EXPORT_SYMBOL` =
  `__declspec(dllexport)`; verified in `pluginfactory.h`/`fplatform.h`).
- MSVC flags: `/std:c++17`, `_CRT_SECURE_NO_WARNINGS`. **No `/experimental:c11atomics`
  needed** — it already propagates to `loopy_dsp_core` via `add_subdirectory(../src)`
  (see current-state); do **not** re-add an `if(MSVC)` block here.
- `loopy_vst3_add_bundle()` Windows branch: assemble
  `<display>.vst3/Contents/x86_64-win/<display>.vst3` (the DLL); **no** codesign, **no**
  `Info.plist`/`PkgInfo`. `moduleinfo.json` is **deferred** (VST3 3.7+ out-of-process
  scan optimization; hosts fall back to in-process scan without it — not needed for
  loadability). Confirm `$<TARGET_FILE>` resolves to the DLL (not an import lib) before copy.
- CI: add a discrete **`vst3-plugins-windows`** job on `windows-latest` (MSVC generator,
  `cmake` + `ctest`) — sibling to `vst3-plugins-macos`, not a matrix row.
- Add the Windows `LoadLibrary`+`GetPluginFactory` load-smoke CTest.
- **Acceptance:** all 7 build on `windows-latest`; parity/ID + load-smoke CTests green.

#### PR 3 — Linux VST3 port *(part 14)*
- Enable the `else()` (Linux) branch.
- `LOOPY_VST3_MODULE_ENTRY = linuxmain.cpp`; MODULE `SUFFIX ".so"`, `PREFIX ""`;
  `-fvisibility=hidden` so only `SMTG_EXPORT_SYMBOL` factory symbols export;
  link `-ldl -lpthread`. (Static deps are `-fPIC` — `loopy_dsp_core` and
  `core_plugin_disabled_stub` both set `POSITION_INDEPENDENT_CODE ON` — so linking into
  a `.so` is fine.)
- `loopy_vst3_add_bundle()` Linux branch:
  `<display>.vst3/Contents/x86_64-linux/<display>.so`.
- CI: add a discrete **`vst3-plugins-linux`** job on `ubuntu-latest`
  (`apt-get install -y build-essential cmake`); `cmake` + `ctest`.
- Add the Linux `dlopen`+`GetPluginFactory` load-smoke CTest.
- **Acceptance:** all 7 build on `ubuntu-latest`; parity/ID + load-smoke CTests green.

### Why this order
PR 1 carries all the refactor risk while macOS output stays provably identical and,
for the first time, the plugins get a CI gate. PRs 2 and 3 are then thin per-OS
additions on a proven foundation — each just flips one entry TU, one suffix, one
bundle layout, and one CI matrix row.

---

## Task checklists

### PR 1 — foundation
- [ ] `vst3/CMakeLists.txt`: extract `LOOPY_VST3_MODULE_ENTRY`, per-OS `sdk_common`
      link, per-OS export-opt **variable**, per-OS `SUFFIX`, per-OS
      `loopy_vst3_add_bundle` body (macOS branch unchanged); add `memorystream.cpp` to
      `sdk_common`.
- [ ] `enable_testing()` + `add_executable`/`add_test` for all 16 tests with the known
      link sets (ids standalone; parity +`processor.cpp`+`sdk`; wrapper +`memorystream`).
- [ ] **Delete** the Darwin-gated vst3 block in `run_native_tests.sh:105-320` (CTest is
      now the single definition); leave the engine/midi/plugin-scan blocks intact.
- [ ] Load-smoke CTest (`dlopen`+`GetPluginFactory`) against an assembled bundle.
- [ ] `.github/workflows/main.yaml`: new discrete `vst3-plugins-macos` job (configure +
      build + `ctest --output-on-failure`).
- [ ] Verify assembled macOS bundle tree is unchanged (`diff -r` excluding signature/mtimes).
- [ ] Add VST3 terms (`dllmain`, `linuxmain`, `moduleinfo`, `pluginval`, `SMTG`, …) to
      `.github/cspell.json` — they appear in **this plan** and future `.md` docs
      (`spell-check` scans `**/*.md`).

### PR 2 — Windows
- [ ] Allow `WIN32` past the guard; `dllmain.cpp`; `SUFFIX ".vst3"`.
- [ ] MSVC flags (`/std:c++17`, `_CRT_SECURE_NO_WARNINGS`); drop `macexport.exp`. Do NOT
      re-add `/experimental:c11atomics` (propagates via `add_subdirectory`).
- [ ] Windows bundle branch: `Contents/x86_64-win/<name>.vst3`; confirm `$<TARGET_FILE>`
      is the DLL, not an import lib.
- [ ] New discrete `vst3-plugins-windows` job (`windows-latest`, MSVC).
- [ ] Windows `LoadLibrary`+`GetPluginFactory` load-smoke CTest.

### PR 3 — Linux
- [ ] Enable Linux branch; `linuxmain.cpp`; `SUFFIX ".so"`; `-fvisibility=hidden`,
      `-ldl -lpthread`.
- [ ] Linux bundle branch: `Contents/x86_64-linux/<name>.so`.
- [ ] New discrete `vst3-plugins-linux` job (`ubuntu-latest`, `build-essential cmake`).
- [ ] Linux `dlopen`+`GetPluginFactory` load-smoke CTest.

---

## Testing strategy

- **CTest parity/ID suite** (the core correctness gate): every `test_<fx>_parity`
  compares the plugin's processed output against the engine's `loopy_dsp_core` kernel
  for the same params; `test_vst3_<fx>_ids` pins the class/GUID contract; the two
  `*_wrapper` tests round-trip parameters via `MemoryStream`. Migrated from the
  Darwin-gated shell block into CTest and run in each per-OS `vst3-plugins-*` job.
- **Load smoke (required)**: a tiny `dlopen`/`LoadLibrary` + `GetPluginFactory` CTest
  against an **assembled bundle** — the only check that validates the export table and
  the per-OS `Contents/…` layout (the parity tests link `factory.cpp` in-process and
  never touch the bundle). Full DAW-host validation (pluginval / a real DAW) stays a
  manual/hardware follow-up.
- **macOS invisibility check** (PR 1): `diff -r` the assembled bundle tree vs pre-PR,
  excluding the code-signature blob and mtimes.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Two test-build definitions (CMake + shell) drift | PR 1 **deletes** the Darwin-gated `run_native_tests.sh:105-320` block — CTest is the single source. |
| `*_wrapper` tests fail to link (`MemoryStream`) | PR 1 adds `memorystream.cpp` to `sdk_common` (known now, not deferred). |
| Parity tests have other hidden macOS-only deps | Link sets are enumerated in current-state; surface any remainder in PR 1 on macOS before any new OS. |
| Windows single-file vs bundle-folder `.vst3` host-scan differences | Use the bundle-folder form (`Contents/x86_64-win/`), matching the VST3 3.x spec and macOS layout. |
| CTest is green but the shipped bundle won't load (bad export/layout) | The **required** load-smoke CTest exercises the assembled bundle + export table per OS. |
| MODULE `SUFFIX ".vst3"` on Windows produces an import-lib / wrong artifact | Verify `$<TARGET_FILE>` points at the DLL; set `PREFIX ""` and copy the DLL into the bundle explicitly. |

---

## Acceptance criteria
- [ ] `cmake -S packages/loopy_engine/vst3 && cmake --build && ctest` is **green on
      macOS, Windows, and Linux** in CI (discrete `vst3-plugins-{macos,windows,linux}` jobs).
- [ ] All 7 plugins produce a correctly-laid-out `.vst3` on each OS, and the required
      **load-smoke CTest** loads an assembled bundle on each OS.
- [ ] macOS bundle tree unchanged vs pre-PR-1 (invisibility; `diff -r` sans signature/mtimes).
- [ ] The 16 parity/ID tests run in CI (they run nowhere today) via a **single** CTest
      definition — the Darwin-gated shell block is removed.
- [ ] No change to DSP, GUIDs, `daw_export`, or the Flutter app.
- [ ] `flutter analyze` / existing jobs remain green; new jobs added to `main.yaml`;
      cspell passes with the new VST3 terms added.

## Out-of-scope follow-ups (tracked, not done here)
- Part 12: macOS notarization / Developer-ID signing.
- Parts 15–17: needs a brainstorm (installer/packaging, CLAP, pluginval gate, more DAWs).
- Release-artifact bundling of the built `.vst3`s.
