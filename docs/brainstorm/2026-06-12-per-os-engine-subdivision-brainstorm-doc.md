---
date: 2026-06-12
topic: per-os-engine-subdivision
---

# Per-OS Engine Subdivision

## What We're Building

Split the platform-specific C currently living inside the ~3,200-line
[`packages/loopy_engine/src/engine.c`](../../packages/loopy_engine/src/engine.c)
into **per-OS translation units** — `engine_linux.c`, `engine_apple.c`,
`engine_windows.c` — that each implement a small, fixed set of **seam functions**
(`le_platform_*`) the portable core calls at well-defined lifecycle points. After
the split, `engine.c` contains zero `#if defined(__APPLE__)/(__linux__)/(_WIN32)`
blocks for *behavior*; it just calls the seam, and exactly one per-OS TU provides
the real implementation (the others compile to empty objects on that platform).

This is deliberately **not** a generic backend vtable. The three OSes do not
implement "the same operation three ways" — they implement *different
capabilities* (CoreAudio channel labels on macOS; JACK port-pinning + PipeWire
quantum forcing on Linux; opt-in ASIO on Windows later). The seam models
lifecycle *hooks*, most of which are no-ops on most platforms, rather than a
polymorphic device abstraction.

## Why This Approach

Three real platform clusters already exist in `engine.c` and two more features are
queued (Windows ASIO, Linux PipeWire channel labels). The `#if` blocks are still
readable today (~9 sites), but they're about to grow, and the Linux JACK cluster
alone (`le_jack_pin_to_device`, `le_jack_rewire`, `le_jack_device_name`,
`le_trailing_int`, `le_pipewire_force_quantum`, the dlfcn typedefs, the backend
preference array) is ~250 lines of OS-only code interleaved with portable DSP.
Pulling each OS into its own TU keeps the audio core legible, lets a platform
owner work without scrolling past two other OSes, and gives Windows ASIO a place
to land that isn't "more `#if` in the hot file."

Alternatives considered and rejected:

- **Generic `ma_backend`-style vtable** — over-engineered. Forces a uniform
  interface onto capabilities that aren't uniform; you'd end up with structs full
  of `NULL` function pointers. YAGNI.
- **Per-capability TUs** (`engine_labels.c`, `engine_jack.c`) — finer-grained, but
  each file *still* needs internal `#if` for which OS it applies to, so it doesn't
  actually remove the platform conditionals — it just scatters them.
- **Single `engine_platform.c`** — smallest change, but keeps all three OSes'
  internal `#if` blocks in one file; doesn't separate the platforms from each
  other, which is the whole point before Windows lands.
- **Keep `#if` in `engine.c`** — fine *today*, but the next two features make the
  hot file worse, and we're choosing to pay the refactor now while the surface is
  small and freshly understood.

## The Seam Interface

A new header `engine_platform.h` declares the hooks; the portable core includes it
and calls them. Each per-OS TU implements **all** of them (trivial no-op bodies
where the platform doesn't care — this keeps the linker happy since the active
OS's TU is the only one providing symbols).

```c
/* engine_platform.h — lifecycle hooks the portable core calls; implemented
 * once per OS in engine_<os>.c. Most are no-ops on most platforms. */

/* Backend preference list passed to ma_context_init. Linux returns
 * {jack, pulseaudio, alsa}; macOS/Windows return (NULL, 0) = miniaudio default. */
void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count);

/* Called immediately before ma_context_init. Linux sets PIPEWIRE_QUANTUM +
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
```

Mapping to today's code (all currently in `engine.c`):

| Seam function | Linux TU body | Apple TU body | Windows TU body |
|---|---|---|---|
| `le_platform_backends` | `{jack,pulse,alsa}` array | `NULL,0` | `NULL,0` (until ASIO opt-in) |
| `le_platform_before_context_init` | `setenv(PIPEWIRE_QUANTUM)` + `le_pipewire_force_quantum(q)` | no-op | no-op |
| `le_platform_after_device_start` | `le_jack_pin_to_device` (+ `le_jack_rewire`/`le_jack_device_name`/`le_trailing_int` as file-local statics) | no-op | no-op |
| `le_platform_on_engine_teardown` | `le_pipewire_force_quantum(0)` | no-op | no-op |
| `le_platform_excluded_input_mask` | `return 0` | `le_macos_excluded_mask` (CoreAudio labels, `le_label_is_loopback`) | `return 0` |

The Linux-only helpers (`le_jack_rewire`, `le_jack_device_name`, `le_trailing_int`,
the `jack_*` dlfcn typedefs, `k_backends[]`) become **file-local statics inside
`engine_linux.c`** — they leave the core's namespace entirely.

## Structural Prerequisite: share `struct le_engine`

`le_platform_after_device_start` needs the engine struct (it touches
`engine->context.backend`, `engine->device.jack.*`, `engine->in/out_channels`,
and `store_i32(&engine->a_in_channels, …)`). Today `struct le_engine` is defined
**inside `engine.c`** ([line 186](../../packages/loopy_engine/src/engine.c#L186)),
and the existing `engine_internal.h` only declares functions, not the struct.

So the split requires moving the `struct le_engine` definition + a couple of
now-shared statics into a **private** header included by both `engine.c` and the
per-OS TUs. Options for where:

- Extend the existing `engine_internal.h` (already the "non-public surface"
  header) — simplest, but it's currently test-facing only; mixing the full struct
  in is a slight scope creep.
- A new `engine_private.h` dedicated to cross-TU internals (struct + shared
  helper decls), with `engine_internal.h` continuing to expose only the
  test-driver entry points.

**Leaning toward `engine_private.h`** to keep the test surface and the
implementation-internal surface distinct. Helpers to promote from `static` to
shared (declared in that header): `enumerate_devices`
([engine.c:1825](../../packages/loopy_engine/src/engine.c#L1825), used by
`le_jack_device_name`) and the atomic accessors `store_i32`/`load_i32`
([engine.c:344](../../packages/loopy_engine/src/engine.c#L344)).

## Build-System Implications

Each `engine_<os>.c` is wrapped whole in `#if defined(<that OS>)`, so on a
non-matching platform it's an **empty translation unit** (no symbols, no duplicate
definitions). That lets every build list all three unconditionally:

- **Linux / Windows (CMake)** —
  [`src/CMakeLists.txt`](../../packages/loopy_engine/src/CMakeLists.txt) adds
  `engine_linux.c engine_apple.c engine_windows.c` to the existing
  `add_library(loopy_engine SHARED …)`. On Linux only `engine_linux.c` has a
  body; the other two compile to nothing. (Same pattern that already silently
  works for `loop_clock.c`.)
- **macOS / iOS (CocoaPods)** — the podspec compiles via `Classes/*.c` forwarders
  that `#include "../../src/<file>.c"`. Today `macos/Classes/` has `engine.c`,
  `lockfree_ring.c`, `loop_clock.c`, `miniaudio_impl.c`. Add an
  `engine_apple.c` forwarder (and matching `ios/Classes/`). The Linux/Windows TUs
  are `#if`'d out on Apple, so they need **no** forwarder — the seam symbols the
  core calls are all provided by `engine_apple.c`. (If we prefer uniformity we can
  add empty forwarders for all three, but it's unnecessary.)
- **Device-free C test harness** — the `cc` line that builds
  `test/test_engine_core.c` already lists the engine sources; add the per-OS TUs
  so the seam symbols link. On the dev's OS exactly one provides real bodies; the
  tests don't exercise device paths, but the seam must resolve at link time. Keep
  the strict `-std=c11` note that already gates `setenv` via the `extern`
  declaration — that declaration moves into `engine_linux.c`.

No change to the FFI surface (`loopy_engine_api.h`), the Dart loader, or ffigen —
the seam is purely internal.

## Migration Strategy (incremental, tests green at each step)

1. **Carve the shared header.** Move `struct le_engine` + promote
   `enumerate_devices`/`store_i32`/`load_i32` into `engine_private.h`; `engine.c`
   includes it. No behavior change; rebuild + run native and Dart tests.
2. **Introduce the seam, still in `engine.c`.** Add `engine_platform.h`; define
   the 5 `le_platform_*` functions *in `engine.c`* wrapping the existing `#if`
   blocks; replace the inline conditionals at the call sites
   (`le_engine_start` ~L2285/L2312, `le_engine_stop` ~L2051, `le_engine_destroy`
   ~L2057, `le_compute_excluded_input_mask` ~L1976) with seam calls. Pure
   refactor; tests green.
3. **Extract Apple.** Move `le_macos_excluded_mask` + the macOS seam bodies into
   `engine_apple.c` (`#if defined(__APPLE__)`); add the CocoaPods forwarder.
   Verify the macOS build (the platform owner's box).
4. **Extract Linux.** Move the JACK cluster + quantum + backend preference + their
   seam bodies into `engine_linux.c` (`#if defined(__linux__)`); add to CMake.
   Verify on the Fedora/PipeWire/Clarett+ box (build, run, latency measure,
   channel count, monitoring) — the same end-to-end checks from this session.
5. **Stub Windows.** `engine_windows.c` (`#if defined(_WIN32)`) with all-no-op
   seam bodies + a `TODO` comment pointing at the ASIO opt-in plan. Compile-only
   CI job confirms it links.
6. **Confirm the core is clean.** `grep -nE '#if defined\((__APPLE__|__linux__|_WIN32)\)' engine.c` returns nothing (or only the `#include`-selection guard, if any remains).

Steps 1–2 are safe no-op refactors landable on their own; 3–5 are mechanical
moves, each independently verifiable on its platform.

## Key Decisions

- **Per-OS TUs + thin seam, not a vtable.** Capabilities differ per OS; model
  lifecycle hooks, not polymorphic device ops. Most hooks are no-ops on most
  platforms — that's expected and fine.
- **Move all current platform code in this effort** (macOS CoreAudio labels +
  the full Linux JACK/quantum cluster); Windows is an all-no-op stub ready for the
  future ASIO work.
- **Whole-file `#if` guard per TU** so every build can list all three sources
  unconditionally; the inactive ones are empty objects. Avoids per-platform source
  lists in CMake and the podspec.
- **Promote `struct le_engine` + a few statics into a private header**
  (`engine_private.h`) — the one real structural prerequisite, because the JACK
  pin hook reaches into engine state.
- **Five seam functions:** `le_platform_backends`,
  `le_platform_before_context_init`, `le_platform_after_device_start`,
  `le_platform_on_engine_teardown`, `le_platform_excluded_input_mask`.
- **FFI/Dart/ffigen untouched** — seam is internal-only.

## Open Questions

- **`engine_private.h` vs extending `engine_internal.h`** — keep the test surface
  and the cross-TU internal surface in separate headers, or consolidate? (Leaning
  separate.)
- **`engine_apple.c` vs `engine_macos.c` naming** — the file is gated on
  `__APPLE__`, so it also covers iOS; `engine_apple.c` is the more honest name even
  though the review said `engine_macos.c`. Confirm iOS is genuinely covered by the
  same CoreAudio-label path (iOS is out of scope for the current desktop plan, so
  its body may stay minimal).
- **Land as one PR or split** — steps 1–2 (no-op seam refactor) could merge ahead
  of 3–5 (per-platform extraction) to de-risk; or ship the whole subdivision in
  one reviewable PR. Decide at plan time.
- **Windows stub depth** — pure no-ops now, or scaffold the ASIO opt-in
  branch points (commented) so PR2 is a smaller diff? Lean pure no-op + TODO to
  avoid speculative structure.
