---
title: "feat(plugin): dynamic params + knob UI (part 5)"
type: feat
date: 2026-06-23
part: 5 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 5 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack.** Shared design and decisions (**D-PARAM**, **D-UI**) live in the umbrella;
> the `le_plugin_param_*` ABI is defined there (§New C ABI surface).

## Dependencies

**Parts 3–4** (a plugin loads + the model has a `PluginEffect`). This part exposes
the plugin's parameters and lets the user tweak the first N in-app.

## Overview

Surface a plugin's **dynamic parameters** and render the first `kPluginKnobs` (=4)
automatable params as in-app knobs (D-UI). Adds `le_plugin_param_*` (count/info/get/
set) with an **RT-safe param-change queue** (app→plugin via the SDK event mechanism,
never a direct audio-thread store), the variable-length `paramValues` on
`PluginEffect`, the `_PluginDeviceCard` widget, and the new `LooperBloc`
plugin-param events.

See umbrella **D-PARAM** (separate ABI section; `LE_FX_PARAMS` untouched; queued
sets) and **D-UI** (first-N knobs + Open Editor; 0-param layout).

## Tasks

### Native
- [ ] `le_plugin_param_count/info_at/get/set` on the `le_plugin_slot*` handle.
  `param_info` unifies VST3 `ParameterInfo` (normalized + `normalizedParamToPlain`)
  and CLAP `clap_param_info` (already plain) into `{id, name, unit, min, max, def,
  step_count, flags}`; flags cover automatable/readonly/bypass/hidden/stepped.
- [ ] **RT param queue:** `param_set` enqueues onto a lock-free SPSC ring drained at
  the top of `process()` into `IParameterChanges` (VST3) / `clap_input_events`
  (CLAP). Never store from the audio thread.
- [ ] ffigen regen + `dart format`.

### Dart
- [ ] Extend `EnginePluginHosting`: `paramCount/paramInfo/paramGet/paramSet`;
  implement in `NativeAudioEngine`; **`MockAudioEngine`** fake enumeration (e.g. 3
  fake params) so widget/bloc tests are deterministic.
- [ ] Add `paramValues` (variable-length, plain) + per-param `PluginParamInfo` to
  `PluginEffect` (engine model + repo mirror).
- [ ] New `LooperBloc` events: `LooperLanePluginParamChanged(slot, paramId,
  plainValue)` + monitor equivalent; wire through `_pushLaneEffects`/
  `_pushMonitorEffects`. UI dispatches events only — no FFI in widgets.

### UI
- [ ] `_PluginDeviceCard` widget class in
  [signal_fx_rack.dart](../../lib/looper/view/signal_graph/signal_fx_rack.dart)
  (sibling to `_DeviceCard`): renders the first `kPluginKnobs` automatable non-hidden
  params as knobs (reuse `SignalKnob`), name + bypass, and an **Open Editor** button
  (inert until part 6). 0-param plugin → name + bypass + Open Editor only. Resolve
  sizing/colors from `LooperTheme`
  ([signal_style.dart](../../lib/looper/view/signal_graph/signal_style.dart)); no
  pixel params in the public API. `kPluginKnobs` is a **Dart UI constant**.

## File References

- [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h),
  `packages/loopy_engine/src/host/*` (param queue)
- [track_effect.dart](../../packages/loopy_engine/lib/src/track_effect.dart),
  [models/track_effect.dart](../../packages/looper_repository/lib/src/models/track_effect.dart)
- [looper_event.dart](../../lib/looper/bloc/looper_event.dart),
  [looper_bloc.dart](../../lib/looper/bloc/looper_bloc.dart)
- [signal_fx_rack.dart](../../lib/looper/view/signal_graph/signal_fx_rack.dart),
  [signal_style.dart](../../lib/looper/view/signal_graph/signal_style.dart)

## Acceptance Criteria

- [ ] First-N knobs tweak a real plugin in-app and the change is audible (manual:
  VST3 + CLAP); a 0-param plugin shows the name+bypass+Open-Editor card; a 200-param
  plugin shows only the first N in-app (rest deferred to the native window, part 6).
- [ ] Param sets reach the plugin via the queue with **no audio-thread allocation**
  (native test).
- [ ] `bloc_test` covers the new plugin-param events (lane + monitor).
- [ ] Widget tests cover `_PluginDeviceCard` first-N / 0-param layouts with theme
  tokens; `MockAudioEngine` keeps `flutter test` green.

## Testing Strategy

- Native: param-queue ordering + no-alloc; unified param_info mapping for both SDKs.
- Dart: `paramValues` round-trip; `bloc_test` for param events; widget tests for the
  card variants (golden where design matters).

## Out of Scope

Native editor window + two-way sync (part 6); opaque state persistence (part 7).
</content>
