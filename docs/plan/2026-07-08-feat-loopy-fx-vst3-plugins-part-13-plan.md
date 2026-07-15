---
title: "feat(vst3): Windows plugin port + signing, all seven plugins (part 13)"
type: feat
date: 2026-07-08
part: 13 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 13 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SIGN, D-VALIDATE) lives in the umbrella. Formerly
> part 8 (Delay + Reverb only) — **scope widened** to all seven plugins.
> Ports parts 2/3/5-9's plugin source (unchanged DSP/wrapper logic — this is
> a build + signing port only) to Windows/MSVC.

## Dependencies

Part 1 (portable `loopy_dsp_core`), parts 2, 3, 5, 6, 7, 8, 9 (all seven
plugins' source to port — the processor/controller/factory C++ is
platform-agnostic; only the CMake target, bundle layout, and signing are
new per plugin).

## Overview

None of the seven plugin trees under `packages/loopy_engine/vst3/` need C++
changes — the VST3 SDK and the `engine_fx.h` seam are portable. This part
adds the Windows CMake wiring: MSVC toolchain flags matching the rest of the
engine's Windows build (`_Atomic`/`/experimental:c11atomics`, per project
memory on the engine's existing C11-atomics MSVC handling), a **folder-style
`.vst3` bundle** per plugin (not a flat DLL — the modern convention even on
Windows, including a `moduleinfo.json`-equivalent if the hand-rolled
packaging needs one for host compatibility; confirmed research: recent VST3
SDK defaults to bundle-style output on Windows too), and Authenticode
signing, applied uniformly across all seven targets.

## Tasks

- [ ] Extend `packages/loopy_engine/vst3/CMakeLists.txt` with a Windows
  branch covering all seven targets (`loopy_vst3_delay`, `_reverb`, `_echo`,
  `_drive`, `_filter`, `_tremolo`, `_octaver`): MSVC-specific compile flags
  matching
  [CMakeLists.txt:69-88](../../packages/loopy_engine/src/CMakeLists.txt)'s
  existing Windows C11-atomics handling.
- [ ] Hand-roll the Windows `.vst3` **folder bundle** layout
  (`<Name>.vst3/Contents/x86_64-win/<Name>.vst3` DLL +
  `Contents/Resources/`) as a shared CMake helper reused by all seven
  targets, matching what a real Live-for-Windows install expects — verify
  the exact expected layout against Steinberg's plugin locations
  documentation before assuming the macOS bundle shape ports directly (it
  does not — Windows historically also accepted a flat `.vst3` DLL; confirm
  which Ableton-for-Windows actually scans first).
- [ ] Local dev-install verification: copy all seven built bundles to
  `%COMMONPROGRAMFILES%\VST3` (manual admin-elevated copy for dev testing;
  the installer in part 16 automates this for end users).
- [ ] Authenticode signing: `signtool sign /fd sha256 /tr <RFC3161 URL> /td
  sha256 /a <bundle>.vst3` on each built DLL (not just relying on a later
  installer signature — each independently-scanned binary should carry its
  own valid signature per research findings), applied to all seven.
- [ ] Manual verification (D-VALIDATE): insert all seven plugins into a real
  Ableton Live for Windows instance; same checklist as parts 2/3/5-9 (param
  list/ranges, audio, automation, mono-input stereo-tail check for Reverb,
  latency-compensation check for Octaver if applicable).

## File References

- `packages/loopy_engine/vst3/CMakeLists.txt` (Windows branch, covering all
  seven targets)
- `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}/`
  (source, unchanged from their respective parts)
- [src/CMakeLists.txt:69-88](../../packages/loopy_engine/src/CMakeLists.txt) (MSVC atomics precedent)
- `packages/loopy_engine/vst3/README.md` (Windows build/signing instructions, extended)

## Acceptance Criteria

- [ ] All seven plugin targets build a valid Windows `.vst3` bundle via
  MSVC.
- [ ] Every built DLL is Authenticode-signed and timestamped;
  `signtool verify /pa` passes for all seven.
- [ ] Manual Ableton-for-Windows load check passes for all seven plugins,
  including the golden-parity expectation holding (spot-check against the
  fixed test signal manually, since the automated harness targets macOS CI
  by default — confirm at implementation time whether the harness is also
  run on Windows CI).

## Out of Scope

Windows app installer (part 16 — this part is plugin build + signing only,
manual local install for verification); Linux (part 14).
