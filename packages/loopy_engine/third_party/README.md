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
