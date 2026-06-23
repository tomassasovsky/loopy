---
title: "feat(plugin): state persistence + missing-plugin resilience (part 7)"
type: feat
date: 2026-06-23
part: 7 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
detail: extensive
---

> **Part 7 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack — the invariant-proving PR.** Shared design and decisions (**D-P1**,
> **D-MISS**, **D-SYNC**) live in the umbrella; the data model + dual-decode and the
> `le_plugin_state_*` ABI are defined there.

## Dependencies

**Part 6** (editor + inbound sync; state is read back at editor-close). Part 7
completes the round-trip and the record-time snapshot.

## Overview

Make a hosted plugin's **full state round-trip** through a session and prove the
**dry-recording invariant** holds. Adds the `le_plugin_state_*` ABI, the opaque
`state` blob on `PluginEffect`, the **D-P1** record-time blob snapshot into
`_snapshotMonitorChainsOntoLanes`, the **D-MISS** missing/moved/version-drift
placeholder + relink, and the `settings_repository` blob-bearing persistence.

See umbrella **D-P1** (frozen-instance lifecycle + capture-failure fallback),
**D-MISS** (placeholder preserves blob, relink policy), **D-SYNC** (state refresh on
save/editor-close), and §Data Model (dual-decode, no envelope).

## Tasks

### Native
- [ ] `le_plugin_state_size/get/set` on the `le_plugin_slot*` handle (VST3
  `IComponent::get/setState` + `setComponentState`; CLAP `clap_plugin_state`
  save/load). Main-thread only.
- [ ] **D-P1 frozen instance:** support instantiating a *distinct* host from a saved
  blob (separate from the live monitor host), created at first lane playback,
  destroyed on take-delete.
- [ ] ffigen regen + `dart format`.

### Dart (model + repository)
- [ ] Add opaque `state` (base64) to `PluginEffect` (engine model + repo mirror);
  encode/decode via the engine serializer (dual-decode, no envelope).
- [ ] **D-P1 capture:** at record-stop, `_snapshotMonitorChainsOntoLanes`
  ([looper_repository.dart:511](../../packages/looper_repository/lib/src/looper_repository.dart))
  calls `le_plugin_state_get` per monitor plugin and stores the blob on each
  recording lane's `PluginEffect`. On capture failure (plugin mid-load / error), the
  lane entry falls back to **bypassed**; the captured audio is dry regardless.
- [ ] **D-MISS:** on reload, an unresolved plugin (uninstalled / moved /
  version-drift) becomes a **placeholder slot** that preserves the blob + ref and is
  relinkable; identity = `format + id (+ version)`, same-id/different-version relinks
  with a "version changed" note. Never the silent `none` fallback.
- [ ] `settings_repository` blob-bearing round-trip: confirm the existing
  per-`(channel,lane)`/`input` string values
  ([settings_repository.dart](../../packages/settings_repository/lib/src/settings_repository.dart))
  hold base64 payloads; async restore of large blobs (slot bypassed until ready).
- [ ] `LooperBloc` `LooperLanePluginRelinked` event + UI affordance on the
  placeholder card.

### l10n
- [ ] `pluginUnavailable`, `pluginVersionChanged` ARB keys (en + es).

## File References

- [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h),
  `packages/loopy_engine/src/host/state_*.cpp`
- [track_effect.dart](../../packages/loopy_engine/lib/src/track_effect.dart),
  [models/track_effect.dart](../../packages/looper_repository/lib/src/models/track_effect.dart)
- [looper_repository.dart:511](../../packages/looper_repository/lib/src/looper_repository.dart) (`_snapshotMonitorChainsOntoLanes`)
- [settings_repository.dart](../../packages/settings_repository/lib/src/settings_repository.dart)
- [app_en.arb](../../lib/l10n/arb/app_en.arb), [app_es.arb](../../lib/l10n/arb/app_es.arb)

## Acceptance Criteria

- [ ] **Dry invariant (headline):** a take recorded with a plugin in the (lane or
  snapshot-copied monitor) chain produces a captured buffer **byte-identical** to the
  same take with the plugin bypassed — the plugin colors playback only. (Automated
  engine test; holds even when D-P1 capture fails.)
- [ ] **Round-trip:** save+reload a session with a hosted plugin restores its full
  opaque state (VST3 + CLAP); a large blob restores async without blocking the UI.
- [ ] **Missing-plugin resilience:** reloading with the plugin uninstalled/moved
  yields a placeholder that preserves the blob and is relinkable; the rest of the
  session loads; **no silent data loss**; a corrupt blob disables the slot without
  crashing.
- [ ] **Back-compat:** a pre-plugin bare-array session decodes unchanged.
- [ ] en + es ARB parity.

## Testing Strategy

- Native: state get/set round-trip per SDK; frozen-instance from blob.
- Dart: `settings_repository` blob round-trip; D-P1 capture + capture-failure
  fallback; D-MISS placeholder/relink; v1-array back-compat; **dry-invariant
  byte-compare** (the headline test).

## Out of Scope

Windows (part 8), Linux (part 9). Autosave-on-crash + out-of-process sandbox remain
named future hardening (umbrella §Out of Scope).
</content>
