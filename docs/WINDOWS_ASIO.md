# Windows ASIO (opt-in): channel-label exclusion + duplex device backend

`LOOPY_ENABLE_ASIO` gates **two** opt-in Windows ASIO features, both off by
default and both behind the same user-supplied GPLv3 SDK:

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
> For low-latency device control *without an SDK*, Loopy uses **WASAPI exclusive
> mode** via miniaudio (MIT-clean, default-on Windows toggle) — but WASAPI still
> only sees the channels the driver publishes to it (often a stereo pair). The
> **ASIO backend** is the only way to reach the device's *full* channel count.
> The two are mutually exclusive in the UI: selecting ASIO hides the
> exclusive-mode toggle (ASIO has no WASAPI share-mode concept).

## Why it is not on by default

The Steinberg ASIO SDK is **GPLv3-or-proprietary** (since Nov 2025), which is
incompatible with Loopy's MIT license if vendored. So the SDK is:

- **never committed** to this repository (it is `.gitignore`d),
- **user-supplied** at build time via `LOOPY_ASIO_SDK_DIR`,
- only compiled when you explicitly set `LOOPY_ENABLE_ASIO=ON`.

The default build requires no ASIO SDK, links no ASIO code, and is byte-for-byte
unchanged: `le_platform_excluded_input_mask` returns `0` on Windows.

> The MIT boundary here is enforced by the **OFF-by-default flag + `.gitignore` +
> review** — not by CI. `license_check.yaml` scans Dart dependencies only; it
> does not see a C/C++ SDK dropped into the build tree.

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

If either answer is no on your hardware, leave the flag OFF — the feature simply
isn't available there, which is expected.

## Building with ASIO enabled

1. Download the Steinberg ASIO SDK and unpack it **outside** version control (or
   into one of the `.gitignore`d folder names, e.g. `asio_sdk/`). The build
   expects the standard SDK layout:

   ```
   <sdk>/common/asio.cpp
   <sdk>/host/asiodrivers.cpp
   <sdk>/host/pc/asiolist.cpp
   <sdk>/common, <sdk>/host, <sdk>/host/pc   (headers)
   ```

   If your SDK is laid out differently, adjust the paths in
   [packages/loopy_engine/src/CMakeLists.txt](../packages/loopy_engine/src/CMakeLists.txt).

2. Configure the native engine with the flag and SDK path:

   ```sh
   cmake -S packages/loopy_engine/src -B build/asio \
     -DLOOPY_ENABLE_ASIO=ON \
     -DLOOPY_ASIO_SDK_DIR=C:/path/to/asio_sdk
   cmake --build build/asio
   ```

   For the **full Flutter app**, the Windows build drives this CMake through the
   plugin and cannot forward `-D` cache flags, so set the two values as
   **environment variables** before building — `src/CMakeLists.txt` reads them as
   a fallback:

   ```powershell
   $env:LOOPY_ENABLE_ASIO = 'ON'
   $env:LOOPY_ASIO_SDK_DIR = 'C:/path/to/asio_sdk'
   flutter clean   # force a CMake reconfigure so the env vars take effect
   flutter build windows --debug --target lib/main_development.dart
   ```

   (An explicit `-DLOOPY_ENABLE_ASIO=ON` on a standalone `cmake` invocation still
   takes precedence; the env fallback only applies when the flag is left default.)

3. With the flag ON and a driver that populates channel names, loopback channels
   on your interface are excluded via the same mask path as macOS. With the flag
   OFF, nothing changes.

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
  ([audio_setup_steps.dart](../lib/audio_setup/view/audio_setup_steps.dart)).
