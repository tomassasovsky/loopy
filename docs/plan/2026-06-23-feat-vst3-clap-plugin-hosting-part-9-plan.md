---
title: "feat(plugin): Linux port — X11 (part 9)"
type: feat
date: 2026-06-23
part: 9 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 9 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack — the final platform.** A single-platform delta on the working macOS +
> Windows base. Shared design and decisions (**D-SCAN**, **D-WIN**, **D-MISS**) live
> in the umbrella.

## Dependencies

**Part 8** (macOS + Windows working). This part ports scanning + editor embedding to
Linux/X11.

## Overview

Bring plugin hosting to **Linux**: standard scan paths, X11 editor embedding, and an
honest handling of Linux GUI limitations — **Wayland editors are unsupported** (clear
message), and many plugins ship **no Linux build** (handled by the D-MISS placeholder
from part 7). Confirm Linux GUI expectations before building the embedding, since X11
embedding is the least standardized of the three platforms.

See umbrella **D-SCAN** (Linux paths), **D-WIN** (X11 ownership), **D-MISS**
(no-Linux-build → placeholder).

## Tasks

- [ ] Confirm Linux GUI expectations (which target plugins ship Linux builds + X11
  editors) before implementing embedding.
- [ ] Wire vendored SDK into
  [linux/CMakeLists.txt](../../packages/loopy_engine/linux/CMakeLists.txt) (enable
  `LOOPY_ENABLE_PLUGINS`).
- [ ] VST3 scan: `/usr/lib/vst3`, `/usr/local/lib/vst3`, `~/.vst3`, app-local;
  `ModuleEntry`/`GetPluginFactory`. CLAP scan: `/usr/lib/clap`, `~/.clap`,
  `CLAP_PATH`.
- [ ] X11 editor: host-owned top-level X11 window (XID) as the attach parent;
  `attached(xid, kPlatformTypeX11EmbedWindowID)` (VST3) / `set_parent(X11)` (CLAP),
  XEmbed; `IPlugFrame::resizeView` resizes the window. Physical-pixel coordinates.
- [ ] **Wayland:** detect a Wayland session and show `pluginWaylandUnsupported`
  (editors unsupported; scanning/processing still work).
- [ ] Apply D-WIN teardown rules on X11; ensure no leaked windows.
- [ ] Confirm a session referencing a plugin with no Linux build resolves to the
  D-MISS placeholder (relinkable), not a crash.

### l10n
- [ ] `pluginWaylandUnsupported` ARB key (en + es).

## File References

- [linux/CMakeLists.txt](../../packages/loopy_engine/linux/CMakeLists.txt)
- `packages/loopy_engine/src/host/scan_*.cpp`, `editor_x11.cpp`,
  `native_window_controller_x11.cpp`
- [app_en.arb](../../lib/l10n/arb/app_en.arb), [app_es.arb](../../lib/l10n/arb/app_es.arb)

## Acceptance Criteria

- [ ] `flutter build linux --debug -t lib/main_development.dart` succeeds with
  plugins enabled.
- [ ] Scan lists VST3 + CLAP plugins from the Linux paths; insert + first-N knobs +
  open editor (X11) + save/reload work (manual, one plugin with a Linux build of each
  format where available).
- [ ] Under Wayland, scanning/processing work and the editor shows a localized
  "unsupported" message rather than failing silently.
- [ ] A macOS/Windows session opened on Linux where a plugin has no Linux build
  resolves to a relinkable placeholder (D-MISS), no crash.
- [ ] X11 window teardown leaves no leaked windows; en + es ARB parity.
- [ ] macOS + Windows behavior unchanged (no regression).

## Out of Scope

Wayland editor embedding (named limitation, not in this stack). Future hardening
(out-of-process sandbox, watchdog, autosave-on-crash, exporting Loopy as a plugin)
remains separate per the umbrella §Out of Scope.
</content>
