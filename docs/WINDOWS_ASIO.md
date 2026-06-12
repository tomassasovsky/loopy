# Windows ASIO channel-label exclusion (opt-in)

On macOS, Loopy reads per-channel hardware labels via Core Audio to exclude an
interface's "Loopback" inputs from recording/monitoring. Windows has no portable
equivalent: WASAPI / DeviceTopology cannot return per-channel **name strings**
(`KSJACK_DESCRIPTION` has no name field). The only Windows API that exposes them
is **ASIO** (`ASIOGetChannelInfo().name`), which RME / MOTU / Focusrite-class
drivers populate.

This feature is therefore **opt-in, off by default**, and degrades cleanly to
the standard behaviour (exclude nothing) when it is not built or the hardware
does not cooperate.

> **Not to be confused with exclusive mode.** ASIO here is **label-read-only** —
> it never carries audio. For low-latency *full device control* on Windows
> (bypassing the Windows mixer, native format), Loopy uses **WASAPI exclusive
> mode** via miniaudio — a built-in, MIT-clean capability exposed as a Windows
> audio-setup toggle (default on), no SDK required. That is the default "full
> control" path; ASIO remains solely a per-channel-label source for the
> loopback-exclusion mask.

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

## What it does (and does not) do

- **Label probe only.** Capture and playback stay on miniaudio/WASAPI. ASIO is
  opened *briefly* only to read input-channel names, then closed. Loopy does not
  route audio through ASIO.
- It builds the **same excluded-input bitmask** the macOS Core Audio path builds,
  reusing the engine's portable `le_label_is_loopback` / `le_excluded_mask_from_names`.
- It **degrades to `0`** (exclude nothing) on any failure or ambiguity. A mask
  that excludes the *wrong* channels is worse than the no-op default, so any
  uncertainty — no driver, load/init failure, or an ambiguous WASAPI↔ASIO device
  match — yields `0`.

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

   For the full Flutter app, pass the same cache vars through to the plugin's
   CMake (the `windows/` plugin `add_subdirectory`s `src/`).

3. With the flag ON and a driver that populates channel names, loopback channels
   on your interface are excluded via the same mask path as macOS. With the flag
   OFF, nothing changes.

## Where the code lives

- Dispatch: `le_platform_excluded_input_mask` in
  [engine_windows.c](../packages/loopy_engine/src/engine_windows.c), under
  `#if defined(LOOPY_ENABLE_ASIO)`.
- ASIO probe: [win_asio_labels.cpp](../packages/loopy_engine/src/win_asio_labels.cpp)
  (+ [win_asio_labels.h](../packages/loopy_engine/src/win_asio_labels.h)).
- Portable, unit-tested mask core: `le_excluded_mask_from_names` /
  `le_label_is_loopback` in
  [engine.c](../packages/loopy_engine/src/engine.c) (tested in
  [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
