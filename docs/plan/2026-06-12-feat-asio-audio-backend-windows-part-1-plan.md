---
title: ASIO Backend Part 1 — Device-Backend Seam (Windows Multichannel I/O)
type: feat
date: 2026-06-12
brainstorm: docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md
part: 1 of 2
---

## 🔌 ASIO Backend Part 1 — The Device-Backend Seam

> **Part 1 of 2.** This PR introduces an internal device-backend seam in the C
> engine and moves today's miniaudio device lifecycle behind it — **with zero
> behavior change** — and grows the FFI structs to their final shape so Part 2
> can build on a stable foundation. No ASIO code lands here.
> Part 2 ([…-part-2-plan.md](docs/plan/2026-06-12-feat-asio-audio-backend-windows-part-2-plan.md))
> adds the real ASIO backend + Dart/UI feature stack.

## Dependencies

- **None.** This is the foundation PR and must merge first. Part 2 depends on it.

## Overview

`le_engine_start` ([engine.c:1753](packages/loopy_engine/src/engine.c)) bakes
miniaudio in directly: `ma_device_init` + `data_callback` → `le_engine_process`.
There is no seam to let a second backend (ASIO, in Part 2) own the device.

This PR introduces a thin internal **device-backend seam** (`le_device_backend`)
the engine drives, and moves the existing miniaudio device lifecycle behind it as
the first (and, in this PR, only) implementation. `le_engine_process`, the SPSC
command ring, the atomic snapshot, and the looper/lane/FX DSP are **reused
unchanged**. The public API structs grow the fields Part 2 needs
(`le_config.backend`/`asio_driver`, `le_device_info` channel counts,
`le_snapshot.active_backend`) so the FFI surface and bindings stabilize in this
PR rather than churning in Part 2.

**The acceptance gate is invisibility:** with `backend == WASAPI` (the default and
only path here), behavior is byte-identical to today on every platform, and all
existing native + Dart tests pass with no logic change.

This seam is **internal to the engine** and **distinct from the per-OS
`engine_platform.h` seam** (which exists for per-OS *capabilities* — CoreAudio
labels, JACK pinning — not swappable device backends; see its header comment at
[engine_platform.h:1](packages/loopy_engine/src/engine_platform.h)).

## Problem Statement

To add ASIO as a real backend (Part 2), the device lifecycle must be swappable.
Today it is hardwired into `le_engine_start`/`le_engine_stop`. Additionally, the
FFI structs cannot express a backend choice or a device's channel counts, both of
which the ASIO UI needs. Landing the seam + struct growth first, behavior-
preserving, isolates the highest-risk refactor (it touches the critical device
lifecycle path) from the novel ASIO code, so each PR is independently reviewable.

## Technical Approach

### The seam contract (`le_device_backend.h`, new)

A small internal interface — a struct of function pointers plus a negotiated-info
out-struct — that `le_engine_start`/`le_engine_stop` drive instead of calling
`ma_device_*` directly:

```c
/* Negotiated device parameters reported back by a backend after open. */
typedef struct le_device_open_result {
  int32_t sample_rate;
  int32_t input_channels;   /* clamped to LE_MAX_CHANNELS */
  int32_t output_channels;  /* clamped to LE_MAX_CHANNELS */
  int32_t buffer_frames;
  int32_t exclusive_active; /* miniaudio only; 0 for ASIO (Part 2) */
  int32_t active_backend;   /* le_audio_backend actually opened */
  char    device_name[256];
} le_device_open_result;

/* One device backend. The impl calls le_engine_process from its RT callback. */
typedef struct le_device_backend {
  int32_t (*open)(le_engine* e, const le_config* cfg, le_device_open_result* out);
  int32_t (*start)(le_engine* e);
  int32_t (*stop)(le_engine* e);   /* stop + fully release the device */
  void    (*close)(le_engine* e);
} le_device_backend;
```

### Implementation steps

**1a. `le_audio_backend` enum + `le_config` fields** —
[loopy_engine_api.h](packages/loopy_engine/src/loopy_engine_api.h):

```c
typedef enum le_audio_backend {
  LE_BACKEND_WASAPI = 0,  /* default: miniaudio's default backend (WASAPI/CoreAudio/ALSA) */
  LE_BACKEND_ASIO = 1,    /* opt-in Windows ASIO (Part 2; requires LOOPY_ENABLE_ASIO) */
} le_audio_backend;

typedef struct le_config {
  ...
  int32_t exclusive;
  int32_t backend;            /* le_audio_backend; 0 = default miniaudio path */
  char    asio_driver[256];   /* selected ASIO driver name (used in Part 2) */
} le_config;
```

**1b. `le_device_info` gains channel counts** — same header:

```c
typedef struct le_device_info {
  char id[256];
  char name[256];
  int32_t is_default;       /* 0/1 */
  int32_t input_channels;   /* 0 = unknown (WASAPI); ASIO probe fills it in Part 2 */
  int32_t output_channels;  /* 0 = unknown */
} le_device_info;
```

> **Explicit change site (do not miss — latent garbage-read bug):**
> `device_info_copy` ([engine.c:~1575](packages/loopy_engine/src/engine.c)) **must
> zero-initialize** `input_channels`/`output_channels` for every miniaudio device
> (WASAPI reports no per-device channel count here). Leaving them uninitialized
> would surface stack garbage as channel counts in Dart's `AudioDevice`. Add an
> assertion in the enumeration test that WASAPI-path devices report
> `input_channels == 0`.

**1c. `le_snapshot.active_backend`** — same header, `le_snapshot`:

```c
  int32_t exclusive_active;
  int32_t active_backend;   /* le_audio_backend actually running (negotiated). In
                             * Part 2, a requested-ASIO open that fell back to
                             * WASAPI reports WASAPI here. */
```

Add `_Atomic int32_t a_active_backend;` to `struct le_engine`
([engine_private.h:186](packages/loopy_engine/src/engine_private.h), beside
`a_exclusive_active`); initialize to `LE_BACKEND_WASAPI` (0) in the configure/reset
path; read out in `le_engine_get_snapshot` → `out->active_backend`. Publish it in
`le_engine_start` from `le_device_open_result.active_backend` (here, always
WASAPI).

**1d. Extract the miniaudio device lifecycle** into a backend impl.

- New `engine_miniaudio.c` + `engine_miniaudio.h` (compiled **unconditionally**,
  like the per-OS TUs): move the device-specific bodies of `le_engine_start` — the
  `ma_device_config` build, context init, pin/loopback resolution, the
  exclusive-mode fallback (`le_decide_share_fallback` stays where it is, called
  from here), `ma_device_init`/`ma_device_start`, `data_callback`,
  `notification_callback` — into `le_miniaudio_open/start/stop/close`, exposed as
  `extern const le_device_backend le_miniaudio_backend`. **`le_engine_process`,
  the looper, the ring, and the snapshot stay in `engine.c`.** Device-lifecycle
  ownership fields (`device_initialised`, `context_initialised`, `context`,
  `capture_id`, `playback_id`) stay in `struct le_engine` and are managed by the
  miniaudio impl.

**1e. `le_engine_start` becomes the backend dispatcher** —
[engine.c:1753](packages/loopy_engine/src/engine.c):

```c
const le_device_backend* be = le_select_backend(config->backend);  /* 1f */
le_device_open_result info;
int32_t r = be->open(engine, config, &info);
if (r != LE_OK) { return r; }
if (le_engine_configure(engine, info.sample_rate, info.input_channels,
                        info.output_channels, config->max_loop_frames) != LE_OK) {
  be->close(engine); return LE_ERR_INVALID;
}
/* publish negotiated info into the existing atomics + a_active_backend */
store_i32(&engine->a_active_backend, info.active_backend);
... /* a_buffer_frames, a_exclusive_active, device_name, excluded mask — as today */
if (be->start(engine) != LE_OK) { be->close(engine); return LE_ERR_DEVICE; }
engine->backend = be;   /* remember for stop()/destroy() */
```

`le_engine_stop`/`le_engine_destroy` call `engine->backend->stop`/`close` instead
of `ma_device_*` directly. The negotiated-info publication, the passthrough
default, the latency-state reset, and the excluded-input-mask computation all stay
in `le_engine_start` (above the seam), unchanged.

**1f. `le_select_backend(int32_t backend)`** in engine.c: returns
`&le_miniaudio_backend` for every input in this PR (the `backend`/`asio_driver`
fields are accepted and ignored — no ASIO backend exists yet). Part 2 adds the
`#if LOOPY_ENABLE_ASIO` branch returning `&le_asio_backend`. **The default build
must never reference any `le_asio_*` symbol** — the ASIO branch (and that symbol
reference) is wrapped in `#if LOOPY_ENABLE_ASIO`, guaranteed at link time, not
just runtime.

**CMake** — [CMakeLists.txt:8](packages/loopy_engine/src/CMakeLists.txt): add
`engine_miniaudio.c` to the unconditional `add_library` source list.

### Layer 2 — FFI bindings (regen)

Regenerate after the struct changes, per the repo gotcha
([PROGRESS.md](docs/PROGRESS.md)):

```sh
cd packages/loopy_engine
dart run ffigen --config ffigen.yaml
dart format lib/src/generated/loopy_engine_bindings.dart   # required: tall style
```

Verify the generated `le_config`/`le_device_info`/`le_snapshot` structs expose the
new fields and the diff is field-scoped (no whole-file churn). Run the loopy_engine
analyzer/tests right after regen.

### Layer 3 — minimal Dart plumbing for the new fields

The new struct fields must be threaded through the Dart models so the regenerated
bindings compile and equality stays complete — but **no UI/behavior change** (the
fields take inert defaults that reproduce today's behavior).

- **`AudioBackend` enum** — define **inline in**
  [engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart) (mirrors
  how `EngineResult` lives in `audio_engine.dart`; a two-value enum does not
  warrant its own file): `enum AudioBackend { wasapi, asio }` with `toNative()` /
  `fromNative(int)` (unknown → `wasapi`).
- **`EngineConfig`** — add `final AudioBackend backend` (default
  `AudioBackend.wasapi`) + `final String asioDriver` (default `''`); wire into the
  constructor, `writeTo` (`ptr.ref.backend = backend.toNative()`,
  `writeNativeString(ptr.ref.asio_driver, asioDriver)`), **hand-written**
  `==`/`hashCode`/`toString`.
- **`AudioDevice`** —
  [audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart): add
  `final int inputChannels` / `final int outputChannels` (default `0`); update the
  **hand-written** `==`/`hashCode`/`toString`; populate from `le_device_info` in
  the enumeration mapper ([native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart)).
- **`EngineSnapshot`** —
  [engine_snapshot.dart](packages/loopy_engine/lib/src/engine_snapshot.dart): add
  `final AudioBackend activeBackend` (default `AudioBackend.wasapi`) to the primary
  constructor, the `initial()` const constructor, `fromNative`
  (`activeBackend: AudioBackend.fromNative(native.active_backend)`), and the
  **hand-written** `==`/`hashAll([...])`/`toString` (this class is **not**
  Equatable — there is no `props`).
- **`MockAudioEngine`** —
  [mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart):
  snapshot reports `activeBackend == AudioBackend.wasapi` (the only path here).

> **Equality model (codebase fact):** the whole `loopy_engine` package
> (`EngineConfig`, `AudioDevice`, `EngineSnapshot`) uses **hand-written** equality
> members, not Equatable. Only `looper_repository` / `settings_repository` /
> presentation classes use Equatable `props`. Edit the hand-written members.

## Acceptance Criteria

### Functional
- [ ] With `backend == WASAPI` (the default and only path), behavior is
      byte-identical to today on Windows, macOS, and Linux.
- [ ] `le_engine_start`/`le_engine_stop`/`le_engine_destroy` drive the device
      exclusively through the `le_device_backend` seam; no direct `ma_device_*`
      call remains in `engine.c`'s lifecycle code (it lives in `engine_miniaudio.c`).
- [ ] `le_snapshot.active_backend` reports `WASAPI`; `le_device_info` channel
      counts are `0` for miniaudio devices.

### Non-Functional
- [ ] **No behavior change anywhere** — the exclusive-mode fallback, device
      pinning, loopback capture, notifications, and metering all work exactly as
      before (now from behind the seam).
- [ ] **FFI**: `le_config`/`le_device_info`/`le_snapshot` grow only the named
      fields; bindings regenerated with `dart format`; no unrelated binding churn.
- [ ] The default build links **no** ASIO symbol (none exist yet); `le_select_backend`
      always returns the miniaudio backend.

### Quality Gates
- [ ] **All existing native tests pass unchanged** (lifecycle, enumeration,
      `le_engine_process`, exclusive fallback) — the invisibility gate.
- [ ] New native tests: `test_select_backend_defaults_to_miniaudio`
      (`le_select_backend(WASAPI)` and `le_select_backend(ASIO)` both return the
      miniaudio backend in this build); struct zero-init smoke
      (`le_config.backend`/`asio_driver`, `le_snapshot.active_backend` default to
      0/WASAPI); enumeration asserts WASAPI devices report `input_channels == 0`.
- [ ] Dart tests: `AudioBackend` round-trip; `EngineConfig`/`AudioDevice`/
      `EngineSnapshot` new fields in equality + `fromNative`/`writeTo`.
- [ ] `flutter analyze` clean; app builds on Windows + macOS + Linux.

## Out of Scope (this PR)
- The ASIO backend itself, ASIO enumeration, the backend-selector UI, persistence
  of the backend choice, and auto-start threading — all in **Part 2**.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| The seam refactor regresses the working miniaudio path | Med | High | Behavior-preserving extraction; **all existing tests must pass unchanged** is the merge gate; `le_select_backend` test proves the default never depends on ASIO. |
| New `le_device_info` fields read as garbage on the WASAPI path | Med | Med | `device_info_copy` explicitly zero-inits them; enumeration test asserts `== 0`. |
| ffigen regen churns the whole bindings file | Med | Low | `dart format` per the repo gotcha; review the field-scoped diff. |

## Documentation Plan
- [docs/PROGRESS.md](docs/PROGRESS.md): record the device-backend seam + the FFI
  struct growth (note the fields are inert until Part 2).

## References

- Brainstorm: [2026-06-12-asio-audio-backend-windows-brainstorm-doc.md](docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md)
- Device open (to move behind the seam): [engine.c:1753](packages/loopy_engine/src/engine.c), `data_callback` [engine.c:1287](packages/loopy_engine/src/engine.c), `notification_callback` [engine.c:1656](packages/loopy_engine/src/engine.c), `device_info_copy` [engine.c:1575](packages/loopy_engine/src/engine.c)
- RT core to reuse unchanged: `le_engine_process` [engine.c:856](packages/loopy_engine/src/engine.c)
- FFI structs: `le_config` [loopy_engine_api.h:189](packages/loopy_engine/src/loopy_engine_api.h), `le_device_info` [loopy_engine_api.h:181](packages/loopy_engine/src/loopy_engine_api.h), `le_snapshot` [loopy_engine_api.h:273](packages/loopy_engine/src/loopy_engine_api.h)
- Engine struct: [engine_private.h:163](packages/loopy_engine/src/engine_private.h)
- Prior art (requested-vs-negotiated, per-OS seam): [2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md](docs/plan/2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md), [2026-06-12-refactor-per-os-engine-subdivision-plan.md](docs/plan/2026-06-12-refactor-per-os-engine-subdivision-plan.md)
- Dart models: [engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart), [engine_snapshot.dart](packages/loopy_engine/lib/src/engine_snapshot.dart), [audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart), [native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart), [mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart)
- ffigen regen gotcha: [PROGRESS.md](docs/PROGRESS.md)
