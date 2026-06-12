---
date: 2026-06-12
type: refactor
title: "refactor: subdivide engine.c into per-OS translation units"
status: ready
brainstorm: docs/brainstorm/2026-06-12-per-os-engine-subdivision-brainstorm-doc.md
branch: feat/windows-linux-native
---

# refactor: subdivide engine.c into per-OS translation units

## Summary

Split the platform-specific C currently interleaved inside the ~3,200-line
[`packages/loopy_engine/src/engine.c`](../../packages/loopy_engine/src/engine.c)
into **per-OS translation units** — `engine_linux.c`, `engine_apple.c`,
`engine_windows.c` — each implementing a small, fixed set of **seam functions**
(`le_platform_*`) that the portable core calls at well-defined lifecycle points.

After the split, `engine.c` contains zero `#if defined(__APPLE__|__linux__|_WIN32)`
blocks for *behavior*; it calls the seam, and exactly one per-OS TU provides the
real implementation. The other two are wrapped whole in `#if defined(<their OS>)`,
so they compile to **near-empty objects** on every other platform — every build
can list all three sources unconditionally.

> **C-standard note (new pattern, not an existing one).** A translation unit that
> is *entirely* `#if`'d out is an empty TU — undefined behavior in ISO C, and a
> warning under `-Wempty-translation-unit` / `-pedantic` (the plan's own native
> test command uses strict `clang -std=c11`). To stay valid on every platform,
> each per-OS TU places a single dummy declaration in its inactive `#else` branch:
> ```c
> #if defined(__linux__)
>   /* … real Linux bodies … */
> #else
>   typedef int loopy_engine_linux_tu_unused; /* keep the TU non-empty */
> #endif
> ```
> No `.c` in `src/` currently uses a whole-file platform guard (`loop_clock.c`,
> `lockfree_ring.c`, `miniaudio_impl.c` are all portable), so this is a **new**
> pattern for the repo — not a precedent to lean on.

This is **not** a generic backend vtable. The three OSes implement *different
capabilities* (CoreAudio channel labels on macOS; JACK port-pinning + PipeWire
quantum forcing on Linux; opt-in ASIO on Windows later), not "the same operation
three ways." The seam models lifecycle *hooks*, most of which are no-ops on most
platforms.

**No change to the FFI surface, the Dart loader, or ffigen** — the seam is purely
internal.

## Motivation

- Three real platform clusters already live in `engine.c`; two more features are
  queued (Windows ASIO, Linux PipeWire channel labels). The 9 current `#if` sites
  are readable today but about to grow.
- The Linux JACK cluster alone (`le_jack_pin_to_device`, `le_jack_rewire`,
  `le_jack_device_name`, `le_trailing_int`, `le_pipewire_force_quantum`, the
  `dlfcn` typedefs, the backend-preference array) is ~250 lines of OS-only code
  interleaved with portable DSP.
- Per-OS TUs keep the audio core legible, let a platform owner work without
  scrolling past two other OSes, and give Windows ASIO a place to land that isn't
  "more `#if` in the hot file."

Alternatives considered and rejected (from the brainstorm): generic `ma_backend`
vtable (over-engineered; structs full of `NULL` pointers — YAGNI), per-capability
TUs (each still needs internal `#if`), single `engine_platform.c` (keeps all three
OSes' `#if` in one file), keep `#if` in `engine.c` (fine today, worse after the
next two features).

## Stakeholders & impact

| Who | Impact |
|-----|--------|
| Engine maintainers | `engine.c` becomes platform-agnostic; each OS isolated in its own TU. No behavior change. |
| Windows owner (future) | `engine_windows.c` is the landing spot for ASIO opt-in — no hot-file churn. |
| macOS owner | CoreAudio label logic moves to `engine_apple.c`; podspec gets one forwarder. |
| Linux owner | JACK/PipeWire cluster moves to `engine_linux.c`; helpers become file-local. |
| Dart / app layer | **Zero impact** — FFI surface (`loopy_engine_api.h`), loader, ffigen untouched. |
| CI | No new jobs — existing `build-windows` / `build-linux` compile-guards cover the new TUs. |

## Research findings

### Current platform `#if` sites in `engine.c` (9 behavior sites)

| Lines | Cluster | Seam it becomes |
|-------|---------|-----------------|
| [32–38](../../packages/loopy_engine/src/engine.c#L32) | `__APPLE__` CoreAudio/CoreFoundation includes | move into `engine_apple.c` |
| [40–46](../../packages/loopy_engine/src/engine.c#L40) | `__linux__` `<dlfcn.h>` + `le_pipewire_force_quantum` fwd-decl | move into `engine_linux.c` |
| [1913–1971](../../packages/loopy_engine/src/engine.c#L1913) | `__APPLE__` `le_macos_input_device` + `le_macos_excluded_mask` | `le_platform_excluded_input_mask` (Apple body) |
| [1978–1984](../../packages/loopy_engine/src/engine.c#L1976) | `le_compute_excluded_input_mask` dispatch | replaced by `le_platform_excluded_input_mask` call |
| [2051–2053](../../packages/loopy_engine/src/engine.c#L2051) | `__linux__` quantum restore in `le_engine_destroy` | `le_platform_on_engine_teardown` |
| [2057–2241](../../packages/loopy_engine/src/engine.c#L2057) | `__linux__` JACK/quantum cluster (`le_pipewire_force_quantum`, `le_trailing_int`, `le_jack_device_name`, `le_jack_rewire`, `le_jack_pin_to_device`, dlfcn typedefs) | `le_platform_after_device_start` + file-local statics |
| [2285–2317](../../packages/loopy_engine/src/engine.c#L2285) | `__linux__` backend array + PIPEWIRE_QUANTUM/`setenv`/force-quantum | `le_platform_backends` + `le_platform_before_context_init` |
| [2402–2406](../../packages/loopy_engine/src/engine.c#L2402) | `__linux__` `le_jack_pin_to_device` call in `le_engine_start` | `le_platform_after_device_start` call |
| [2421–2425](../../packages/loopy_engine/src/engine.c#L2421) | `__linux__` quantum restore in `le_engine_stop` | `le_platform_on_engine_teardown` |

Verify clean at the end with:
```bash
grep -nE '#if defined\((__APPLE__|__linux__|_WIN32)\)' \
  packages/loopy_engine/src/engine.c
# expect: no output — both #include-selection guards (L32, L40) move out too
```

### Symbols that must become cross-TU shared (the structural prerequisite)

`le_platform_after_device_start` reaches into engine state, so these become
reachable from `engine_linux.c` via the **private header** `engine_private.h`:

| Symbol | Current location | How it's shared |
|--------|------------------|-----------|
| `struct le_engine` | [engine.c:186](../../packages/loopy_engine/src/engine.c#L186) | full struct definition **moves** into `engine_private.h` (JACK pin hook touches `engine->context.backend`, `engine->device.jack.*`, `engine->in/out_channels`, `engine->a_in/out_channels`) |
| `enumerate_devices` | [engine.c:1825](../../packages/loopy_engine/src/engine.c#L1825) | **promoted** to externally-linked: declared in `engine_private.h`, defined only in `engine.c` (used by `le_jack_device_name`) |
| `store_i32` / `load_i32` | [engine.c:341/344](../../packages/loopy_engine/src/engine.c#L341) | **moved as `static inline`** into `engine_private.h` (trivial `atomic_*_explicit(…, memory_order_relaxed)` wrappers — no need to add an externally-linked symbol; removed from `engine.c`) |

This leaves `enumerate_devices` as the **only** symbol promoted to external linkage
(the one genuine cross-TU function call), shrinking the shared-symbol surface and
removing any double-definition risk for the two atomic accessors.

### Build-system facts (confirmed)

- **CMake** ([src/CMakeLists.txt:8](../../packages/loopy_engine/src/CMakeLists.txt#L8))
  drives Linux + Windows via `add_library(loopy_engine SHARED …)`; `linux/` and
  `windows/` plugin CMakes `add_subdirectory` it. Add the three TUs to the source
  list. (The whole-file-`#if` empty-TU pattern is **new** here — no existing `.c`
  uses it; see the C-standard note in the Summary for the required dummy
  declaration in each inactive branch.)
- **macOS CocoaPods** — `macos/loopy_engine.podspec` uses
  `s.source_files = 'Classes/**/*'` (glob). Today `macos/Classes/` has `engine.c`,
  `lockfree_ring.c`, `loop_clock.c`, `miniaudio_impl.c` forwarders that
  `#include "../../src/<file>.c"`. Add **one** forwarder
  `macos/Classes/engine_apple.c`. The Linux/Windows TUs are `#if`'d out on Apple,
  so they need **no** forwarder (resolved open question).
- **No `ios/` directory exists** in this repo — only `macos/`. `engine_apple.c` is
  still the honest name (gated on `__APPLE__`, covers a future iOS target), but
  there is **no iOS forwarder to add now** (resolved open question).
- **Native test harness** — built by the documented `clang`/`cc` command in
  [test/test_engine_core.c:8–14](../../packages/loopy_engine/src/test/test_engine_core.c#L8),
  which lists the engine sources explicitly. **No Makefile / no CI job** builds it
  — it's a manual dev command. Its source list must gain the three per-OS TUs so
  the seam symbols resolve at link time. Keep the `-std=c11` strictness note (the
  `extern int setenv(...)` declaration moves into `engine_linux.c`).
- **CI compile-guards already exist** —
  [`.github/workflows/main.yaml`](../../.github/workflows/main.yaml) has
  `build-windows` (`flutter build windows --debug`) and `build-linux`
  (`flutter build linux --debug`) jobs that compile the engine through the plugin
  CMake. The Windows stub and Linux TU get link-checked there with **no new CI
  work**. There is **no macOS build job** — macOS verification is the platform
  owner's local box.

### Conventions observed in the codebase

- Forwarder TUs carry a header comment explaining the CocoaPods include indirection
  (see [macos/Classes/engine.c](../../packages/loopy_engine/macos/Classes/engine.c)).
  New forwarders should match.
- Source files open with a block comment describing the file's role (see
  `engine_internal.h`, `test_engine_core.c`). New TUs/headers follow suit.
- `engine_internal.h` is explicitly the **test-facing** non-public surface
  ("Not part of the FFI surface (excluded from ffigen)"). Keeping cross-TU
  internals in a separate `engine_private.h` preserves that boundary.

## The seam interface

New header `engine_platform.h` declares the hooks. The portable core includes it
and calls them. Each per-OS TU implements **all five** (trivial no-op bodies where
the platform doesn't care — keeps the linker happy since the active OS's TU is the
only one providing symbols).

```c
/* engine_platform.h — lifecycle hooks the portable core calls; implemented
 * once per OS in engine_<os>.c. Most are no-ops on most platforms. */
#ifndef LOOPY_ENGINE_PLATFORM_H
#define LOOPY_ENGINE_PLATFORM_H

#include <stdint.h>
#include "miniaudio.h"        /* ma_backend, ma_uint32 */
#include "engine_private.h"   /* le_engine, le_config */

/* Backend preference list passed to ma_context_init. Linux returns
 * {jack, pulseaudio, alsa}; macOS/Windows return (NULL, 0) = miniaudio default. */
void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count);

/* Called immediately before ma_context_init. Linux sets PIPEWIRE_QUANTUM and
 * forces the graph quantum via pw-metadata. No-op elsewhere. */
void le_platform_before_context_init(const le_config* config);

/* Called immediately after ma_device_start. Linux pins the JACK ports to the
 * selected device and clamps the published channel count. No-op elsewhere. */
void le_platform_after_device_start(le_engine* engine, const le_config* config);

/* Called from le_engine_stop and le_engine_destroy. Linux restores PipeWire's
 * dynamic quantum (force-quantum 0). No-op elsewhere. */
void le_platform_on_engine_teardown(void);

/* Excluded-input-channel mask from per-channel labels. macOS reads CoreAudio
 * labels; Windows (ASIO) and Linux return 0 for now. Replaces the existing
 * le_compute_excluded_input_mask dispatch. */
uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count);

#endif /* LOOPY_ENGINE_PLATFORM_H */
```

### Seam → implementation mapping

| Seam function | Linux TU body | Apple TU body | Windows TU body |
|---|---|---|---|
| `le_platform_backends` | `{jack,pulse,alsa}` array | `*out_list=NULL; *out_count=0` | `*out_list=NULL; *out_count=0` (until ASIO) |
| `le_platform_before_context_init` | `setenv(PIPEWIRE_QUANTUM)` + `le_pipewire_force_quantum(q)` | no-op | no-op |
| `le_platform_after_device_start` | `le_jack_pin_to_device` (+ rewire/device_name/trailing_int as file-local statics) | no-op | no-op |
| `le_platform_on_engine_teardown` | `le_pipewire_force_quantum(0)` | no-op | no-op |
| `le_platform_excluded_input_mask` | `return 0` | `le_macos_excluded_mask` (CoreAudio labels, `le_label_is_loopback`) | `return 0` |

The Linux-only helpers (`le_jack_rewire`, `le_jack_device_name`,
`le_trailing_int`, the `jack_*` dlfcn typedefs, `k_backends[]`) become
**file-local statics inside `engine_linux.c`** — they leave the core's namespace
entirely. `le_label_is_loopback` stays declared in `engine_internal.h` (it is
already test-facing) and is used by `engine_apple.c`.

> **Trade-off acknowledged:** keeping `le_label_is_loopback` in `engine_internal.h`
> means `engine_apple.c` includes three headers (`engine_platform.h` →
> `engine_private.h` transitively, plus `engine_internal.h`). Moving the helper into
> `engine_private.h` would cut that to one include, but it would blur the documented
> boundary that `engine_internal.h` is the *test-facing* surface. We keep the helper
> in `engine_internal.h` and accept the extra include — the boundary is the higher
> value, and only `engine_apple.c` pays it.

## Resolved open questions

| Question | Decision |
|----------|----------|
| `engine_private.h` vs extending `engine_internal.h` | **Separate header** `engine_private.h` — keeps the test surface (`engine_internal.h`) distinct from cross-TU internals. |
| `engine_apple.c` vs `engine_macos.c` | **`engine_apple.c`** — gated on `__APPLE__`, honest about covering a future iOS target. No iOS forwarder needed (no `ios/` dir exists). |
| Land as one PR or split | **Split: PR1 = steps 1–2** (no-op seam refactor, single-platform-verifiable), **PR2 = steps 3–5** (per-platform extraction). See "PR strategy". |
| Windows stub depth | **Pure no-ops + `TODO`** pointing at the ASIO opt-in plan — no speculative scaffolding. |

## Migration plan (tests green at each step)

### Step 1 — Carve the private header (`engine_private.h`)

**Files:** new `packages/loopy_engine/src/engine_private.h`; edit `engine.c`.

- [ ] Create `engine_private.h` with a header comment ("cross-TU internals — the
  full `struct le_engine` and shared helpers; NOT the FFI surface and NOT the
  test surface").
- [ ] Move `struct le_engine` ([engine.c:186](../../packages/loopy_engine/src/engine.c#L186))
  into it. **`engine_private.h` must be self-contained and idempotent** (header
  guard + its own includes) — other TUs include it, so it cannot rely on each
  `.c`'s inclusion order. It includes the headers the struct's field types need:
  `loopy_engine_api.h` (the opaque `le_engine` typedef + `le_config`,
  `LE_MAX_CHANNELS`), `miniaudio.h`, `lockfree_ring.h`, `loop_clock.h`. (`<stdatomic.h>`
  arrives transitively via `lockfree_ring.h` — `engine.c` does not include it
  directly — but include it explicitly here since the struct holds `atomic_*` fields.)
- [ ] Promote **only** `enumerate_devices` to external linkage: declare it in
  `engine_private.h`; remove `static` from its definition in `engine.c` (it stays
  **defined** in `engine.c`).
- [ ] Move `store_i32` / `load_i32` into `engine_private.h` as `static inline`
  (trivial atomic wrappers — `engine.c` picks them up via the include, so delete
  their `static` definitions from `engine.c`). Leave `load_f32` / `store_f32` /
  `bits_to_f32` alone — they have no cross-TU consumer.
- [ ] `#include "engine_private.h"` near the top of `engine.c`.
- [ ] **No behavior change.** Rebuild; run native + Dart tests (see Verification).

### Step 2 — Introduce the seam, bodies still in `engine.c`

**Files:** new `engine_platform.h`; edit `engine.c`.

- [ ] Add `engine_platform.h` (interface above).
- [ ] In `engine.c`, define the 5 `le_platform_*` functions wrapping the **existing**
  `#if` blocks verbatim (still guarded by `#if defined(__linux__)` / `__APPLE__`).
- [ ] Replace the inline conditionals at the call sites with seam calls:
  - `le_engine_start`: backend selection at [~L2285](../../packages/loopy_engine/src/engine.c#L2285)
    → `le_platform_backends(&p_backends, &backend_count)` + `le_platform_before_context_init(config)`
    (the env/quantum block) before `ma_context_init`.
  - `le_engine_start`: JACK pin at [~L2402](../../packages/loopy_engine/src/engine.c#L2402)
    → `le_platform_after_device_start(engine, config)` after `ma_device_start`.
  - `le_engine_stop`: quantum restore [~L2421](../../packages/loopy_engine/src/engine.c#L2421)
    → `le_platform_on_engine_teardown()`.
  - `le_engine_destroy`: quantum restore [~L2051](../../packages/loopy_engine/src/engine.c#L2051)
    → `le_platform_on_engine_teardown()`.
  - `le_compute_excluded_input_mask` [~L1976](../../packages/loopy_engine/src/engine.c#L1976)
    → delete it; call `le_platform_excluded_input_mask(capture_uid, neg_in)`
    directly at [~L2391](../../packages/loopy_engine/src/engine.c#L2391).
- [ ] `#include "engine_platform.h"` in `engine.c`.
- [ ] **Pure refactor; tests green.** This is the end of PR1.

> Steps 1–2 are a safe, single-platform-verifiable no-op refactor. Land as **PR1**.
>
> **Caveat:** "single-platform-verifiable" means *for the platform you build on*.
> On the Linux dev box the rewired Apple call site (`le_platform_excluded_input_mask`
> replacing `le_compute_excluded_input_mask` at engine.c:1976/2391) is inside an
> `#if defined(__APPLE__)` body and is **never compiled** — there is no macOS CI.
> Its compile coverage first happens when the macOS owner builds PR2/step 3. Keep
> the rewiring mechanical and minimal in PR1 to limit that exposure.

### Step 3 — Extract Apple (`engine_apple.c`)

**Files:** new `packages/loopy_engine/src/engine_apple.c`; new
`packages/loopy_engine/macos/Classes/engine_apple.c` (forwarder); edit `engine.c`
(remove the now-moved Apple bodies).

- [ ] Create `engine_apple.c`, wrapped whole in `#if defined(__APPLE__)` … `#else`
  `typedef int loopy_engine_apple_tu_unused;` `#endif` (non-empty TU on every
  platform — see the C-standard note in the Summary). Header comment describing
  the file's role.
- [ ] Move the CoreAudio/CoreFoundation includes ([L32–38](../../packages/loopy_engine/src/engine.c#L32)),
  `le_macos_input_device`, and `le_macos_excluded_mask`
  ([L1913–1971](../../packages/loopy_engine/src/engine.c#L1913)) into it as
  file-local statics.
- [ ] Implement all 5 seam functions: `le_platform_excluded_input_mask` →
  `le_macos_excluded_mask`; the other four are no-ops.
- [ ] `#include "engine_platform.h"` and `"engine_internal.h"` (for
  `le_label_is_loopback`). `engine_private.h` arrives transitively via
  `engine_platform.h`, so a direct include is optional. Remove the corresponding
  bodies from `engine.c`.
- [ ] **Confirm `le_label_is_loopback` stays non-`static` in `engine.c`** (it is
  today — `engine.c:1747`, declared in `engine_internal.h:39`). `engine_apple.c`
  links to it across TUs, so a stray `static` here would surface as an
  undefined-symbol error on the first macOS build.
- [ ] Add forwarder `macos/Classes/engine_apple.c`:
  `#include "../../src/engine_apple.c"` with the standard CocoaPods comment.
  (`s.source_files = 'Classes/**/*'` picks it up automatically.)
- [ ] **Verify the macOS build** on the platform owner's box (build + loopback
  exclusion behavior unchanged).

### Step 4 — Extract Linux (`engine_linux.c`)

**Files:** new `packages/loopy_engine/src/engine_linux.c`; edit `engine.c`
(remove moved Linux bodies), `src/CMakeLists.txt`.

- [ ] Create `engine_linux.c`, wrapped whole in `#if defined(__linux__)` … `#else`
  `typedef int loopy_engine_linux_tu_unused;` `#endif` (non-empty TU on every
  platform — see the C-standard note in the Summary). Header comment.
- [ ] Move into it as file-local statics: `<dlfcn.h>` include, the `extern int
  setenv(...)` declaration, `le_pipewire_force_quantum`, `le_trailing_int`,
  `le_jack_device_name`, `le_jack_rewire`, `le_jack_pin_to_device`, the `jack_*`
  dlfcn typedefs, `LE_JACK_INPUT/OUTPUT` macros, and `k_backends[]`.
- [ ] Implement all 5 seam functions:
  - `le_platform_backends` → publish `k_backends` (count 3).
  - `le_platform_before_context_init` → `setenv("PIPEWIRE_QUANTUM", …)` +
    `le_pipewire_force_quantum(q_frames)` (the [L2300–2313](../../packages/loopy_engine/src/engine.c#L2300) block).
  - `le_platform_after_device_start` → `le_jack_pin_to_device(engine, config)`.
  - `le_platform_on_engine_teardown` → `le_pipewire_force_quantum(0)`.
  - `le_platform_excluded_input_mask` → `return 0`.
- [ ] `#include "engine_platform.h"`, `"engine_private.h"` (for `struct le_engine`,
  `enumerate_devices`, `store_i32`). Remove the moved bodies from `engine.c`.
- [ ] **Update the native test build command now, not in step 6** — but only with
  the TUs that already exist. The `le_platform_*` symbols leave `engine.c` in this
  step, so the manual link command in
  [test/test_engine_core.c:8–14](../../packages/loopy_engine/src/test/test_engine_core.c#L8)
  must already list `engine_linux.c engine_apple.c` (both created by step 3/4) or
  the native suite fails to link from here onward. `engine_windows.c` is added to
  the command in step 5 when it exists.
  (On the Linux dev box `engine_apple.c` links as a dummy TU — harmless; only
  `engine_linux.c` actually provides the seam symbols there.)
- [ ] **Add a Linux build-command variant to the file comment.** The existing
  command at [test/test_engine_core.c:8–14](../../packages/loopy_engine/src/test/test_engine_core.c#L8)
  is explicitly `Build & run (macOS):` and hardcodes `-framework CoreAudio
  -framework AudioToolbox -framework AudioUnit -framework CoreFoundation` — which
  do not exist on Linux. Since this refactor is verified on the Fedora dev box,
  document **both** forms: a `Build & run (Linux):` variant that lists the three
  TUs and drops the macOS frameworks (`-lpthread -lm` only), plus the existing
  macOS form (now also listing the three TUs + its frameworks). Do not leave a
  single command that mixes Linux sources with macOS frameworks.
- [ ] **Defer the CMake source-list edit to step 5.** `flutter build linux`
  configures CMake against files that must exist on disk, and `engine_windows.c`
  is not created until step 5. Adding all three TUs to
  [`add_library(loopy_engine SHARED …)`](../../packages/loopy_engine/src/CMakeLists.txt#L8)
  in one commit *after* step 5 avoids an intermediate state where CMake references
  a not-yet-created file.
- [ ] **Verify on the Fedora / PipeWire / Clarett+ box** — the same end-to-end
  checks from the prior session: build, run, loopback latency measure, channel
  count, monitoring/routing.

### Step 5 — Stub Windows (`engine_windows.c`)

**Files:** new `packages/loopy_engine/src/engine_windows.c`; edit
`src/CMakeLists.txt`; edit `src/test/test_engine_core.c`.

- [ ] Create `engine_windows.c`, wrapped whole in `#if defined(_WIN32)` … `#else`
  `typedef int loopy_engine_windows_tu_unused;` `#endif` (non-empty TU on every
  platform — see the C-standard note in the Summary).
- [ ] All-no-op seam bodies (`le_platform_backends` → `NULL, 0`; the rest empty;
  `le_platform_excluded_input_mask` → `return 0`).
- [ ] `TODO` comment pointing at the future ASIO opt-in plan
  ([2026-06-11-windows-linux-native](../../docs/brainstorm/2026-06-11-windows-linux-native-brainstorm-doc.md)
  / its plan).
- [ ] Now that all three TUs exist on disk, add
  `engine_linux.c engine_apple.c engine_windows.c` to
  [`add_library(loopy_engine SHARED …)`](../../packages/loopy_engine/src/CMakeLists.txt#L8)
  in a single commit (deferred from step 4 to avoid referencing a missing file).
- [ ] Add `engine_windows.c` to the native test build command in
  [test/test_engine_core.c:8–14](../../packages/loopy_engine/src/test/test_engine_core.c#L8),
  completing the three-TU source list begun in step 4.
- [ ] Existing `build-windows` CI compile-guard confirms it links — no new CI.

### Step 6 — Confirm the core is clean

- [ ] Run the `grep` from Research findings against `engine.c`; **expect no
  output** — both `#include`-selection guards (engine.c:32, :40) move out entirely
  to `engine_apple.c` / `engine_linux.c`, so there is no behavior `#if` *and* no
  include-selection guard left to hedge for.
- [ ] (The native test build command was already completed across steps 4–5 — no
  test-command work remains here.)

## File inventory

| Path | Action |
|------|--------|
| `packages/loopy_engine/src/engine_private.h` | **new** — `struct le_engine` (moved) + `enumerate_devices` decl (defined in `engine.c`) + `store_i32`/`load_i32` `static inline` definitions |
| `packages/loopy_engine/src/engine_platform.h` | **new** — the 5-function seam interface |
| `packages/loopy_engine/src/engine_linux.c` | **new** — JACK/PipeWire cluster + Linux seam bodies (`#if __linux__`) |
| `packages/loopy_engine/src/engine_apple.c` | **new** — CoreAudio labels + Apple seam bodies (`#if __APPLE__`) |
| `packages/loopy_engine/src/engine_windows.c` | **new** — all-no-op stub + ASIO TODO (`#if _WIN32`) |
| `packages/loopy_engine/macos/Classes/engine_apple.c` | **new** — CocoaPods forwarder |
| `packages/loopy_engine/src/engine.c` | **edit** — remove platform `#if`; call the seam; un-`static` 3 helpers |
| `packages/loopy_engine/src/CMakeLists.txt` | **edit** — add the 3 TUs to the library sources |
| `packages/loopy_engine/src/test/test_engine_core.c` | **edit** — add the 3 TUs to the documented build command |

## PR strategy

Split to de-risk:

- **PR1 — steps 1–2** (`refactor: introduce engine platform seam`). No-op:
  private header + seam, bodies still in `engine.c`. Verifiable on a single
  platform; zero behavior change. Smallest reviewable unit.
- **PR2 — steps 3–6** (`refactor: subdivide engine.c into per-OS TUs`).
  Mechanical moves into `engine_apple.c` / `engine_linux.c` / `engine_windows.c`,
  CMake + podspec forwarder + test-command + clean-core grep. Each extraction is
  independently verifiable on its platform.

Both PRs target `feat/windows-linux-native` (current branch) or `master` per repo
convention.

## Verification

Run at the end of **every** step (1–6); the refactor must stay green throughout.

### Native core tests (dev box)
```bash
cd packages/loopy_engine
clang -std=c11 -I src -I src/miniaudio \
  src/test/test_engine_core.c src/engine.c src/lockfree_ring.c \
  src/loop_clock.c src/miniaudio_impl.c \
  $EXTRA_TUS \          # src/engine_linux.c src/engine_apple.c added in step 4; src/engine_windows.c in step 5
  -lpthread -lm -o /tmp/loopy_core_tests   # + CoreAudio frameworks on macOS
/tmp/loopy_core_tests
# expect: all pass, 0 failures
```

### Dart unit tests
```bash
cd packages/loopy_engine && flutter test
# engine_config_test, engine_snapshot_test, loopback_info_test, track_effect_test, … all green
```

### Compile guards (mirror CI)
```bash
flutter build linux   --debug --target lib/main_development.dart   # exercises engine_linux.c body
flutter build windows --debug --target lib/main_development.dart   # exercises engine_windows.c stub (on Windows / CI)
```

### Linux end-to-end (Fedora / PipeWire / Clarett+ box, after step 4)
- [ ] App launches; device selection works.
- [ ] Loopback latency measurement completes and reports a sane round-trip.
- [ ] Multichannel capture channel count matches the selected interface (JACK pin).
- [ ] Monitoring / dual-route routing behaves as before.
- [ ] `pw-metadata -n settings 0 clock.force-quantum` is restored to dynamic after
  stop/destroy.

### macOS (platform owner, after step 3)
- [ ] App builds via CocoaPods with the new `engine_apple.c` forwarder.
- [ ] Loopback-labelled capture channels are still excluded (CoreAudio labels).

### Core-is-clean gate (step 6)
```bash
grep -nE '#if defined\((__APPLE__|__linux__|_WIN32)\)' \
  packages/loopy_engine/src/engine.c   # expect: no output
```

## Acceptance criteria

- [ ] `engine.c` has **zero** behavior `#if defined(__APPLE__|__linux__|_WIN32)`
  sites (clean-core grep passes).
- [ ] Five `le_platform_*` seam functions defined exactly once per OS; each per-OS
  TU implements **all five** (no-ops where N/A).
- [ ] Each `engine_<os>.c` is wrapped whole in its OS guard → empty object on
  other platforms; all builds list all three sources unconditionally.
- [ ] `struct le_engine` definition + `store_i32`/`load_i32` (`static inline`) live
  in `engine_private.h`; `enumerate_devices` is declared there and defined once in
  `engine.c`; `engine_internal.h` stays test-only.
- [ ] Each per-OS TU is **non-empty on every platform** (real bodies under its OS
  guard; a dummy `typedef` in the `#else`) — no `-Wempty-translation-unit`.
- [ ] CMake builds the 3 TUs; macOS podspec picks up `engine_apple.c` via the
  `Classes/**/*` glob; the native test command lists the 3 TUs.
- [ ] FFI surface (`loopy_engine_api.h`), Dart loader, and ffigen output unchanged
  (no regen needed).
- [ ] Native tests, Dart tests, and `flutter build linux`/`windows` all green.
- [ ] Linux end-to-end checks pass on the Clarett+ box; macOS loopback exclusion
  verified by the platform owner.
- [ ] Landed as PR1 (seam, no-op) + PR2 (extraction).

## Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| `struct le_engine` field-type includes missing in `engine_private.h` → compile errors | Mirror the includes already at the top of `engine.c`; build after step 1 before touching anything else. |
| `enumerate_devices` defined twice (un-`static` + header) | Declare in header, **define** only in `engine.c`; do not also define in a TU. `store_i32`/`load_i32` are `static inline` in the header (no external symbol → no double-definition risk). |
| Empty-TU pattern (fully `#if`'d-out TU is UB in ISO C / warns under `-Wempty-translation-unit`, and the native test command uses strict `-std=c11`) | Each per-OS TU adds a single dummy declaration in its inactive `#else` branch (`typedef int loopy_engine_<os>_tu_unused;`) so it is never a genuinely empty TU. This is a **new** pattern — `loop_clock.c` is *not* precedent (it has no platform guard). |
| macOS not buildable locally (no `ios/`, Linux dev box) | macOS step (3) gated behind the platform owner's verification; CI has no macOS job, so don't claim macOS-green without the owner. |
| `le_label_is_loopback` visibility from `engine_apple.c` | It's declared in `engine_internal.h` (test-facing) and stays defined in `engine.c`; `engine_apple.c` includes that header. |
| Quantum/JACK behavior subtly changes during the move | Step 2 wraps existing blocks verbatim (no edits); steps 3–5 are cut/paste only. Linux end-to-end checks catch regressions. |

## Out of scope

- Windows ASIO implementation (only the no-op stub + TODO lands here).
- Linux PipeWire channel labels (the Linux `le_platform_excluded_input_mask`
  returns 0 for now).
- Any FFI / Dart / ffigen change.
- A generic backend vtable (explicitly rejected).
