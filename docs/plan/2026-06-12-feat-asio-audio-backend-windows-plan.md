---
title: ASIO Audio Backend for Windows Multichannel I/O
type: feat
date: 2026-06-12
brainstorm: docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md
---

## 🎚️ ASIO Audio Backend — Full Multichannel I/O on Windows

> **Note:** This plan has been split into parts. See the `-part-N` files in this
> directory:
> - [Part 1 — Device-Backend Seam](docs/plan/2026-06-12-feat-asio-audio-backend-windows-part-1-plan.md)
>   (behavior-preserving seam refactor + FFI struct growth; ships green on its own)
> - [Part 2 — ASIO Backend + Backend-Selector UI](docs/plan/2026-06-12-feat-asio-audio-backend-windows-part-2-plan.md)
>   (the real ASIO backend + Dart/UI stack; depends on Part 1)
>
> The split-part plans also fold in the technical-review fixes (ASIO global-state
> re-entrancy contract, hand-written-equality corrections, scope trims). This file
> is retained as the consolidated reference.

## Overview

Loopy on Windows sees only **2 channels** of a pro multichannel interface because
the Focusrite (18-in / 20-out class) driver publishes only its first analogue
pair to WASAPI. Inputs 3–18 and outputs 3–20 exist **only** inside the device's
**ASIO** driver. WASAPI — shared or exclusive — cannot surface channels Windows
never publishes (diagnosed, not assumed: a `ma_context_get_device_info` probe
reported `max ch: shared=2 exclusive=2` for every direction).

This plan adds a **real ASIO capture/playback backend**: load the ASIO driver,
create its buffers, run its real-time `bufferSwitch` callback, and feed the
**existing** `le_engine_process` DSP core at the driver's full channel count. It
is built behind a **device-backend seam** in the C engine so miniaudio (WASAPI/
CoreAudio/ALSA) and ASIO are two interchangeable implementations of one internal
contract; everything above the device layer — the SPSC command ring, the atomic
snapshot, and the looper/lane/FX DSP — is reused **unchanged**.

ASIO stays **opt-in** behind the existing `LOOPY_ENABLE_ASIO` CMake flag (OFF by
default) with a **user-supplied, non-vendored** GPLv3 Steinberg ASIO SDK. The
default build, macOS, and Linux are **byte-for-byte unaffected**. When ASIO is
not built, no driver is installed/selected, or ASIO init fails, the engine
**falls back to the miniaudio (WASAPI) backend** — exactly today's behavior — and
the **negotiated backend is reported back through the snapshot** so the UI shows
reality, not just intent.

This is the natural successor to the just-shipped WASAPI exclusive mode
([2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md](docs/plan/2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md)),
which gives low latency on the 2 channels WASAPI exposes but cannot create the
others. ASIO is the only Windows API that exposes the complete device.

## Problem Statement

`le_engine_start` ([engine.c:1753](packages/loopy_engine/src/engine.c)) bakes
miniaudio in directly: `ma_device_init` + `data_callback` →
`le_engine_process`. There is no seam to let a second backend own the device.
Concretely:

- The only device path is miniaudio's WASAPI/DirectSound, capped at the 2
  channels Focusrite's driver publishes.
- `le_device_info` ([loopy_engine_api.h:181](packages/loopy_engine/src/loopy_engine_api.h))
  is `{id, name, is_default}` — **no channel counts**, so the UI cannot show
  "18 in / 20 out".
- `le_config` has no backend selector; `le_snapshot` has no notion of which
  backend is actually running.

Pro audio on Windows runs on ASIO precisely because WASAPI does not aggregate pro
interfaces the way macOS CoreAudio does (which is why Loopy already delivers full
multichannel on macOS). This is the fundamental Windows reality.

## Decisions Locked (with the user)

| Decision | Choice |
|----------|--------|
| Pursue ASIO as a real backend | **Yes** — accept the large effort + GPLv3 opt-in / user-supplied SDK model |
| Bridge architecture | **Device-backend seam in the C engine** (Approach A): miniaudio and ASIO are two implementations, both feeding the *same* `le_engine_process`; `engine.c` stays clean |
| ASIO selection UX | **Backend selector + ASIO driver picker**: a top-level "Audio backend: WASAPI / ASIO"; choosing ASIO swaps the two device pickers for one "ASIO driver" picker that drives all I/O |
| Buffer / sample rate | **App maps to ASIO-allowed sizes**: derive buffer chips from `ASIOGetBufferSize` (min/max/preferred/granularity); request sample rate via `ASIOCanSampleRate`/`ASIOSetSampleRate` |
| First deliverable | **Core end-to-end first**: seam + ASIO duplex open at full channel count + backend/driver/buffer selection + channel counts in the UI + existing looper/DSP reused + WASAPI fallback. Polish deferred. |

### Decisions made in this plan (open questions from the brainstorm, resolved)

| Open question | Resolution |
|---------------|------------|
| **OQ1** — `le_config` backend representation | A dedicated `int32_t backend` enum field + `char asio_driver[256]` name string (ASIO drivers are not WASAPI device ids). |
| **OQ2** — channel-count FFI shape (probe vs post-open) | **Both.** Add `input_channels`/`output_channels` to `le_device_info`, populated by a cheap per-driver probe (`ASIOInit`+`ASIOGetChannels`+`ASIOExit`) during ASIO enumeration, so the picker shows "18 in / 20 out" **before** open. The post-open snapshot still carries the authoritative negotiated counts. |
| **OQ3** — active-backend truth | A new `int32_t active_backend` snapshot field, mirroring `exclusive_active`'s requested-vs-negotiated pattern. A requested-ASIO open that falls back to WASAPI reports `active_backend = WASAPI`. |
| **OQ4** — routing persistence scope | **Not** backend-scoped in v1. Channel index 0 is index 0 regardless of backend; switching down to WASAPI leaves lanes routed to inputs ≥2 / outputs ≥2 recording silence / playing nowhere (already the documented behavior). Surface it, do not silently drop. |
| **OQ5** — ASIO driver as a "pinned device" for the connectivity banner | A selected ASIO driver **counts as pinned** for `_detectConnectivity`, so a driver loss can raise the banner (reset/hot-swap signaling itself is deferred; `device_present` is still set correctly). |

## Architecture: the device-backend seam (Approach A)

```mermaid
flowchart TD
    start["le_engine_start(config)"] -->|picks backend from config.backend| seam
    seam["device backend seam<br/>(le_device_backend.h)<br/>open / start / stop / close / enumerate<br/>→ negotiated info"]
    seam --> ma["miniaudio backend<br/>(engine_miniaudio.c — today's engine.c device code)<br/>WASAPI / CoreAudio / ALSA"]
    seam --> asio["ASIO backend<br/>(win_asio_device.cpp, #if LOOPY_ENABLE_ASIO,<br/>C++ → extern \"C\")"]
    ma -->|data_callback| proc
    asio -->|bufferSwitch → de-interleave/convert| proc
    proc["le_engine_process(engine,<br/>out_f32_interleaved, in_f32_interleaved, frames)<br/>★ UNCHANGED ★"]
    proc -.->|interleave/convert out| asio
    proc --> ring["SPSC ring · atomic snapshot · looper/lane/FX DSP<br/>★ all reused unchanged ★"]
```

**Both backends converge on the existing `le_engine_process` with interleaved f32
duplex buffers.** The seam is **internal to the engine** and is **distinct from
the per-OS `engine_platform.h` seam** (which exists for per-OS *capabilities* —
CoreAudio labels, JACK pinning — not for swappable device backends; see its
header comment at [engine_platform.h:1](packages/loopy_engine/src/engine_platform.h)).

### The seam contract (`le_device_backend.h`, new)

A thin internal interface — a small struct of function pointers plus a negotiated-
info out-struct — that `le_engine_start`/`le_engine_stop` drive instead of calling
`ma_device_*` directly:

```c
/* Negotiated device parameters reported back by a backend after open. */
typedef struct le_device_open_result {
  int32_t sample_rate;
  int32_t input_channels;   /* clamped to LE_MAX_CHANNELS */
  int32_t output_channels;  /* clamped to LE_MAX_CHANNELS */
  int32_t buffer_frames;
  int32_t exclusive_active; /* miniaudio only; 0 for ASIO */
  int32_t active_backend;   /* le_audio_backend actually opened */
  char    device_name[256];
} le_device_open_result;

/* One device backend. Both impls call le_engine_process from their RT callback. */
typedef struct le_device_backend {
  int32_t (*open)(le_engine* e, const le_config* cfg, le_device_open_result* out);
  int32_t (*start)(le_engine* e);
  int32_t (*stop)(le_engine* e);   /* stop + fully release the device */
  void    (*close)(le_engine* e);
} le_device_backend;
```

`le_engine_start` selects the backend from `config->backend`, calls `open` (which
fills `le_device_open_result`), then `le_engine_configure(engine, sr, in, out,
max_loop_frames)` exactly as today, publishes the negotiated info into the
existing atomics (`a_sample_rate`, `a_in/out_channels`, `a_buffer_frames`,
`a_exclusive_active`) **plus a new `a_active_backend`**, and calls `start`.
`le_engine_stop` calls `stop`/`close`. The miniaudio path keeps **byte-identical**
behavior — it is the current code, moved behind the seam.

### The ASIO bridge (the hard part)

ASIO differs from miniaudio's callback in three ways the bridge absorbs **inside
the ASIO backend TU**, so the engine core never sees it:

1. **Non-interleaved, per-channel buffers.** ASIO hands the callback an array of
   per-channel blocks (`ASIOBufferInfo[]`). The bridge **de-interleaves on the
   way in** (gather N input blocks → one interleaved f32 input buffer) and
   **interleaves on the way out** (scatter the interleaved f32 output back into
   per-channel ASIO blocks).
2. **Native sample formats.** ASIO channels are `ASIOSTInt32LSB` / `ASIOSTInt24LSB`
   / `ASIOSTFloat32LSB` / etc. (per `ASIOChannelInfo.type`). The bridge converts
   each to/from f32 in the callback.
3. **Its own RT thread + buffer-switch model.** ASIO owns the audio thread and
   calls `bufferSwitch(index, directProcess)`. The bridge does
   de-interleave → convert → `le_engine_process` → convert → interleave entirely
   within that callback. The engine's RT contract (no locks/allocs on the audio
   thread) is preserved — the ring and atomics already make `le_engine_process`
   callable from any RT thread. **Pre-allocate** the interleaved scratch buffers
   (sized to `max_buffer_frames * LE_MAX_CHANNELS`) at `open`, never in the
   callback.

Channel mapping is direct: ASIO input channel *c* → engine input channel *c*
(0-based); output likewise. `LE_MAX_CHANNELS = 32` covers 18/20, so the mask-based
routing model needs no change.

**The pure, testable core.** Factor the format-conversion + interleave/deinterleave
math into pure helpers (no ASIO types, no threads) so they are unit-tested
off-thread with synthetic buffers — the riskiest unit (RT glitches/format errors)
is verified without hardware:

```c
/* engine_internal.h — pure, unit-testable bridge math (no ASIO/threads). */
typedef enum { LE_SMP_I16, LE_SMP_I24, LE_SMP_I32, LE_SMP_F32 } le_sample_fmt;

/* Gather one per-channel native block [chan] into interleaved f32 out[frame*ch + chan]. */
void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count,
                        int frames);
/* Scatter interleaved f32 in[frame*ch + chan] into one per-channel native block. */
void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count, int frames);
```

### Backend selection & negotiation

- `le_config` grows `int32_t backend` + `char asio_driver[256]`.
- ASIO enumeration is **separate** from miniaudio's: list installed drivers via
  `AsioDrivers::getDriverNames` (each driver is one duplex device), and **probe**
  each for channel counts (`loadAsioDriver`→`ASIOInit`→`ASIOGetChannels`→`ASIOExit`)
  to fill `le_device_info.input_channels`/`output_channels`.
- On open: `loadAsioDriver` → `ASIOInit` → `ASIOGetChannels` (the real 18/20) →
  request sample rate (`ASIOCanSampleRate`/`ASIOSetSampleRate`) → pick a buffer
  size within `ASIOGetBufferSize` → `ASIOCreateBuffers` → `ASIOStart`.
- Teardown order (E7): `ASIOStop` → `ASIODisposeBuffers` → `ASIOExit`, so a live
  reopen (buffer/rate change) re-inits cleanly.
- **Channel counts reach the UI** via `le_device_info` (pre-open probe) and the
  post-open snapshot (negotiated).

### Graceful fallback

When `LOOPY_ENABLE_ASIO` isn't built, no ASIO driver is installed/selected, or
ASIO open fails for any reason, `le_engine_start` **falls back to the miniaudio
backend** and sets `a_active_backend = LE_BACKEND_WASAPI`. ASIO is purely
additive and opt-in; the default build and all non-Windows platforms are
unaffected.

## Technical Approach

Build strictly in dependency order, and **land the seam refactor first with all
existing tests green before any ASIO code is added** (mitigates the
regress-the-working-path risk). Layers: **Native seam → Native ASIO backend →
FFI regen → Dart engine → Repository/persistence → Auto-start → Presentation**.

---

### Layer 0 — Device-backend seam refactor (NO behavior change)

**Goal:** move today's miniaudio device lifecycle behind `le_device_backend`
without changing any behavior. This lands and ships green on its own.

**0a. New `le_audio_backend` enum + `le_config.backend`** —
[loopy_engine_api.h](packages/loopy_engine/src/loopy_engine_api.h):

```c
typedef enum le_audio_backend {
  LE_BACKEND_WASAPI = 0,  /* default: miniaudio's default backend (WASAPI/CoreAudio/ALSA) */
  LE_BACKEND_ASIO = 1,    /* opt-in Windows ASIO (requires LOOPY_ENABLE_ASIO) */
} le_audio_backend;

typedef struct le_config {
  ...
  int32_t exclusive;
  int32_t backend;            /* le_audio_backend; 0 = default miniaudio path */
  char    asio_driver[256];   /* selected ASIO driver name (backend == ASIO) */
} le_config;
```

**0b. `le_device_info` gains channel counts** — same header:

```c
typedef struct le_device_info {
  char id[256];
  char name[256];
  int32_t is_default;       /* 0/1 */
  int32_t input_channels;   /* 0 = unknown (WASAPI today); ASIO probe fills it */
  int32_t output_channels;  /* 0 = unknown */
} le_device_info;
```

> `enumerate_devices` ([engine.c:1589](packages/loopy_engine/src/engine.c)) and
> `device_info_copy` ([engine.c:~1575](packages/loopy_engine/src/engine.c)) set
> the two new fields to `0` for miniaudio (WASAPI does not report per-device
> channel counts here) — unchanged behavior, fields default to 0.

**0c. `le_snapshot.active_backend`** — same header, `le_snapshot`:

```c
  int32_t exclusive_active;
  int32_t active_backend;   /* le_audio_backend actually running (negotiated). A
                             * requested-ASIO open that fell back reports WASAPI. */
```

Add `_Atomic int32_t a_active_backend;` to `struct le_engine`
([engine_private.h:186](packages/loopy_engine/src/engine_private.h), beside
`a_exclusive_active`); init to 0 in the configure/reset path; read out in
`le_engine_get_snapshot` → `out->active_backend`.

**0d. Extract the miniaudio device lifecycle** into a backend impl.

- New file `engine_miniaudio.c` (compiled unconditionally, like the per-OS TUs):
  move the device-specific bodies of `le_engine_start` (the `ma_device_config`
  build, context init, pin/loopback resolution, exclusive fallback,
  `ma_device_init`/`ma_device_start`, `data_callback`, `notification_callback`)
  into `le_miniaudio_open/start/stop/close`, exposed as a
  `const le_device_backend le_miniaudio_backend` (declared in a new
  `engine_miniaudio.h`). `le_engine_process`, the looper, the ring, and the
  snapshot **stay in engine.c**.
- `le_engine_start` ([engine.c:1753](packages/loopy_engine/src/engine.c)) becomes
  the **backend dispatcher**:
  ```c
  const le_device_backend* be = le_select_backend(config->backend);  /* see 0e */
  le_device_open_result info;
  int32_t r = be->open(engine, config, &info);
  if (r != LE_OK) return r;                       /* (ASIO open may fall back; see L1) */
  if (le_engine_configure(engine, info.sample_rate, info.input_channels,
                          info.output_channels, config->max_loop_frames) != LE_OK) {
    be->close(engine); return LE_ERR_INVALID;
  }
  /* publish negotiated info into the existing atomics + a_active_backend */
  ...
  if (be->start(engine) != LE_OK) { be->close(engine); return LE_ERR_DEVICE; }
  engine->backend = be;   /* remember for stop() */
  ```
- `le_engine_stop`/`le_engine_destroy` call `engine->backend->stop/close` instead
  of `ma_device_*` directly. Keep `device_initialised`/`context_initialised`
  ownership inside the miniaudio impl.

**0e. Backend selection** — `le_select_backend(int32_t backend)` in engine.c:
returns `&le_asio_backend` only when `backend == LE_BACKEND_ASIO` **and**
`LOOPY_ENABLE_ASIO` is compiled **and** the ASIO backend's `open` will be tried;
otherwise `&le_miniaudio_backend`. Off-ASIO builds always return miniaudio (the
`asio_driver`/`backend` fields are simply ignored — the default build links no
ASIO code). This is the single chokepoint enforcing fallback when ASIO is absent.

**CMake** — [CMakeLists.txt:8](packages/loopy_engine/src/CMakeLists.txt): add
`engine_miniaudio.c` to the unconditional source list.

**Native tests (seam, no device)** —
[test_engine_core.c](packages/loopy_engine/src/test/test_engine_core.c):
- `test_select_backend_defaults_to_miniaudio`: `le_select_backend(LE_BACKEND_WASAPI)`
  and (in a non-ASIO build) `le_select_backend(LE_BACKEND_ASIO)` both return the
  miniaudio backend. The real proof the default build never hard-depends on ASIO.
- Struct zero-init smoke: `le_config.backend`/`asio_driver` and
  `le_snapshot.active_backend` default to 0 / WASAPI.
- All existing lifecycle/enumeration/process tests **still pass unchanged** — the
  acceptance gate for Layer 0.

---

### Layer 1 — The ASIO device backend (`#if LOOPY_ENABLE_ASIO`)

**Goal:** a real ASIO duplex path at full channel count, behind the flag, that
falls back to miniaudio on any failure.

**1a. Pure bridge math** — declared in
[engine_internal.h](packages/loopy_engine/src/engine_internal.h), defined in
engine.c (platform-agnostic, no ASIO headers): `le_deinterleave_in` /
`le_interleave_out` (see Architecture). Unit-test these exhaustively
(`test_engine_core.c`):
- `test_bridge_roundtrip_f32`: interleave(deinterleave(x)) == x for f32.
- `test_bridge_convert_int32`/`int24`/`int16`: known native byte patterns convert
  to the expected f32 and back within tolerance; endianness (`*LSB`) correct.
- `test_bridge_channel_scatter_gather`: a 3-channel synthetic block round-trips to
  the right interleaved positions.
This is the riskiest unit (RT glitches/format errors) and is now tested without
hardware.

**1b. The ASIO backend TU** — new `win_asio_device.cpp`
(`#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)`, mirroring
[win_asio_labels.cpp](packages/loopy_engine/src/win_asio_labels.cpp)). Exposes an
`extern "C" const le_device_backend le_asio_backend` (declared in a new
`win_asio_device.h`) with:
- **`le_asio_open`**: `loadAsioDriver(cfg->asio_driver)` → `ASIOInit` (sysRef =
  `GetDesktopWindow()`, as the label probe does) → `ASIOGetChannels` (real 18/20,
  clamp to `LE_MAX_CHANNELS`) → sample-rate negotiate
  (`ASIOCanSampleRate(cfg->sample_rate)` ? `ASIOSetSampleRate` : keep
  `ASIOGetSampleRate`) → buffer-size pick within `ASIOGetBufferSize` (map
  `cfg->buffer_frames` to the nearest allowed; see 1d) → read each channel's
  `ASIOChannelInfo.type` into a per-channel `le_sample_fmt` table →
  `ASIOCreateBuffers` (register the static `ASIOCallbacks`) → allocate the
  interleaved scratch buffers → fill `le_device_open_result` (incl.
  `active_backend = LE_BACKEND_ASIO`, `device_name = asio_driver`,
  `exclusive_active = 0`). **On ANY failure: `ASIOExit`, return non-OK** so the
  dispatcher falls back (1e).
- **`bufferSwitch(index, directProcess)`** (static callback; the engine handle is
  held in a file-static set at open, like the SDK host pattern): for each input
  channel, `le_deinterleave_in` its `bufferInfos[c].buffers[index]` block into the
  interleaved input scratch; `le_engine_process(engine, out_scratch, in_scratch,
  blockFrames)`; for each output channel, `le_interleave_out` the interleaved
  output scratch into `bufferInfos[c].buffers[index]`. Call
  `ASIOOutputReady()` if supported. **No allocs/locks** — scratch is pre-allocated.
- **`bufferSwitchTimeInfo`** delegates to `bufferSwitch` (drivers may call either).
- **`sampleRateDidChange`/`asioMessages`**: minimal for v1 — set `device_present`
  appropriately; **reset/hot-swap handling is deferred** (return defaults). The
  seam must not preclude wiring them later.
- **`le_asio_start`**: `ASIOStart`; set `a_device_present = 1`.
- **`le_asio_stop`/`le_asio_close`**: `ASIOStop` → `ASIODisposeBuffers` →
  `ASIOExit`; free scratch; clear the file-static engine handle; set
  `a_device_present = 0`.

**1c. `le_select_backend` returns the ASIO backend** under
`#if LOOPY_ENABLE_ASIO` when `backend == LE_BACKEND_ASIO`.

**1d. Buffer-size + sample-rate negotiation helpers (pure, testable)** —
the *mapping* logic (not the ASIO calls) factored into engine.c and unit-tested:
```c
/* Map a requested buffer size to the nearest ASIO-allowed size given
 * (min,max,preferred,granularity). granularity -1 => powers of two only;
 * 0 => only `preferred`; >0 => linear step. Returns the chosen size. */
int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity);
/* The set of selectable buffer sizes to present as chips (<= cap entries). */
int32_t le_asio_buffer_choices(int32_t min, int32_t max, int32_t preferred,
                               int32_t granularity, int32_t* out, int32_t cap);
```
Tests (`test_engine_core.c`): powers-of-two driver (granularity −1) →
`{min..max}` powers of two incl. preferred; fixed driver (granularity 0) →
`{preferred}` only; linear driver → stepped set; a requested size outside the set
snaps to `preferred`.

**1e. Dispatcher fallback** — in `le_engine_start` (Layer 0e), if the selected
backend is ASIO and `be->open` returns non-OK, **retry once with the miniaudio
backend** and the same `config` (channel fields stay 0 = device default):
```c
if (config->backend == LE_BACKEND_ASIO && r != LE_OK) {
  be = &le_miniaudio_backend;
  r = be->open(engine, config, &info);   /* WASAPI fallback */
}
```
`info.active_backend` therefore reflects what actually opened. A pure helper
keeps the decision testable without a device:
```c
/* engine_internal.h — given requested backend + whether the ASIO open succeeded,
 * which backend should run. */
le_audio_backend le_decide_backend_fallback(le_audio_backend requested,
                                            int asio_open_ok);
```
Test: requested ASIO + ok → ASIO; requested ASIO + fail → WASAPI; requested
WASAPI → WASAPI.

**1f. ASIO enumeration with channel probe** — `extern "C"`:
```c
LE_EXPORT int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                            int32_t* count);
```
Behind `LOOPY_ENABLE_ASIO`, defined in `win_asio_device.cpp`: `getDriverNames`,
then per driver `loadAsioDriver`→`ASIOInit`→`ASIOGetChannels`→`ASIOExit` to fill
`name`/`input_channels`/`output_channels` (`id` = the driver name; `is_default` =
0). **Without `LOOPY_ENABLE_ASIO`**, a stub in engine.c returns `*count = 0,
LE_OK` (so Dart always has the symbol and a default build reports "no ASIO
drivers"). Degrades to 0 on any probe failure (a driver that won't init is simply
omitted), exactly like the label probe's defensive posture.

**CMake** — add `win_asio_device.cpp` to the `LOOPY_ENABLE_ASIO` `target_sources`
block beside `win_asio_labels.cpp`
([CMakeLists.txt:90](packages/loopy_engine/src/CMakeLists.txt)).

**Native tests** — the pure helpers above are the safety net; the ASIO calls
themselves need the SDK + hardware and are covered by the manual hardware spike
(Verification).

---

### Layer 2 — FFI bindings (regen)

Regenerate after the `le_config` / `le_device_info` / `le_snapshot` changes, per
the repo gotcha ([PROGRESS.md](docs/PROGRESS.md)):

```sh
cd packages/loopy_engine
dart run ffigen --config ffigen.yaml
dart format lib/src/generated/loopy_engine_bindings.dart   # required: tall style
```

Bind the new enumeration symbol `le_enumerate_asio_drivers`. Verify the generated
`le_config`/`le_device_info`/`le_snapshot` structs expose the new fields and the
diff is field-scoped (no whole-file churn). Run the loopy_engine analyzer/tests
**right after regen, before touching the Dart wrappers**, so a struct-layout
surprise surfaces at the FFI boundary, not three layers up.

---

### Layer 3 — Dart engine layer (loopy_engine)

**3a. `AudioBackend` enum** — new
`packages/loopy_engine/lib/src/audio_backend.dart`: `enum AudioBackend { wasapi,
asio }` with `toNative()`/`fromNative(int)` (mirrors `EngineResult.fromCode`).

**3b. `EngineConfig`** —
[engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart): add
`final AudioBackend backend` (default `AudioBackend.wasapi`) and
`final String asioDriver` (default `''`); wire into the constructor, `writeTo`
(`ptr.ref.backend = backend.toNative()`; `writeNativeString(ptr.ref.asio_driver,
asioDriver)`), `==`, `hashCode`, `toString`.

**3c. `AudioDevice`** —
[audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart): add
`final int inputChannels` / `final int outputChannels` (default `0` = unknown);
update `==`, `hashCode`, `toString`. Populate from `le_device_info` in the
enumeration mapper.

**3d. `EngineSnapshot`** —
[engine_snapshot.dart](packages/loopy_engine/lib/src/engine_snapshot.dart): add
`final AudioBackend activeBackend` in **all four** sites (miss any → broken
compile/equality): primary constructor (`= AudioBackend.wasapi`), `initial()`
const-ctor initializer list, `fromNative`
(`activeBackend: AudioBackend.fromNative(native.active_backend)`), `props`.

**3e. `AudioEngine` interface** —
[audio_engine.dart](packages/loopy_engine/lib/src/audio_engine.dart): add
`List<AudioDevice> enumerateAsioDrivers();` (returns `[]` off-ASIO builds /
non-Windows). Implement in
[native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart)
via `le_enumerate_asio_drivers` (reuse the `_maxDevices` buffer + the existing
`le_device_info` marshalling, now reading the channel fields). The mock returns a
canned list (3g).

**3f. enumeration mapper** — in
[native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart),
wherever `le_device_info` → `AudioDevice` (the existing
`enumerateDevices` path), read the two new channel fields. ASIO drivers come in
via `enumerateAsioDrivers`, tagged appropriately (a driver is one duplex device;
see 7 for how the UI treats it).

**3g. `MockAudioEngine`** —
[mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart):
**deterministic rule** — `enumerateAsioDrivers()` returns one fake driver
("Mock ASIO Device", 18 in / 20 out); `start` with `backend == asio` "succeeds"
and the snapshot reports `activeBackend == config.backend` (echo intent). The
**fallback path (requested ASIO, reality WASAPI) is therefore NOT exercised by
the mock** — its widget test drives that branch directly (Layer 7 tests).

**Tests:** unit-test `EngineConfig` (new fields in equality/`writeTo`),
`AudioDevice` (channel fields), `EngineSnapshot.fromNative` (`activeBackend`
mapping), and `AudioBackend` round-trip in the loopy_engine package tests.

---

### Layer 4 — Repository + persistence (Domain)

**4a. `EngineStatus`** —
[engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart):
add `final AudioBackend activeBackend` (default `wasapi`), `props`; map it where
the repository builds `EngineStatus` from the snapshot
([looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart)):
`activeBackend: snapshot.activeBackend`.

**4b. `StoredAudioConfig` + keys** —
[settings_repository.dart](packages/settings_repository/lib/src/settings_repository.dart):
add `final AudioBackend backend` (default `wasapi`) and `final String asioDriver`
(default `''`); update the hand-written `==`/`hashCode`. New keys
`_audioBackendKey = 'audio.backend'`, `_audioAsioDriverKey = 'audio.asioDriver'`.
- `saveAudioConfig`: persist `config.backend.name` (string) and `config.asioDriver`.
- `loadAudioConfig`: read them back (`backend ?? wasapi`, `asioDriver ?? ''`).
- The repository stays **platform-agnostic** — no `dart:io`; the
  ASIO-availability decision lives in the presentation layer (Layer 7), as the
  exclusive-mode default does.

**Tests:** extend
[settings_repository_test.dart](packages/settings_repository/test/settings_repository_test.dart)
for round-trip of `backend`/`asioDriver` (save asio+"X Driver" → load asio+"X
Driver"; unset → wasapi+"").

---

### Layer 5 — Auto-start path

[audio_bootstrap.dart](lib/app/audio_bootstrap.dart): thread the new fields into
the auto-start `EngineConfig` (G7 — this assembly is **duplicated** from the
cubit's `_engineConfig`; both must add the fields or relaunch-into-ASIO diverges
from interactive start):

```dart
final stored = await settings.loadAudioConfig();
... EngineConfig(
  ...,
  backend: stored.backend,
  asioDriver: stored.asioDriver,
)
```

If `stored.backend == asio` but the saved `asioDriver` is no longer enumerated
(E1) the **native dispatcher falls back to WASAPI** automatically; the cubit then
reads `engineStatus.activeBackend` and surfaces the fallback (Layer 7). No UI in
bootstrap itself.

---

### Layer 6 — (folded into Layer 7)

---

### Layer 7 — State, Cubit, UI (Presentation)

**7a. `AudioSetupState`** —
[audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart): add
- `final AudioBackend backend` (intent; default `wasapi`),
- `final String asioDriver` (selected driver id, default `''`),
- `final List<AudioDevice> asioDrivers` (enumerated drivers, default `const []`),
to the constructor, `copyWith`, `props`. Negotiated reality reads from
`engineStatus.activeBackend`. Add derived getters:
- `bool get isAsio => backend == AudioBackend.asio;`
- `AudioDevice? get selectedAsioDriver` (match `asioDriver` in `asioDrivers`).
- `List<int> get bufferChoices` / `List<int> get sampleRateChoices`: when `isAsio`
  and a driver is selected, **derived from the driver** (channel counts known;
  buffer/rate sets come from the snapshot/driver probe — see 7e); otherwise the
  existing static `bufferSizes`/`sampleRates`.

**7b. `AudioSetupCubit`** —
[audio_setup_cubit.dart](lib/audio_setup/cubit/audio_setup_cubit.dart):
- **Platform/availability gate** (single source, like `_defaultExclusive`):
  `static bool get _asioSelectable => defaultTargetPlatform ==
  TargetPlatform.windows;` and ASIO is only *offered* when `_asioSelectable` **and**
  `state.asioDrivers.isNotEmpty` (a default build enumerates none → selector
  hidden; G6).
- Load `asioDrivers` on construction (`_repository.asioDrivers()` →
  `enumerateAsioDrivers`) alongside `devices()`/`detectLoopback()` in the
  hydrate `emit`.
- **`void setBackend(AudioBackend backend)`** (G2): guard no-op; on switch to
  ASIO, default `asioDriver` to the first enumerated driver if unset; **keep** the
  WASAPI `playbackDeviceId`/`captureDeviceId` dormant (do not clear — restored on
  switch back, OQ4/E6); `emit(copyWith(...))`; `_persistAndApply()`.
- **`void setAsioDriver(String driverId)`**: guard no-op; `emit`; `_persistAndApply()`.
- `_engineConfig()` ([audio_setup_cubit.dart:157](lib/audio_setup/cubit/audio_setup_cubit.dart)):
  add `backend: state.backend`, `asioDriver: state.asioDriver`. **Force
  `useLoopbackCapture: false` when `state.isAsio`** (E8 — no WASAPI loopback while
  ASIO holds the device).
- `_storedConfig()`: add `backend`, `asioDriver`.
- `_projectFromRepository(hydrateConfig)`: hydrate `backend` from
  `lastConfig?.backend ?? AudioBackend.wasapi` and `asioDriver` from
  `lastConfig?.asioDriver ?? ''` (intent); negotiated reality from
  `engineStatus.activeBackend`, unchanged pattern.
- **Connectivity (OQ5)**: in `_detectConnectivity`
  ([audio_setup_cubit.dart:251](lib/audio_setup/cubit/audio_setup_cubit.dart)),
  treat `state.isAsio && state.asioDriver.isNotEmpty` as "pinned" so an ASIO
  driver loss can raise the lost/restored banner.

**7c. Backend selector + driver picker UI** —
[audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart),
`_EngineStep`:
- At the top of the step, **only when ASIO is selectable** (`_asioSelectable &&
  asioDrivers.isNotEmpty`), an `_OptionRow` backend selector ("WASAPI" / "ASIO")
  wired to `state.backend` / `cubit.setBackend` (mirror the sample-rate
  `_Option` pattern at [audio_setup_steps.dart:176](lib/audio_setup/view/audio_setup_steps.dart)).
- **When `state.isAsio`**: replace the output `AudioDevicePicker`
  ([audio_setup_steps.dart:167](lib/audio_setup/view/audio_setup_steps.dart)) with
  a single **ASIO driver picker** (reuse `AudioDevicePicker` over
  `state.asioDrivers`, label showing "<name> · 18 in / 20 out" from the probed
  channel counts), wired to `state.asioDriver` / `cubit.setAsioDriver`. The
  separate **input** device picker in `_InputStep`
  ([audio_setup_steps.dart:236](lib/audio_setup/view/audio_setup_steps.dart)) is
  **hidden under ASIO** (one driver drives all I/O); show a read-only note instead.
- **Buffer/rate chips** iterate `state.bufferChoices`/`state.sampleRateChoices`
  (7a) instead of the static lists, so under ASIO they reflect the driver's
  allowed sizes/rates (E3, E4).
- Exclusive-mode toggle ([audio_setup_steps.dart:207](lib/audio_setup/view/audio_setup_steps.dart))
  is **hidden under ASIO** (exclusive is a WASAPI concept; no meaning for ASIO).

**7d. Fallback + active-backend status** —
[audio_setup_steps.dart](lib/audio_setup/view/audio_setup_steps.dart),
`_RunningPanel`: surface the **negotiated** backend, and a fallback row **only on
mismatch** (G5, mirrors the exclusive-fallback pattern):
`if (state.backend == AudioBackend.asio && state.engineStatus.activeBackend !=
AudioBackend.asio)` → "ASIO unavailable — running on WASAPI (2 channels)". Add a
plain "Backend: ASIO / WASAPI" row to the ready/running status table.

**7e. Buffer/rate choices source.** For v1, the driver's allowed buffer/rate sets
are read from the **post-open snapshot** is not enough (they're needed before
open). Carry them on the probed `AudioDevice` is heavy; instead **for v1 derive
chips from the static lists intersected with what ASIO accepts at open** and rely
on the **negotiated values in the status table** to show the truth, plus the
graceful snap-to-preferred in native (1d). (A richer pre-open buffer/rate probe is
listed in Out of Scope.) This keeps the picker honest without a second probe
round-trip; the native `le_asio_pick_buffer` guarantees a valid open regardless of
the chip chosen.

**7f. l10n** — add the backend selector labels ("Audio backend", "WASAPI",
"ASIO"), the ASIO driver group label, the channel-count format ("{in} in / {out}
out"), the input-hidden-under-ASIO note, and the fallback status string to **every
ARB file** ([app_en.arb](lib/l10n/arb/app_en.arb) **and**
[app_es.arb](lib/l10n/arb/app_es.arb) — `flutter gen-l10n` flags untranslated
keys), used via `context.l10n`. Reuse existing strings where possible.

**Immutability/equality completeness (do not miss any site):**
| Type | Sites to edit |
|------|---------------|
| `EngineConfig` | ctor, `writeTo`, `==`, `hashCode`, `toString` |
| `AudioDevice` | ctor, `==`, `hashCode`, `toString` |
| `EngineSnapshot` | ctor, `initial()`, `fromNative`, `props` |
| `EngineStatus` | ctor, `props`, build site at [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart) |
| `StoredAudioConfig` | ctor (optional), `==`, `hashCode`, save/load |
| `AudioSetupState` | ctor, `copyWith`, `props`, derived getters |

---

## User Flows & Edge Cases (from flow analysis)

| # | Case | Resolution |
|---|------|------------|
| G1/G7 | Backend must persist end-to-end | `backend`+`asioDriver` threaded through `EngineConfig`, `StoredAudioConfig`, `SettingsRepository`, `AudioSetupState`, `_projectFromRepository`, **and** `audio_bootstrap` (both config-assembly sites). |
| G2/E6/OQ4 | Backend switch invalidates device-id meaning | `setBackend` swaps pickers (two WASAPI device pickers ↔ one ASIO driver picker); WASAPI ids kept dormant, never sent to an ASIO open and vice versa; restored on switch back. |
| G3/OQ2 | Channel counts needed before open | Per-driver ASIO probe fills `le_device_info.input/output_channels`; picker shows "18 in / 20 out" pre-open; routing UI gets authoritative counts post-open from the snapshot. |
| G4 | Requested channel counts vs ASIO-dictated | ASIO `open` ignores `cfg` channel counts and reports the driver's (clamped to 32); `le_engine_configure` uses the negotiated counts (already the contract). |
| G5/OQ1 | Silent fallback hides 16 lost inputs | `active_backend` snapshot field; `_RunningPanel` shows a fallback row on mismatch; status table always shows the running backend. |
| G6 | Default build (`LOOPY_ENABLE_ASIO=OFF`) | `le_enumerate_asio_drivers` stub returns 0 drivers → backend selector hidden; a persisted `backend=asio` falls back to WASAPI deterministically via `le_select_backend`/`le_decide_backend_fallback`. |
| E1 | Persisted ASIO driver no longer installed | Native open fails → WASAPI fallback; UI surfaces "ASIO unavailable". |
| E2 | Driver busy / single-client (DAW holds it) | Open fails → WASAPI fallback (same path); never a dead engine. |
| E3 | Sample rate refused (`ASIOCanSampleRate` false) | Negotiate to driver-current rate; status table shows negotiated SR; open never fails over a rate mismatch. |
| E4 | Buffer granularity non-power-of-two / fixed | `le_asio_pick_buffer`/`le_asio_buffer_choices` handle all three granularity modes; persisted size outside the set snaps to `preferred`. |
| E5 | Driver exposes > 32 channels | Clamp to `LE_MAX_CHANNELS`; 32-bit masks don't overflow; surfaced via the count fields. 18/20 is safe. |
| E7 | Heavy live reopen on every option change | Teardown order `ASIOStop→ASIODisposeBuffers→ASIOExit` guarantees full release before re-init; (debounce listed Out of Scope). |
| E8 | WASAPI loopback detection irrelevant under ASIO | `useLoopbackCapture` forced off when `isAsio`; latency auto-measure relies on `excludedInputMask` (dedicated loopback channels) only. |
| E9 | Latency display is buffer-estimate-based | Keep the estimate, labelled "estimated"; real `ASIOGetLatencies` deferred (Out of Scope). |
| E10/OQ5 | Connectivity banner / `device_present` | ASIO sets `device_present=1` running / `0` on failed reopen; an ASIO driver counts as "pinned" so the banner stays coherent. |
| E11 | Multichannel passthrough (18 in ≠ 20 out) | Per-input monitor masks already handle unequal counts; the global `passthrough` flag monitors input 0 to the stereo pair as today. |
| E12 | Per-device latency key uses `deviceName` | ASIO backend sets `device_name` = driver name, so WASAPI vs ASIO calibration keys for the same interface stay distinct (correctly different round-trips). |

## Acceptance Criteria

### Functional
- [ ] **Seam refactor is invisible**: with `backend == WASAPI` (the default),
      behavior is byte-identical to today on every platform; all existing native +
      Dart tests pass with no logic change.
- [ ] On a Windows build with `LOOPY_ENABLE_ASIO=ON` and the Focusrite ASIO
      driver, selecting **ASIO** opens the device at the **full 18 in / 20 out**,
      and recording/looping/monitoring/routing work across all channels.
- [ ] The ASIO bridge feeds the existing `le_engine_process` correctly: no
      glitches, correct format conversion, correct channel mapping (verified on
      hardware + the pure-conversion unit tests).
- [ ] The audio-setup UI shows a **backend selector** (Windows + drivers present);
      choosing ASIO swaps the two device pickers for one **ASIO driver picker**
      showing "18 in / 20 out"; buffer chips reflect the driver's allowed sizes.
- [ ] Channel counts reach the routing UI so it offers **all** ASIO channels.
- [ ] **Graceful fallback**: ASIO build-off / no driver / missing persisted driver
      / driver busy / init failure all yield **working WASAPI audio**, never a dead
      engine, and the UI shows the fallback + reason. `active_backend` reports the
      truth.
- [ ] Backend + driver selection **persist** across launches (interactive start
      **and** auto-start); switching back to WASAPI restores the prior device ids.

### Non-Functional
- [ ] **No behavior change on macOS/Linux or the default Windows build** (no ASIO
      code linked, `le_enumerate_asio_drivers` returns 0, selector hidden).
- [ ] **RT contract preserved**: the ASIO `bufferSwitch` does no allocation/locking
      (scratch pre-allocated at open); `le_engine_process` is unchanged.
- [ ] **MIT boundary intact**: the GPLv3 ASIO SDK is never committed
      (`.gitignore`d, user-supplied via `LOOPY_ASIO_SDK_DIR`, OFF by default).
- [ ] **FFI**: `le_config`/`le_device_info`/`le_snapshot` grow only the named
      fields; bindings regenerated with `dart format`; no unrelated binding churn.

### Quality Gates
- [ ] Native tests green on Windows (MSVC) + macOS/Linux, including the seam
      selection, the pure bridge conversion/interleave round-trips, the
      buffer-size mapping, and the backend-fallback decision.
- [ ] Dart tests: `AudioBackend`, `EngineConfig`, `AudioDevice`, `EngineSnapshot`,
      `StoredAudioConfig`, `AudioSetupCubit` (`setBackend`/`setAsioDriver`/hydration/
      fallback display), audio-setup widget (selector present on Windows w/ drivers,
      hidden otherwise; driver picker swap; fallback status row).
- [ ] `flutter analyze` clean; app builds on Windows (default + ASIO) + macOS.
- [ ] **Hardware spike** (Verification) passes on the user's Focusrite before merge.

## Verification (hardware spike — required before merge)

The ASIO device calls need the SDK + real hardware. On the user's machine, with
`LOOPY_ENABLE_ASIO=ON` and `LOOPY_ASIO_SDK_DIR` set
([docs/WINDOWS_ASIO.md](docs/WINDOWS_ASIO.md) §"Building with ASIO enabled"):

1. **Enumerate + probe**: ASIO driver appears in the picker with the correct
   "18 in / 20 out".
2. **Open at full count**: select ASIO, start; snapshot reports `input_channels=18`,
   `output_channels=20`, `active_backend=ASIO`.
3. **Audio integrity**: record a loop from a high-numbered input (e.g. input 5),
   play to a high-numbered output (e.g. output 7); confirm correct routing, no
   glitches, correct pitch/format (validates de-interleave/convert/interleave).
4. **Buffer/rate negotiation**: change the buffer chip and sample rate; confirm a
   clean reopen and the status table's negotiated values.
5. **Fallback**: with another app holding the driver (or ASIO build OFF), confirm
   WASAPI fallback + the surfaced reason; audio still runs at 2 channels.
6. **Persistence**: relaunch; confirm it auto-starts back on the ASIO driver.

## Out of Scope (deferred follow-ups)

- "Open ASIO Control Panel" button (`ASIOControlPanel`).
- ASIO per-channel **label** exclusion (reuse the existing `win_asio_labels` probe
  to drive the excluded-input mask under ASIO).
- ASIO **reset / hot-swap** handling (`asioMessages` reset requests, device
  re-open on `kAsioResetRequest`).
- ASIO-reported input/output **latency** (`ASIOGetLatencies`) feeding the latency
  display instead of the buffer-based estimate.
- A richer **pre-open buffer/rate probe** surfacing the exact ASIO-allowed sets as
  chips before open (v1 relies on snap-to-preferred + negotiated status).
- Per-driver **format edge cases** beyond common Int32/Int24/Float32.
- **Debouncing** rapid ASIO reopen on successive option changes.
- Backend-**scoped routing** persistence (v1 shares channel indices across backends).

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| The de-interleave/convert bridge has subtle RT bugs (glitches, format errors) | Med | High | Riskiest unit — pure `le_deinterleave_in`/`le_interleave_out` + `le_asio_pick_buffer` unit-tested off-thread with synthetic buffers; hardware spike validates early. |
| The seam refactor regresses the working miniaudio path | Med | High | Land Layer 0 **first**, byte-identical, all existing tests green, before any ASIO code; `le_select_backend` test proves the default never depends on ASIO. |
| ASIO driver quirks (format, buffer granularity, SR switching) | Med | Med | Negotiate defensively; snap to driver-preferred; degrade to WASAPI on any init failure. |
| GPLv3 SDK accidentally committed | Low | Critical | Unchanged from the label-probe work: `.gitignore`d + OFF-by-default flag + user-supplied + review. |
| Channel-count UI needs counts before open | Med | Med | Per-driver `ASIOInit`+`ASIOGetChannels`+`ASIOExit` probe fills `le_device_info`; degrades to 0 (unknown) on probe failure. |
| Config divergence between cubit and auto-start | Med | Med | Both `_engineConfig` and `audio_bootstrap` add the fields; an acceptance test covers relaunch-into-ASIO. |
| Scope creep into deferred polish | Med | Med | Hard "core end-to-end" boundary; control panel / labels / reset / latency / debounce are explicit Out of Scope. |

## Documentation Plan
- [docs/WINDOWS_ASIO.md](docs/WINDOWS_ASIO.md): expand from "label-read-only" to
  document ASIO-as-a-backend — the backend selector, the build flag now also gates
  the device path, and the fallback contract. Keep the GPLv3/MIT-boundary section.
- [docs/PROGRESS.md](docs/PROGRESS.md): record the device-backend seam, the ASIO
  backend, the `active_backend` reporting, and the ffigen regen.
- Engine header comments on `le_config.backend`/`asio_driver`,
  `le_device_info.input/output_channels`, `le_snapshot.active_backend`.

## References

- Brainstorm: [2026-06-12-asio-audio-backend-windows-brainstorm-doc.md](docs/brainstorm/2026-06-12-asio-audio-backend-windows-brainstorm-doc.md)
- Device open (miniaudio, to move behind the seam): [engine.c:1753](packages/loopy_engine/src/engine.c), `data_callback` [engine.c:1287](packages/loopy_engine/src/engine.c), `notification_callback` [engine.c:1656](packages/loopy_engine/src/engine.c)
- RT core to reuse unchanged: `le_engine_process` [engine.c:856](packages/loopy_engine/src/engine.c)
- Enumeration: `enumerate_devices` [engine.c:1589](packages/loopy_engine/src/engine.c), `device_info_copy` [engine.c:1575](packages/loopy_engine/src/engine.c)
- Existing ASIO label probe (mirror its TU shape + SDK usage): [win_asio_labels.cpp](packages/loopy_engine/src/win_asio_labels.cpp)
- FFI structs: `le_config` [loopy_engine_api.h:189](packages/loopy_engine/src/loopy_engine_api.h), `le_device_info` [loopy_engine_api.h:181](packages/loopy_engine/src/loopy_engine_api.h), `le_snapshot` [loopy_engine_api.h:273](packages/loopy_engine/src/loopy_engine_api.h)
- Engine struct: [engine_private.h:163](packages/loopy_engine/src/engine_private.h); test surface [engine_internal.h](packages/loopy_engine/src/engine_internal.h)
- Build: [CMakeLists.txt](packages/loopy_engine/src/CMakeLists.txt) (unconditional sources :8; ASIO block :77)
- Prior art (pattern to follow): [2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md](docs/plan/2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md) — `exclusive`/`exclusive_active` requested-vs-negotiated; the per-OS seam [2026-06-12-refactor-per-os-engine-subdivision-plan.md](docs/plan/2026-06-12-refactor-per-os-engine-subdivision-plan.md)
- Dart layer: [engine_config.dart](packages/loopy_engine/lib/src/engine_config.dart), [engine_snapshot.dart](packages/loopy_engine/lib/src/engine_snapshot.dart), [audio_device.dart](packages/loopy_engine/lib/src/audio_device.dart), [native_audio_engine.dart](packages/loopy_engine/lib/src/native_audio_engine.dart), [mock_audio_engine.dart](packages/loopy_engine/lib/src/mock_audio_engine.dart)
- Domain: [engine_status.dart](packages/looper_repository/lib/src/models/engine_status.dart), [looper_repository.dart:293](packages/looper_repository/lib/src/looper_repository.dart), [settings_repository.dart](packages/settings_repository/lib/src/settings_repository.dart)
- Presentation: [audio_setup_cubit.dart:157](lib/audio_setup/cubit/audio_setup_cubit.dart), [audio_setup_state.dart](lib/audio_setup/cubit/audio_setup_state.dart), [audio_setup_steps.dart:153](lib/audio_setup/view/audio_setup_steps.dart), [audio_bootstrap.dart](lib/app/audio_bootstrap.dart)
- ASIO SDK host API (user-supplied): `AsioDrivers::getDriverNames`, `loadAsioDriver`, `ASIOInit`, `ASIOGetChannels`, `ASIOGetChannelInfo`, `ASIOCanSampleRate`, `ASIOSetSampleRate`, `ASIOGetBufferSize`, `ASIOCreateBuffers`, `ASIOStart`/`ASIOStop`, `ASIODisposeBuffers`, `ASIOExit`, `bufferSwitch`, `ASIOOutputReady`
- ffigen regen gotcha: [PROGRESS.md](docs/PROGRESS.md)
