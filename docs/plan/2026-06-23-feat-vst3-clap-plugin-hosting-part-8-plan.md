---
title: "feat(plugin): Windows port — HWND (part 8)"
type: feat
date: 2026-06-23
part: 8 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 8 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack.** A single-platform delta on the working macOS base (parts 1–7). Shared
> design and decisions (**D-SCAN**, **D-WIN**, **D-LICENSE**) live in the umbrella.

## Dependencies

**Part 7** (full feature working on macOS). This part ports scanning + editor
embedding to Windows; no new cross-platform abstractions.

## Overview

Bring plugin hosting to **Windows**: registry + Common-Files scan paths, HWND editor
embedding, and the GPLv3 license-posture documentation. The host abstraction and ABI
are unchanged — only the platform-specific scan walk and window controller differ.

See umbrella **D-SCAN** (Windows paths), **D-WIN** (HWND ownership), **D-LICENSE**
(Windows already GPLv3 via ASIO; MIT VST3/CLAP do not worsen it).

## Tasks

- [ ] Wire vendored SDK include/build into
  [windows/CMakeLists.txt](../../packages/loopy_engine/windows/CMakeLists.txt)
  (enable the `LOOPY_ENABLE_PLUGINS` path).
- [ ] VST3 scan: `%PROGRAMFILES%\Common Files\VST3`, `%LOCALAPPDATA%\Programs\Common\VST3`,
  app-local; `InitDll`/`GetPluginFactory` load. CLAP scan: `%COMMONPROGRAMFILES%\CLAP`,
  user path, `CLAP_PATH`.
- [ ] HWND editor: host-owned top-level HWND as the attach parent;
  `attached(hwnd, kPlatformTypeHWND)` (VST3) / `set_parent(WIN32)` (CLAP);
  `IPlugFrame::resizeView` resizes the HWND. Physical-pixel coordinates.
- [ ] Apply the D-WIN teardown rules (force-close on slot/session close + app-quit;
  zero leaked windows) on Windows.
- [ ] Update [third_party/README.md](../../packages/loopy_engine/third_party/README.md)
  / license docs: Windows build is GPLv3 (ASIO); MIT VST3/CLAP unchanged.

## File References

- [windows/CMakeLists.txt](../../packages/loopy_engine/windows/CMakeLists.txt)
- `packages/loopy_engine/src/host/scan_*.cpp`, `editor_win32.cpp`,
  `native_window_controller_win.cpp`
- [third_party/README.md](../../packages/loopy_engine/third_party/README.md)

## Acceptance Criteria

- [ ] `flutter build windows` succeeds with plugins enabled.
- [ ] Scan lists VST3 + CLAP plugins from the Windows paths; insert + first-N knobs +
  open editor (HWND) + save/reload all work (manual, one plugin of each format).
- [ ] Window teardown leaves zero leaked HWNDs.
- [ ] License docs reflect the unchanged GPLv3 posture.
- [ ] macOS behavior unchanged (no regression).

## Out of Scope

Linux (part 9). ASIO-specific concerns beyond the existing build (covered by prior
ASIO work).
</content>
