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

**Secondary gap this plan also closes:** the 16 parity/ID test files
(`vst3/**/test_vst3_*_ids.cpp`, `vst3/test/test_*_parity.cpp`) are **wired into no
build and run in no CI job** — the plugins have *zero* automated coverage today
(the `build-macos` CI job only builds the Flutter app via the podspec, never the
`vst3/` CMake project). Turning these into a CTest gate is the natural
**invisibility gate** for the cross-platform CMake refactor.

---

## Goals / Non-goals

**Goals**
- All 7 plugins build as loadable `.vst3` on **Windows** (MSVC) and **Linux** (gcc/clang).
- Correct per-OS `.vst3` bundle layout that hosts scan (`Contents/x86_64-win/*.vst3`,
  `Contents/x86_64-linux/*.so`).
- The parity/ID tests run in CI on **all three** OSes via CTest — the real correctness gate.
- **macOS build output and behavior are byte-for-byte unchanged** (invisibility).

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
- 16 orphaned tests: `vst3/{delay,drive,echo,filter,octaver,reverb,tremolo}/test_vst3_*_ids.cpp`,
  `vst3/{delay,reverb}/test_vst3_*_wrapper.cpp`, `vst3/test/test_*_parity.cpp`.
- CI: `.github/workflows/main.yaml` — `build-macos:148`, `build-windows:35`,
  `build-linux:48`, `native-tests:104` (runs `run_native_tests.sh`, which builds engine
  + midi + plugin-**scan** tests, **not** the vst3 parity tests).
- Windows MSVC gotcha (from `docs/PROGRESS.md`): `_Atomic`/`<stdatomic.h>` in the engine
  core needs `/experimental:c11atomics`; `loopy_dsp_core` reuse may inherit this.

---

## Technical approach

### PR split (3 PRs, each independently mergeable, in order)

Splitting keeps each PR reviewable and puts the risky refactor behind a green
macOS gate before any new-OS complexity lands.

#### PR 1 — Portable CMake foundation + CTest parity gate + macOS CI *(enabling; part-13 pre-work)*
Behavior-preserving on macOS. No new OS yet.
- Refactor `vst3/CMakeLists.txt` to isolate the OS-specific layer behind
  `if(APPLE)/elseif(WIN32)/else()` blocks **without changing macOS output**:
  - `set(LOOPY_VST3_MODULE_ENTRY <macmain|dllmain|linuxmain>.cpp)` fed into `sdk`.
  - `sdk_common` platform link: `-framework CoreFoundation` only `if(APPLE)`.
  - A `loopy_vst3_plugin_link_opts()` helper or per-OS variable so `macexport.exp`
    is applied **only** `if(APPLE)`.
  - Generalize `loopy_vst3_add_bundle()` with a per-OS body (macOS branch identical
    to today: `Contents/MacOS` + `Info.plist` + `PkgInfo` + `codesign`).
  - Per-OS MODULE `SUFFIX` (macOS `""`, Windows `.vst3`, Linux `.so`) — variablized now,
    exercised later.
- **Keep the `if(NOT APPLE) FATAL_ERROR`** for now (so PR 1 truly ships no behavior
  change) — PR 2/3 remove it. *(Alternatively drop the guard here but leave the
  Windows/Linux bundle branches stubbed with a clear `message(FATAL_ERROR "part 13/14")`.
  Chosen: keep the guard; smaller blast radius.)*
- **Wire the tests** into the CMake project: `enable_testing()`, an `add_executable`
  + `add_test` per `test_vst3_<fx>_ids` and `test_<fx>_parity` (+ the 2 wrapper tests),
  linking `loopy_dsp_core` + the plugin's TUs under test. Confirm each test's actual
  link deps during implementation.
- **New CI job `vst3-plugins` on `macos-latest`**: `cmake -S packages/loopy_engine/vst3
  -B build && cmake --build build && ctest --test-dir build --output-on-failure`.
  This is the first time the plugins are built/tested in CI at all.
- **Acceptance (invisibility):** the assembled macOS `.vst3` bundles are identical to
  pre-PR (diff the bundle tree); all parity/ID tests pass in the new CI job.

#### PR 2 — Windows VST3 port *(part 13)*
- Remove/loosen the `if(NOT APPLE)` guard for `WIN32`.
- `LOOPY_VST3_MODULE_ENTRY = dllmain.cpp`; MODULE `SUFFIX ".vst3"`, `PREFIX ""`.
- Drop the `macexport.exp` link option on Windows (export via `SMTG_EXPORT_SYMBOL`).
- MSVC flags: `/std:c++17`; `_CRT_SECURE_NO_WARNINGS`; add `/experimental:c11atomics`
  **iff** `loopy_dsp_core` pulls in `_Atomic` (verify at build — mirror
  `src/CMakeLists.txt`'s `if(MSVC)` block).
- `loopy_vst3_add_bundle()` Windows branch: assemble
  `<display>.vst3/Contents/x86_64-win/<display>.vst3` (the DLL) + optional
  `Contents/moduleinfo.json`; **no** codesign, **no** `Info.plist`/`PkgInfo`.
- CI: add `windows-latest` to the `vst3-plugins` job (matrix), configuring the MSVC
  generator and running `ctest`.
- **Acceptance:** all 7 build on `windows-latest`; parity/ID CTests green; a smoke
  note that at least one bundle loads (validator optional — see Risks).

#### PR 3 — Linux VST3 port *(part 14)*
- Enable the `else()` (Linux) branch.
- `LOOPY_VST3_MODULE_ENTRY = linuxmain.cpp`; MODULE `SUFFIX ".so"`, `PREFIX ""`;
  `-fvisibility=hidden` so only `SMTG_EXPORT_SYMBOL` factory symbols export;
  link `-ldl -lpthread`.
- `loopy_vst3_add_bundle()` Linux branch:
  `<display>.vst3/Contents/x86_64-linux/<display>.so`.
- CI: add `ubuntu-latest` to the `vst3-plugins` matrix (`apt-get install build-essential
  cmake`); run `ctest`.
- **Acceptance:** all 7 build on `ubuntu-latest`; parity/ID CTests green.

### Why this order
PR 1 carries all the refactor risk while macOS output stays provably identical and,
for the first time, the plugins get a CI gate. PRs 2 and 3 are then thin per-OS
additions on a proven foundation — each just flips one entry TU, one suffix, one
bundle layout, and one CI matrix row.

---

## Task checklists

### PR 1 — foundation
- [ ] `vst3/CMakeLists.txt`: extract `LOOPY_VST3_MODULE_ENTRY`, per-OS `sdk_common`
      link, per-OS export-opt, per-OS `SUFFIX`, per-OS `loopy_vst3_add_bundle` body
      (macOS branch unchanged).
- [ ] `enable_testing()` + `add_test` targets for all 16 test files; resolve each
      test's link deps (`loopy_dsp_core` + plugin TUs + `sdk`/`sdk_common` as needed).
- [ ] `.github/workflows/main.yaml`: new `vst3-plugins` job on `macos-latest`
      (cmake configure + build + `ctest --output-on-failure`).
- [ ] Verify assembled macOS bundles are byte-identical to pre-PR (document the diff cmd).
- [ ] Spell-check: add `moduleinfo`, `dllmain`, `linuxmain`, `pluginval` etc. to
      `.github/cspell.json` if referenced in comments/docs.

### PR 2 — Windows
- [ ] Allow `WIN32` past the guard; `dllmain.cpp`; `SUFFIX ".vst3"`.
- [ ] MSVC flags block (mirror `src/CMakeLists.txt`); drop `macexport.exp`.
- [ ] Windows bundle branch: `Contents/x86_64-win/<name>.vst3`.
- [ ] `vst3-plugins` matrix: add `windows-latest`.
- [ ] Confirm `loopy_dsp_core` builds under MSVC here (atomics flag if needed).

### PR 3 — Linux
- [ ] Enable Linux branch; `linuxmain.cpp`; `SUFFIX ".so"`; `-fvisibility=hidden`,
      `-ldl -lpthread`.
- [ ] Linux bundle branch: `Contents/x86_64-linux/<name>.so`.
- [ ] `vst3-plugins` matrix: add `ubuntu-latest` (+ `build-essential cmake`).

---

## Testing strategy

- **CTest parity/ID suite** (the core gate): every `test_<fx>_parity` compares the
  plugin's processed output against the engine's `loopy_dsp_core` kernel for the same
  params; `test_vst3_<fx>_ids` pins the class/GUID contract. These run on all 3 OSes
  in the `vst3-plugins` job.
- **Compile-load smoke** (optional, per Risks): run Steinberg's `moduleinfotool` or
  `pluginval` against one built bundle per OS if the vendored SDK / a free download
  makes it cheap; otherwise a `dlopen`/`LoadLibrary` + `GetPluginFactory` smoke test
  as a tiny CTest.
- **macOS invisibility check** (PR 1): assert the bundle tree + binary are unchanged.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `loopy_dsp_core` needs `/experimental:c11atomics` under MSVC and fails to build | Mirror the existing `if(MSVC)` block from `src/CMakeLists.txt`; verify in PR 2 first-build. |
| Parity tests have hidden macOS-only deps (paths, frameworks) | Surface them in PR 1 when wiring CTest on macOS, before any new OS. |
| Windows single-file vs bundle-folder `.vst3` host-scan differences | Use the bundle-folder form (`Contents/x86_64-win/`), matching the VST3 3.x spec and macOS layout. |
| No real host to prove the plugin loads in CI | Add a `GetPluginFactory` `dlopen`/`LoadLibrary` smoke CTest; full DAW validation stays a manual/hardware follow-up. |
| MODULE `SUFFIX ".vst3"` on Windows produces an import-lib / wrong artifact | Verify `$<TARGET_FILE>` points at the DLL; set `PREFIX ""` and copy the DLL into the bundle explicitly. |

---

## Acceptance criteria
- [ ] `cmake -S packages/loopy_engine/vst3 && cmake --build && ctest` is **green on
      macOS, Windows, and Linux** in CI.
- [ ] All 7 plugins produce a correctly-laid-out `.vst3` on each OS.
- [ ] macOS artifacts unchanged vs pre-PR-1 (invisibility).
- [ ] The 16 parity/ID tests run in CI (they run nowhere today).
- [ ] No change to DSP, GUIDs, `daw_export`, or the Flutter app.
- [ ] `flutter analyze` / existing jobs remain green; new CI job added to `main.yaml`.

## Out-of-scope follow-ups (tracked, not done here)
- Part 12: macOS notarization / Developer-ID signing.
- Parts 15–17: needs a brainstorm (installer/packaging, CLAP, pluginval gate, more DAWs).
- Release-artifact bundling of the built `.vst3`s.
