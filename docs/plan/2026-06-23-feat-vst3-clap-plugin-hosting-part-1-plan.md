---
title: "feat(plugin): SDK vendoring + build wiring (part 1)"
type: feat
date: 2026-06-23
part: 1 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 1 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack.** Shared design, decisions (D-LICENSE), and the full data model live in the
> umbrella. This part is **headers + build wiring only — no new logic**; the pass/fail
> criterion is "CI stays green with both SDKs vendored."

## Dependencies

None. This is the base of the stack.

## Overview

Vendor the **VST3 SDK** (MIT, 3.8+, Oct 2025) and **CLAP** headers (MIT) under
`packages/loopy_engine/third_party/`, and wire them into the engine's build on
macOS so subsequent parts can `#include` them. No host code, no ABI, no Dart — this
PR exists to isolate the build-system churn (SPM `Package.swift`, CocoaPods
forwarders, CMake) into one trivially-verifiable change, per the splitting review.

See umbrella **D-LICENSE**: both SDKs are MIT → clean for the MIT engine core;
Windows is already GPLv3 via the vendored ASIO SDK and MIT VST3/CLAP do not worsen
that.

## Tasks

- [ ] Vendor the VST3 SDK (`pluginterfaces` + `public.sdk` hosting subset, or the
  full SDK pinned to 3.8.x) under `packages/loopy_engine/third_party/vst3sdk/`,
  retaining LICENSE + copyright text.
- [ ] Vendor CLAP headers (header-only) under
  `packages/loopy_engine/third_party/clap/`, retaining LICENSE.
- [ ] Wire macOS SPM build: add the SDK include paths/sources to
  [macos/loopy_engine/Package.swift](../../packages/loopy_engine/macos/loopy_engine/Package.swift)
  (`process()` resources as needed — see the FFI macOS build note in project memory:
  SPM primary, CocoaPods fallback needs `Classes/` forwarders + `mh_dylib`).
- [ ] Wire CocoaPods fallback: update
  [macos/loopy_engine.podspec](../../packages/loopy_engine/macos/loopy_engine.podspec)
  include paths + `Classes/` forwarders.
- [ ] Add a guarded compile of one trivial translation unit that `#include`s a VST3
  and a CLAP header (e.g. `IPluginFactory`, `clap_entry`) to prove the include paths
  resolve, behind a `LOOPY_ENABLE_PLUGINS` flag (default ON for macOS).
- [ ] Update [third_party/README.md](../../packages/loopy_engine/third_party/README.md)
  with the VST3/CLAP license posture (D-LICENSE): MIT, does not change the
  ASIO-driven Windows GPLv3 status.
- [ ] Leave Windows/Linux CMake (`windows/CMakeLists.txt`, `linux/CMakeLists.txt`)
  untouched except for vendored-header include paths gated off by default (ports are
  parts 8–9).

## File References

- New: `packages/loopy_engine/third_party/vst3sdk/`, `…/clap/`
- [macos/loopy_engine/Package.swift](../../packages/loopy_engine/macos/loopy_engine/Package.swift)
- [macos/loopy_engine.podspec](../../packages/loopy_engine/macos/loopy_engine.podspec)
- [src/CMakeLists.txt](../../packages/loopy_engine/src/CMakeLists.txt)
- [third_party/README.md](../../packages/loopy_engine/third_party/README.md)

## Acceptance Criteria

- [ ] `flutter build macos --debug -t lib/main_development.dart` succeeds with both
  SDKs vendored and the guarded include-probe TU compiling.
- [ ] No new public API, no ABI change, no ffigen regen — the diff is headers +
  build files only.
- [ ] `third_party/README.md` states the MIT posture and the unchanged Windows
  GPLv3 status.
- [ ] Existing engine + Dart tests pass unchanged (no behavioral delta).

## Out of Scope

Any host logic, scanning, ABI, or Dart — those start in part 2. Windows/Linux build
wiring beyond inert include paths (parts 8–9).
</content>
