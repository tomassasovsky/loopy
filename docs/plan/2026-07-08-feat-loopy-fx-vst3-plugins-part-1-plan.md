---
title: "feat(dsp): shared DSP-core CMake split (part 1)"
type: feat
date: 2026-07-08
part: 1 of 12
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 1 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> pilot.** Shared design (D-LINK, D-SEAM) lives in the umbrella. This part is a
> **pure build-mechanics refactor — no DSP behavior change**; the pass/fail
> criterion is "the existing native test suite passes byte-identically before
> and after."

## Dependencies

None. This is the base of the stack.

## Overview

`engine_fx.c` currently compiles directly into the `loopy_engine` **SHARED**
library target
([CMakeLists.txt:14-60](../../packages/loopy_engine/src/CMakeLists.txt)), so
no second target (the future VST3 plugin builds in parts 2/3) can link it
without either duplicating the source file or extracting it. This part
extracts `engine_fx.c` (+ the `core/` headers it transitively needs —
`engine_fx.h`, `engine_private.h`) into a new `loopy_dsp_core` **STATIC**
library that `loopy_engine` links `PRIVATE`. Nothing about `loopy_engine`'s
public behavior, ABI, or output changes — this is source reorganization only.

**The link-seam gotcha (umbrella D-LINK):** `engine_fx.c`'s `LE_FX_PLUGIN`
vtable row (`fx_plugin_process`,
[engine_fx.c:909-917](../../packages/loopy_engine/src/core/engine_fx.c))
calls `le_plugin_slot_process` **unconditionally** — no `#ifdef` guard. Any
target linking `loopy_dsp_core` therefore has an unresolved symbol unless it
also links something that defines it. `loopy_engine` already gets this for
free (it links either the real host implementation, `host/slot.cpp`, when
`LOOPY_ENABLE_PLUGINS` is on, or the existing stub,
[`core/plugin_disabled.c:50`](../../packages/loopy_engine/src/core/plugin_disabled.c),
when it's off). Document this explicitly so parts 2/3 know to link the stub
too.

## Tasks

- [ ] Add `add_library(loopy_dsp_core STATIC core/engine_fx.c)` to
  [src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt), with
  `POSITION_INDEPENDENT_CODE ON` set explicitly (it will end up embedded in
  multiple `.so`/`.dll`/`.dylib` outputs — PIC is not guaranteed to propagate
  automatically from a STATIC target's consumers on every toolchain).
- [ ] Remove `core/engine_fx.c` from `loopy_engine`'s own `add_library(...)`
  source list; add `target_link_libraries(loopy_engine PRIVATE
  loopy_dsp_core)` instead.
- [ ] Confirm `loopy_dsp_core`'s only unresolved external symbols are libc/libm
  (`malloc`/`memcpy`/`sinf`/…) and `le_plugin_slot_process` — verify by
  building the static lib in isolation and inspecting undefined symbols
  (`nm -u` / `dumpbin /symbols`), documenting the expected list in a code
  comment so a future change that adds a new dependency is caught in review.
- [ ] Match `C_STANDARD 11` / `_Atomic` settings
  ([CMakeLists.txt:69-88](../../packages/loopy_engine/src/CMakeLists.txt))
  on the new `loopy_dsp_core` target — it must build under the exact same C
  dialect/atomics configuration `engine_fx.c` already assumes.
- [ ] No change to `LOOPY_ENABLE_PLUGINS` gating, the Windows/macOS/Linux
  per-OS build wiring (SPM/podspec/CMake), or any public header.

## File References

- [src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt)
- [core/engine_fx.c](../../packages/loopy_engine/src/core/engine_fx.c) (moved, not edited)
- [core/engine_fx.h](../../packages/loopy_engine/src/core/engine_fx.h) (unchanged)
- [core/engine_private.h](../../packages/loopy_engine/src/core/engine_private.h) (unchanged)
- [core/plugin_disabled.c](../../packages/loopy_engine/src/core/plugin_disabled.c) (unchanged; documented as the required link companion for parts 2/3)

## Acceptance Criteria

- [ ] `bash packages/loopy_engine/src/test/run_native_tests.sh` passes,
  identically to `master`, on macOS (and Linux/Windows CI if already green
  there) — this is the whole regression gate.
- [ ] `loopy_engine`'s compiled output (shared lib symbol table, size) is
  unchanged in substance — `engine_fx.c`'s object code now arrives via a
  static-lib link instead of a direct compile, not duplicated or altered.
- [ ] No new public symbols exported from `loopy_engine`; no ffigen
  regeneration needed (no ABI touched).
- [ ] `flutter build macos --debug -t lib/main_development.dart` (or the
  platform-appropriate equivalent) still succeeds.

## Out of Scope

Any VST3/plugin-authoring code — that starts in part 2. No change to
`LOOPY_ENABLE_PLUGINS` semantics or the existing third-party hosting stack.
</content>
