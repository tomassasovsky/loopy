# Windows ASIO: channel-label exclusion + duplex device backend

`LOOPY_ENABLE_ASIO` gates **two** Windows ASIO features, **on by default on
Windows** and built against the Steinberg ASIO SDK vendored under
[third_party/asiosdk](../packages/loopy_engine/third_party/asiosdk):

1. **Channel-label exclusion** (the original feature): read per-channel hardware
   labels via `ASIOGetChannelInfo().name` to exclude an interface's "Loopback"
   inputs, the way macOS does via Core Audio. WASAPI / DeviceTopology has no
   per-channel name strings (`KSJACK_DESCRIPTION` has no name field), so ASIO is
   the only Windows source. **Label-read-only**: ASIO is opened briefly, names
   are read, and it is closed — no audio flows through it.
2. **Duplex device backend** (Part 2): a real ASIO capture/playback backend, so a
   pro multichannel interface runs at its **full channel count** (e.g. 18 in /
   20 out on a Focusrite) — channels WASAPI never exposes (it publishes only the
   first analogue pair). The user selects it via a **backend selector** in audio
   setup; under ASIO a single **driver picker** drives all I/O.

Both features **degrade cleanly** to the standard behaviour when not built or
when the hardware does not cooperate (exclude nothing / fall back to WASAPI).

> **ASIO backend vs. WASAPI exclusive mode — different "full control" paths.**
> For low-latency device control, Loopy can also use **WASAPI exclusive mode**
> via miniaudio — but WASAPI still only sees the channels the driver publishes to
> it (often a stereo pair). The **ASIO backend** is the only way to reach the
> device's *full* channel count.

## License (GPLv3) and the vendored SDK

The Steinberg ASIO SDK is **GPLv3-or-proprietary**. Loopy is licensed
**GPL-3.0-or-later**, so the SDK is **vendored** under
[`packages/loopy_engine/third_party/asiosdk`](../packages/loopy_engine/third_party/asiosdk)
(version pinned in its README), with the Steinberg Licensing Agreement kept
intact alongside it. ASIO is therefore compiled by default on Windows — no
user-supplied SDK step. macOS/Linux keep the miniaudio backend (`LOOPY_ENABLE_ASIO`
is OFF there).

> `license_check.yaml` scans Dart dependencies only; it does not assert the repo
> license or inspect the vendored C/C++ SDK.

## What the label probe does (and does not) do

- **Label probe only.** This probe never routes audio. ASIO is opened *briefly*
  only to read input-channel names, then closed.
- It builds the **same excluded-input bitmask** the macOS Core Audio path builds,
  reusing the engine's portable `le_label_is_loopback` / `le_excluded_mask_from_names`.
- It **degrades to `0`** (exclude nothing) on any failure or ambiguity. A mask
  that excludes the *wrong* channels is worse than the no-op default, so any
  uncertainty — no driver, load/init failure, or an ambiguous WASAPI↔ASIO device
  match — yields `0`.

## What the ASIO backend does (Part 2)

- **Real duplex audio.** `win_asio_device.cpp` loads the selected driver, creates
  its buffers, runs its real-time `bufferSwitch`, and feeds the **unchanged**
  `le_engine_process` at the driver's full channel count. It plugs into the same
  `le_device_backend` seam the miniaudio/WASAPI backend uses, so the SPSC ring,
  the atomic snapshot, and the looper/lane/FX DSP are reused as-is.
- **Format/layout bridging stays out of the engine core.** ASIO's per-channel,
  native-format buffers are de-interleaved/converted to one interleaved f32
  buffer (and back) by the pure, unit-tested `le_deinterleave_in` /
  `le_interleave_out`; buffer sizes are snapped to a driver-allowed value by
  `le_asio_pick_buffer`. Scratch buffers are pre-allocated at open, never in the
  callback — the engine's no-alloc/no-lock RT contract holds.
- **Graceful fallback (the contract).** A requested ASIO open that fails — build
  OFF, no/missing driver, driver busy, init failure — **falls back to WASAPI**:
  the dispatcher in `le_engine_start` retries once on the miniaudio backend. The
  **negotiated** backend is reported via `le_snapshot.active_backend`, so the UI
  shows reality (an "ASIO unavailable — running on WASAPI" note), never a dead
  engine.
- **R1 — global-state re-entrancy (correctness).** The ASIO host SDK loads a
  **single process-global driver** (`loadAsioDriver`/`ASIOInit`/`ASIOExit` operate
  on global state). `le_enumerate_asio_drivers` therefore must **never** probe a
  driver while an ASIO device is open — that would tear down the live stream. The
  native side reports only the open driver while running; the Dart cubit also
  refuses to enumerate while `activeBackend == asio`. Teardown clears the
  file-static engine pointer **only after `ASIOStop` returns** (which guarantees
  `bufferSwitch` will not fire again), so no callback can race teardown.

## Prerequisite: the 30-minute hardware spike

Before relying on this, confirm on **your** interface (it is ~80% likely, not
guaranteed):

1. **Does `ASIOChannelInfo.name` carry a "Loopback"-style string** that
   `le_label_is_loopback` matches (it matches case-insensitive `"loop"`, which
   also covers Focusrite's `"Loop 1"` / `"Loop 2"`)? Inspect with the SDK's
   `hostsample`, or a quick `ASIOGetChannelInfo` loop.
2. **Can the WASAPI device id be matched to one ASIO driver?** The miniaudio/
   WASAPI `uid` is an opaque endpoint string; ASIO enumerates drivers by name.
   `win_asio_labels.cpp::choose_driver` uses a single-driver-or-substring rule
   and returns "no match" on ambiguity. On a multi-interface rig you may need to
   tighten this once you see what your driver reports.

If either answer is no on your hardware, the **label-exclusion** sub-feature just
degrades to a no-op (mask `0`, nothing excluded) — the ASIO duplex backend still
works. You do not need to disable ASIO for it.

## Building

On Windows, ASIO is built **by default** against the vendored SDK — no extra
step. `flutter build windows` and a plain `cmake` configure both compile it.

To build against a **different** SDK, or to **disable** ASIO, use environment
variables (the Flutter Windows build drives CMake through the plugin and cannot
forward `-D` cache flags):

```powershell
$env:LOOPY_ENABLE_ASIO = 'OFF'                 # skip ASIO entirely, or
$env:LOOPY_ASIO_SDK_DIR = 'C:/path/to/asio_sdk' # point at a different SDK
flutter clean   # force a CMake reconfigure so the env vars take effect
flutter build windows --debug --target lib/main_development.dart
```

A standalone `cmake -S packages/loopy_engine/src` accepts the same as `-D` cache
flags. The vendored SDK uses the standard layout
(`common/asio.cpp`, `host/asiodrivers.cpp`, `host/pc/asiolist.cpp` + headers).

## Where the code lives

**Label probe**

- Dispatch: `le_platform_excluded_input_mask` in
  [engine_windows.c](../packages/loopy_engine/src/engine_windows.c), under
  `#if defined(LOOPY_ENABLE_ASIO)`.
- ASIO probe: [win_asio_labels.cpp](../packages/loopy_engine/src/win_asio_labels.cpp)
  (+ [win_asio_labels.h](../packages/loopy_engine/src/win_asio_labels.h)).
- Portable, unit-tested mask core: `le_excluded_mask_from_names` /
  `le_label_is_loopback` in
  [engine.c](../packages/loopy_engine/src/engine.c) (tested in
  [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).

**Duplex backend (Part 2)**

- ASIO backend + driver enumeration:
  [win_asio_device.cpp](../packages/loopy_engine/src/win_asio_device.cpp)
  (+ [win_asio_device.h](../packages/loopy_engine/src/win_asio_device.h)),
  exposing `le_asio_backend` and `le_enumerate_asio_drivers`.
- Backend selection + WASAPI fallback: `le_select_backend` / `le_engine_start` in
  [engine.c](../packages/loopy_engine/src/engine.c). The default build links no
  ASIO symbol (the reference lives inside the `#if`); a non-ASIO build provides a
  stub `le_enumerate_asio_drivers` returning 0.
- Pure, unit-tested bridge math: `le_deinterleave_in` / `le_interleave_out` /
  `le_asio_pick_buffer` in [engine.c](../packages/loopy_engine/src/engine.c)
  (tested in [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
- Dart stack: the `enumerateAsioDrivers` FFI marshalling
  ([native_audio_engine.dart](../packages/loopy_engine/lib/src/native_audio_engine.dart)),
  the `AudioBackend` / `asioDriver` persistence
  ([settings_repository.dart](../packages/settings_repository/lib/src/settings_repository.dart)),
  and the backend selector + driver picker in the audio-setup feature
  ([audio_settings_section.dart](../lib/audio_setup/view/audio_settings_section.dart)).
