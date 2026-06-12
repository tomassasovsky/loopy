---
title: ASIO Audio Backend for Windows Multichannel I/O
date: 2026-06-12
status: brainstorm
---

# ASIO Audio Backend — Full Multichannel I/O on Windows

## Problem

Loopy on Windows can only see **2 channels** of a pro multichannel interface.
The user's Focusrite (an 18-in / 20-out class device) should expose 18 inputs and
20 outputs, but it doesn't.

This was **diagnosed, not assumed.** A miniaudio probe (`ma_context_get_device_info`
over the WASAPI backend) run on the user's machine reported, for every direction:

```
CAPTURE  "Analogue 1 + 2 (Focusrite USB Audio)" *DEFAULT*  max ch: shared=2 exclusive=2
PLAYBACK "Speakers (Focusrite USB Audio)"        *DEFAULT*  max ch: shared=2 exclusive=2
```

There is **no multichannel WASAPI endpoint** for this interface — not in shared
mode, not in exclusive mode (the just-shipped WASAPI exclusive-mode feature works
correctly; it simply can't surface channels Windows never publishes). Focusrite's
Windows driver exposes only the first analogue pair to WASAPI. Inputs 3–18 and
outputs 3–20 exist **only** inside the device's **ASIO** driver.

This is the fundamental Windows reality and the reason pro audio on Windows runs
on ASIO: WASAPI does not aggregate pro interfaces the way macOS CoreAudio does.

## Goal

Access the **full channel count** of a pro interface on Windows (the Focusrite's
18 in / 20 out) for recording, looping, monitoring, and per-lane routing — the
same multichannel experience Loopy already delivers on macOS via CoreAudio.

## The only viable path: a real ASIO capture/playback backend

ASIO is the **only** Windows API that exposes the complete multichannel device.
This means a genuine second audio backend — load the Focusrite ASIO driver,
create its buffers, run its callback — **not** the label-reading-only scope of the
prior PR2 work.

### What already exists (foundation, not the feature)

- `LOOPY_ENABLE_ASIO` CMake option (OFF by default), `LOOPY_ASIO_SDK_DIR` for a
  **user-supplied, non-vendored** Steinberg ASIO SDK (GPLv3-or-proprietary,
  `.gitignore`d). The MIT boundary is preserved: the SDK is never committed.
- `win_asio_labels.cpp` already loads ASIO drivers (`AsioDrivers`,
  `loadAsioDriver`, `ASIOInit`, `ASIOGetChannelInfo`) — but for **channel-label
  strings only**, never audio.
- A per-OS platform seam (`engine_platform.h`) and the lock-free engine core
  (`le_engine_process`, the SPSC command ring, the atomic snapshot) — all backend-
  agnostic and reusable as-is.

### What is net-new

A full ASIO **audio** path: `ASIOCreateBuffers` + the `bufferSwitch` real-time
callback, format conversion, channel mapping, sample-rate/buffer negotiation,
device/driver selection, and the engine seam that lets ASIO and miniaudio coexist.

## Decisions Locked (with the user)

| Decision | Choice |
|----------|--------|
| Pursue ASIO as a real backend | **Yes** — accept the large effort + GPLv3 opt-in/user-supplied SDK model |
| Bridge architecture | **Device-backend seam in the C engine** (Approach A): miniaudio and ASIO are two implementations, both feeding the *same* `le_engine_process`; engine.c stays clean |
| ASIO selection UX | **Backend selector + ASIO driver picker**: a top-level "Audio backend: WASAPI / ASIO"; choosing ASIO swaps the two device pickers for one "ASIO driver" picker that drives all I/O |
| Buffer / sample rate | **App maps to ASIO-allowed sizes**: query `ASIOGetBufferSize` (min/max/preferred/granularity) and present the allowed buffer sizes as the app's chips; request sample rate via `ASIOCanSampleRate`/`ASIOSetSampleRate` |
| First deliverable | **Core end-to-end first**: device-backend seam + ASIO duplex open at full channel count + backend/driver/buffer selection + channel counts in the UI + existing looper/DSP reused + WASAPI fallback. Polish deferred. |

## Architecture: the device-backend seam (Approach A)

Today `le_engine_start` bakes miniaudio in directly (`ma_device_init` +
`data_callback` → `le_engine_process`). We introduce a thin internal **device
backend** the engine drives, with two implementations:

```
            le_engine_start(config)
                    │  picks backend from config (WASAPI default | ASIO)
                    ▼
        ┌───────────────────────────┐
        │  device backend (seam)     │   open / start / stop / enumerate /
        │                            │   negotiated channel & buffer info
        └───────────────────────────┘
            │                     │
   miniaudio backend          ASIO backend (win_asio_device.cpp,
   (engine.c today,           #if LOOPY_ENABLE_ASIO, C++ → extern "C")
    WASAPI/CoreAudio/ALSA)        │
            │                     │
            └─────────┬───────────┘
                      ▼
        le_engine_process(engine, out_f32_interleaved,
                          in_f32_interleaved, frames)   ← unchanged
```

**Both backends converge on the existing `le_engine_process` with interleaved f32
duplex buffers.** Everything above the device layer — the SPSC ring, the atomic
snapshot, the looper/lane/FX DSP — is reused **unchanged**.

### The ASIO bridge (the hard part)

ASIO differs from miniaudio's callback in three ways the bridge must absorb,
**inside the ASIO backend TU**, so the engine core never sees it:

1. **Non-interleaved, per-channel buffers.** ASIO hands the callback an array of
   per-channel buffers (`ASIOBufferInfo[]`), one block per input/output channel.
   The bridge **de-interleaves on the way in** (gather N channel blocks → one
   interleaved f32 input buffer) and **interleaves on the way out** (scatter the
   interleaved f32 output back into per-channel ASIO blocks).
2. **Native sample formats.** ASIO channels are `ASIOSTInt32LSB` / `ASIOSTInt24LSB`
   / `ASIOSTFloat32LSB` / etc. (reported per driver via `ASIOChannelInfo.type`).
   The bridge converts each to/from f32 in the callback.
3. **Its own RT thread + buffer-switch model.** ASIO owns the audio thread and
   calls `bufferSwitch(index, directProcess)`; the bridge does its de-interleave →
   `le_engine_process` → interleave entirely within that callback. The engine's
   RT contract (no locks/allocs on the audio thread) is preserved — the ring and
   atomics already make `le_engine_process` callable from any RT thread.

Channel mapping is direct: ASIO input channel *c* → engine input channel *c*
(0-based), output likewise. `LE_MAX_CHANNELS = 32` already covers 18/20, so the
mask-based routing model needs no change.

### Backend selection & negotiation

- `le_config` grows a backend selector (e.g. `int32_t backend` +
  `char asio_driver[…]`) and the enumeration exposes ASIO drivers.
- ASIO enumeration is separate from miniaudio's: list installed ASIO drivers
  (`AsioDrivers::getDriverNames`); each driver is one duplex device.
- On open: `loadAsioDriver` → `ASIOInit` → `ASIOGetChannels` (the real 18/20) →
  request sample rate (`ASIOCanSampleRate`/`ASIOSetSampleRate`) → pick a buffer
  size within `ASIOGetBufferSize` → `ASIOCreateBuffers` → `ASIOStart`.
- **Channel counts must reach the UI.** `le_device_info` (and/or the snapshot)
  gains channel-count fields so the backend/driver picker can show "18 in / 20 out"
  and the routing UI can offer all channels. (Today `le_device_info` is id/name/
  is_default only.)

### Graceful fallback

When `LOOPY_ENABLE_ASIO` isn't built, no ASIO driver is installed/selected, or
ASIO init fails, the engine uses the **miniaudio (WASAPI) backend** — exactly
today's behavior. ASIO is purely additive and opt-in; the default build and all
non-Windows platforms are unaffected.

## Scope

### In (first deliverable — "core end-to-end")
- Device-backend seam in the engine; miniaudio refactored to sit behind it (no
  behavior change) and the ASIO backend added behind `LOOPY_ENABLE_ASIO`.
- ASIO duplex open at the driver's **full** channel count, feeding the existing
  `le_engine_process` (de-interleave/convert in, interleave/convert out).
- Backend selector + ASIO driver picker UI; ASIO-allowed buffer-size chips;
  sample-rate request.
- Channel counts surfaced through the FFI to the UI (enumeration/snapshot).
- The whole looper/ring/snapshot/DSP reused unchanged.
- WASAPI fallback; default build + macOS/Linux unchanged.

### Out (deferred follow-ups)
- "Open ASIO Control Panel" button (`ASIOControlPanel`).
- ASIO per-channel **label** exclusion (reuse the existing `win_asio_labels`
  probe to drive the excluded-input mask under ASIO).
- ASIO reset / hot-swap handling (`asioMessages` reset requests, device re-open).
- ASIO-reported input/output **latency** (`ASIOGetLatencies`) feeding the latency
  display instead of the buffer-based estimate.
- Per-driver format edge cases beyond the common Int32/Float32 (e.g. Int24
  packed) if the target interface doesn't need them.

## Open Questions

1. **`le_config` backend representation** — a `backend` enum + `asio_driver` name
   string vs overloading the existing device-id fields. Leaning: a dedicated
   `backend` field + driver name, since ASIO drivers aren't WASAPI device ids.
2. **Channel-count FFI shape** — add `input_channels`/`output_channels` to
   `le_device_info` (per-device, known only after a probe/open for ASIO) vs rely
   on the post-open snapshot (already carries negotiated counts). ASIO channel
   counts are known after `ASIOInit`+`ASIOGetChannels`, so a lightweight
   "probe driver" enumeration call may be needed to show counts *before* opening.
3. **Buffer-size chips** — map ASIO's `(min,max,preferred,granularity)` to a small
   set of selectable sizes; how to present when granularity is non-power-of-two.
4. **Threading/ownership** — ASIO's callback thread vs the engine's existing
   device lifecycle and the device-present/notification model (ASIO has its own
   reset/disconnect signaling, deferred but the seam should not preclude it).
5. **C++/C boundary** — the ASIO backend is C++ (SDK classes); it exposes a small
   `extern "C"` surface the device seam calls, mirroring `win_asio_labels.cpp`.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| The de-interleave/convert bridge has subtle RT bugs (glitches, format errors) | Med | High | The bridge is the riskiest unit — unit-test the pure format/interleave conversion off-thread with synthetic buffers; verify on the real interface early. |
| Refactoring `le_engine_start` behind a seam regresses the working miniaudio path | Med | High | Keep miniaudio behavior byte-identical; the seam refactor lands first with all existing tests green before ASIO is added. |
| ASIO driver quirks (sample format, buffer granularity, sample-rate switching) | Med | Med | Negotiate defensively; fall back to driver-preferred values; degrade to WASAPI on any init failure. |
| GPLv3 SDK accidentally committed | Low | Critical | Already `.gitignore`d + OFF-by-default flag + user-supplied; unchanged from PR2. |
| Channel-count UI needs counts before open (ASIO knows them only after init) | Med | Med | A cheap "probe" path that ASIOInit+ASIOGetChannels+ASIOExit per driver to read counts for the picker, or show counts after selection/open. |
| Scope creep into the deferred polish | Med | Med | Hard "core end-to-end" boundary; control panel / labels / reset / latency are explicit follow-ups. |

## Why not the alternatives

- **WASAPI (shared or exclusive):** proven insufficient — the device only exposes
  2 channels. Exclusive mode (already shipped) gives low latency on those 2
  channels but cannot create channels Windows doesn't publish.
- **Inline ASIO branch in `le_engine_start` (Approach B):** rejected — turns the
  start path two-headed and reintroduces the platform churn the per-OS seam exists
  to avoid.
- **Standalone ASIO module bypassing the device layer (Approach C):** rejected —
  duplicates lifecycle/snapshot wiring and engine state for no benefit.

## References

- Proven constraint: WASAPI channel probe (this session) on the user's Focusrite.
- Existing ASIO foundation: `packages/loopy_engine/src/win_asio_labels.{cpp,h}`,
  `LOOPY_ENABLE_ASIO` in `packages/loopy_engine/src/CMakeLists.txt`,
  `docs/WINDOWS_ASIO.md`.
- Engine core to reuse: `le_engine_process` /
  [engine.c](../../packages/loopy_engine/src/engine.c), the SPSC ring, the atomic
  `le_snapshot`.
- Just-shipped WASAPI exclusive mode + per-OS seam:
  `docs/plan/2026-06-12-feat-wasapi-exclusive-mode-windows-plan.md`,
  `packages/loopy_engine/src/engine_platform.h`.
- Steinberg ASIO SDK (user-supplied, non-vendored): `AsioDrivers`, `ASIOInit`,
  `ASIOGetChannels`, `ASIOGetBufferSize`, `ASIOCreateBuffers`, `bufferSwitch`,
  `ASIOStart`, `ASIOGetLatencies`, `ASIOControlPanel`.
