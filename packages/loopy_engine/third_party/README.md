# Vendored third-party code

## `asiosdk/` — Steinberg ASIO SDK

- **Version:** ASIO SDK 2.3.3 (`asiosdk_2.3.3_2019-06-14`), vendored verbatim.
- **License:** governed by the Steinberg ASIO SDK Licensing Agreement, kept
  intact at
  [`asiosdk/Steinberg ASIO 2.3.3 Licensing Agreement V2.0.3 - 2023.pdf`](asiosdk/).
  This repository is licensed GPL-3.0-or-later; the SDK is redistributed under
  that agreement.
- **Why vendored:** ASIO is the only Windows path to a pro interface's full
  channel count, and is built **by default** on Windows. Vendoring makes the
  Windows build reproducible (no user-supplied SDK step). See
  [docs/WINDOWS_ASIO.md](../../../docs/WINDOWS_ASIO.md).
- **Used by:** `packages/loopy_engine/src/CMakeLists.txt` compiles
  `common/asio.cpp`, `host/asiodrivers.cpp`, and `host/pc/asiolist.cpp` from
  here when `LOOPY_ENABLE_ASIO` is on (the Windows default).

Do not edit the SDK sources in place — they are an upstream drop. To upgrade,
replace the folder with a newer SDK release and update the version above.

## `vst3sdk/` — Steinberg VST3 SDK (plugin-hosting subset)

- **Version:** VST3 SDK `v3.8.0_build_66` (Oct 2025), assembled from the
  upstream modular repos at that tag:
  - [`pluginterfaces/`](vst3sdk/pluginterfaces/) — `steinbergmedia/vst3_pluginterfaces`
  - [`base/`](vst3sdk/base/) — `steinbergmedia/vst3_base`
  - [`public.sdk/source/`](vst3sdk/public.sdk/) — `steinbergmedia/vst3_public_sdk`
    (the `samples/` tree and VSTGUI are **not** vendored — Loopy hosts plugins'
    own native editor windows via `IPlugView`, so VSTGUI is not needed).
- **License:** **MIT.** Each subtree keeps its upstream `LICENSE.txt`
  ([pluginterfaces](vst3sdk/pluginterfaces/LICENSE.txt),
  [base](vst3sdk/base/LICENSE.txt),
  [public.sdk](vst3sdk/public.sdk/LICENSE.txt)). VST3 relicensed to MIT with
  VST 3.8.
- **Why vendored:** makes the plugin-hosting build reproducible (no
  user-supplied SDK step), mirroring the ASIO approach above.

## `clap/` — CLAP plugin ABI (header-only)

- **Version:** CLAP `1.2.9`, headers only ([`clap/include/`](clap/include/)).
- **License:** **MIT** ([`clap/LICENSE`](clap/LICENSE)).
- **Why vendored:** CLAP is a header-only C ABI; vendoring keeps the build
  self-contained.

### License posture for plugin hosting (D-LICENSE)

Both the VST3 SDK (MIT, 3.8+) and CLAP (MIT) are permissively licensed, so they
are **clean for the engine core** and add no copyleft obligation of their own.
(The repository as a whole is GPL-3.0-or-later — see the root `LICENSE` — so the
combined binary stays GPLv3 regardless of platform; MIT inputs are compatible
with that and do not change it.)

They **do not change** the existing platform license posture:

- **Windows is already GPL-3.0-or-later** via the vendored Steinberg ASIO SDK
  above (built by default on Windows). Adding MIT VST3/CLAP does **not** worsen
  that — MIT is compatible with GPLv3.
- **macOS/Linux** ship the miniaudio backend (ASIO off), so the engine there
  carries only MIT third-party code for plugin hosting.

The vendored VST3/CLAP headers are compiled into the engine only when
`LOOPY_ENABLE_PLUGINS` is defined — ON by default for the macOS SPM/CocoaPods
builds, OFF for the Windows/Linux CMake build (where the ports land in later
parts of the stack).

Do not edit the SDK sources in place — they are upstream drops. To upgrade,
replace the folder(s) with a newer release and update the version(s) above.
