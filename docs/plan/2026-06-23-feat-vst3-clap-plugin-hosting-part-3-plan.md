---
title: "feat(plugin): slot lifecycle + vtable row (part 3)"
type: feat
date: 2026-06-23
part: 3 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
detail: extensive
---

> **Part 3 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack — the safety-critical core.** Shared design and decisions (**D-LIFE**,
> **D-RT**) live in the umbrella, including the cross-thread lifecycle state diagram.
> This part gets its own focused review pass because it is the only code that runs on
> the audio thread.

## Dependencies

**Parts 1–2** (vendoring; `IPluginHost` skeleton + scan). Uses the scanned
`plugin_id` to load a plugin into a slot.

## Overview

Make a hosted plugin **make sound**. Adds the `LE_FX_PLUGIN` vtable row, the per-slot
`IPluginHost::load/activate/process` for both formats, the **cross-thread lifecycle
state machine** (control-thread load→activate-bypassed→atomic-publish-ready; audio
thread renders dry passthrough until ready; quiescent-handshake teardown), output
**sanitize** (denormal flush + NaN/Inf→0), and the `le_engine_set_lane_plugin` /
`set_monitor_plugin` ABI returning an opaque `le_plugin_slot*` handle.

See umbrella **D-LIFE** (lifecycle state diagram), **D-RT** (RT-exempt, sanitize, no
watchdog), and §Plugin-slot lifecycle.

## Tasks

### Native (C/C++)
- [ ] Add `LE_FX_PLUGIN` to `le_fx_type`
  ([loopy_engine_api.h:185](../../packages/loopy_engine/src/core/loopy_engine_api.h))
  and a vtable row in `LE_FX[]`
  ([engine_fx.c:923](../../packages/loopy_engine/src/core/engine_fx.c)) whose
  `process` forwards to the slot's `IPluginHost::process`, `defaults` = no-op.
- [ ] VST3 host `load/activate/process`: create `IComponent`/`IAudioProcessor`/
  `IEditController`, connect, `setBusArrangements(kStereo)`, `setupProcessing`,
  `setActive`/`setProcessing`; `process()` drives `ProcessData`.
- [ ] CLAP host `load/activate/process`: `create_plugin` → `init` → `audio_ports`
  check → `activate` → `start_processing`; `process()` drives `clap_process`.
- [ ] **Lifecycle state machine (D-LIFE):** control-thread load+activate (bypassed)
  → atomic-publish a `ready` flag the audio thread reads; audio thread renders **dry
  passthrough** for a not-ready/unloading slot (no click); destroy happens
  control-thread-side only after a published-quiescent handshake. **No
  alloc/lock/dylib-load on the audio thread.**
- [ ] **Sanitize (D-RT):** after `process`, flush denormals + map NaN/Inf→0 at the
  slot boundary in `fx_apply_chain`
  ([engine_fx.c:951](../../packages/loopy_engine/src/core/engine_fx.c)) before output
  re-enters the chain.
- [ ] `le_plugin_slot` opaque handle; `le_engine_set_lane_plugin` /
  `set_monitor_plugin` (load into a slot, publish ready, return handle); clearing the
  slot (type→none) destroys via the handshake. Reuses existing lane/monitor
  addressing from `le_engine_set_lane_fx*`.
- [ ] ffigen regen + `dart format`.

### Dart
- [ ] Extend `EnginePluginHosting` with `setLanePlugin/setMonitorPlugin/clearSlot`
  returning a slot handle wrapper; implement in `NativeAudioEngine`; **stub in
  `MockAudioEngine`** (fake handle, silent process).

## File References

- [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h),
  [engine_fx.c](../../packages/loopy_engine/src/core/engine_fx.c),
  [engine_process.c](../../packages/loopy_engine/src/core/engine_process.c)
- New: `packages/loopy_engine/src/host/host_vst3.cpp`, `…/host_clap.cpp`, `…/slot.cpp`
- [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart),
  [mock_audio_engine.dart](../../packages/loopy_engine/lib/src/mock_audio_engine.dart)

## Acceptance Criteria

- [ ] Inserting a (stereo-effect) plugin into a lane slot colors playback at the
  plugin's default state (manual: one VST3 + one CLAP).
- [ ] **Lifecycle safety:** insert/remove/reorder a plugin slot while audio runs
  causes **no use-after-free** and **no audio-thread allocation**; the audio thread
  renders dry passthrough (no click) during load/unload. (Native harness; ASan if
  available.)
- [ ] **Output safety:** a deliberately NaN/denormal-emitting stub plugin cannot
  poison downstream lanes or the master sum — output is sanitized at the slot
  boundary. (Native test.)
- [ ] `MockAudioEngine` stub keeps `flutter test` green.

## Testing Strategy

Native CHECK/printf + `main()` harness (project memory: absolute flutter path):
sanitize (NaN/denormal in → clean out), lifecycle under a simulated running callback
(insert/remove with no UAF/alloc), passthrough-during-load (no click). Stub plugin
with a NaN-emit mode is the fixture.

## Out of Scope

Dynamic param surfacing (part 5), topology guard + sealed model (part 4), editor
(part 6), persistence (part 7). This part loads plugins at **default** state only.
</content>
