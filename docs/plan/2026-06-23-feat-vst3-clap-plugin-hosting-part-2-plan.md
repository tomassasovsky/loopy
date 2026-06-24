---
title: "feat(plugin): scan ABI + PluginCatalog (part 2)"
type: feat
date: 2026-06-23
part: 2 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 2 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack.** Shared design and decisions (D-SCAN) live in the umbrella; the
> `le_plugin_scan_*` ABI and `le_plugin_desc` struct are defined there
> (§New C ABI surface).

## Dependencies

**Part 1** (SDKs vendored + build wired) must merge first.

## Overview

Make the app **discover installed VST3 and CLAP plugins**. Adds the `IPluginHost`
interface skeleton, both scan backends (VST3 bundle walk + CLAP search-path walk),
the `le_plugin_scan_*` ABI, the Dart FFI bindings + `EnginePluginHosting` capability
interface (with a `MockAudioEngine` stub), and a Dart `PluginCatalog` that drives an
async scan and caches results. No load/process/GUI yet — the visible result is a
list of installed plugins.

See umbrella **D-SCAN**: async, dedicated scan thread, never blocks the audio
callback, progress + cancel, cache keyed by (path, mtime, size), per-candidate
try+timeout so one broken plugin doesn't abort the scan.

## Tasks

### Native (C/C++)
- [ ] Add `IPluginHost` interface header (skeleton; only scan-relevant statics
  needed now) under `packages/loopy_engine/src/host/`.
- [ ] VST3 scan backend: walk the standard bundle locations (macOS user/system
  `…/VST3`), load each bundle (`bundleEntry` → `GetPluginFactory`), enumerate
  classes via `IPluginFactory2::getClassInfo2`, filter `kVstAudioEffectClass`, emit
  `le_plugin_desc` (TUID hex id, name, vendor, path, packed version).
- [ ] CLAP scan backend: walk `~/Library/Audio/Plug-Ins/CLAP`, system path, and
  `CLAP_PATH`; for each `.clap`, `clap_entry.init` → factory →
  `get_plugin_descriptor`, emit `le_plugin_desc`.
- [ ] Per-candidate guard: try + timeout; a crashing/timing-out candidate becomes a
  "failed" entry, scan continues (in-process for MVP; out-of-process isolation is a
  named follow-up).
- [ ] `le_plugin_scan_begin/poll/get/cancel` on a **dedicated scan thread**; results
  buffered for `_get`.
- [ ] Add `le_plugin_format`, `le_plugin_desc` to
  [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h);
  regen ffigen + `dart format` the generated bindings (per project memory: ffigen
  short-style drift).

### Dart (loopy_engine)
- [ ] New `EnginePluginHosting` capability interface on the `AudioEngine`
  abstraction ([audio_engine.dart](../../packages/loopy_engine/lib/src/audio_engine.dart)),
  with `scanBegin/scanPoll/scanResults/scanCancel`.
- [ ] Implement in [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart).
- [ ] **`MockAudioEngine` stub** returning a deterministic fixed scan list
  ([mock_audio_engine.dart](../../packages/loopy_engine/lib/src/mock_audio_engine.dart)).
- [ ] Dart `PluginDescriptor` model (id, name, vendor, path, format, version).

### Dart (repository)
- [ ] `PluginCatalog` in `looper_repository`: drives an async scan (timer-polled),
  exposes progress (`found`/`total`), cancel, and a cached descriptor list keyed by
  (path, mtime, size); cache invalidated on app-version bump. Minimal scan-result
  holder — not a speculative framework.

## File References

- New: `packages/loopy_engine/src/host/plugin_host.h`, `…/scan_vst3.cpp`, `…/scan_clap.cpp`
- [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h) (ABI)
- [audio_engine.dart](../../packages/loopy_engine/lib/src/audio_engine.dart),
  [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart),
  [mock_audio_engine.dart](../../packages/loopy_engine/lib/src/mock_audio_engine.dart)
- New: `packages/looper_repository/lib/src/plugin_catalog.dart`, `…/models/plugin_descriptor.dart`

## Acceptance Criteria

- [ ] App lists installed VST3 **and** CLAP plugins on macOS (manual: one known
  plugin of each format).
- [ ] Scan reports progress, is cancelable, and **does not block the audio
  callback** (verify scan while audio runs).
- [ ] A single broken/timing-out plugin yields a "failed" entry and the scan
  completes (test fixture: a deliberately-broken stub).
- [ ] Cache re-scans when a plugin's (path, mtime, size) changes; 0-plugins yields a
  clean empty state.
- [ ] `MockAudioEngine` stub keeps `flutter test` green app-wide.
- [ ] ffigen bindings regenerated and `dart format`-ed.

## Testing Strategy

- Native: scan a temp dir of stub bundles (good + broken); assert descriptor fields
  + failed-entry handling. Stub VST3 + CLAP fixtures (see umbrella Testing).
- Dart: `PluginCatalog` cache-keying + progress/cancel; `mocktail`/`MockAudioEngine`.

## Out of Scope

Load/process (part 3), params (part 5), editor (part 6), persistence (part 7).
</content>
