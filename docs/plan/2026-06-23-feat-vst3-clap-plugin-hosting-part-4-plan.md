---
title: "feat(plugin): topology guard + sealed model (part 4)"
type: feat
date: 2026-06-23
part: 4 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 4 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack — the domain-model gate.** Shared design and decisions (**D-BUS**) and the
> sealed-model rationale live in the umbrella (§Data Model). Mostly Dart;
> self-contained and well-specified — a good first-PR candidate.

## Dependencies

**Part 3** (a plugin can be loaded into a slot). This part makes load **reject
unsupported plugins** and gives the domain model somewhere to put a plugin.

## Overview

Two coupled concerns surfaced as an explicit gate before any param/persist code:

1. **Topology guard (D-BUS).** Reject non-stereo-effect plugins (instruments with no
   audio-in, multi-bus, sidechain, wrong channel count) **at insert** with a
   localized message; adapt mono→stereo (duplicate L→R). No partial slot is created.
2. **Sealed `TrackEffect` model.** Convert `TrackEffect` to a sealed hierarchy —
   `BuiltInEffect` (current `{type, params:[4]}`) and `PluginEffect` (a `pluginRef`:
   format + id + version) — in **both** the engine model and the repository mirror,
   keeping the engine as serialization source of truth. **`fromCode` must not
   silent-drop plugin codes** (the data-loss fix). `paramValues` + opaque `state`
   land in later parts; this part adds the variant + ref only.

## Tasks

### Native
- [ ] Topology check in the host `load` path (D-BUS): require a stereo (or
  mono→adaptable) main audio-in + audio-out bus; reject instruments/multi-bus with a
  distinct `LE_ERR_*` code so Dart can localize.
- [ ] Mono→stereo adapter (duplicate L→R) for mono-only effect plugins.

### Dart (model — engine first, repository mirror second)
- [ ] Convert engine `TrackEffect`
  ([track_effect.dart](../../packages/loopy_engine/lib/src/track_effect.dart)) to a
  sealed hierarchy `BuiltInEffect | PluginEffect`; `PluginEffect` carries
  `PluginRef(format, id, version)`. Update encode/decode to **dual-decode** (built-in
  unchanged; plugin entry by `type==LE_FX_PLUGIN`+`plugin` key) — no envelope.
- [ ] Mirror in repository
  ([models/track_effect.dart](../../packages/looper_repository/lib/src/models/track_effect.dart));
  update `props`/`copyWith`/`==` per variant; repository delegates serialization to
  the engine (no drift).
- [ ] **Fix `fromCode`**: the silent `none` fallback must **not** apply to plugin
  entries — an unresolved plugin becomes a placeholder-bearing `PluginEffect` (full
  D-MISS handling is part 7; here just stop the silent drop).
- [ ] Surface the D-BUS reject code to the bloc/UI as a localized error.

### l10n
- [ ] Add `pluginUnsupportedTopology` and `pluginLoadFailed` ARB keys to **both**
  [app_en.arb](../../lib/l10n/arb/app_en.arb) and
  [app_es.arb](../../lib/l10n/arb/app_es.arb) with `@`-metadata.

## File References

- [track_effect.dart](../../packages/loopy_engine/lib/src/track_effect.dart) (engine model — first)
- [models/track_effect.dart](../../packages/looper_repository/lib/src/models/track_effect.dart) (repo mirror — second)
- `packages/loopy_engine/src/host/*` (topology check)
- [app_en.arb](../../lib/l10n/arb/app_en.arb), [app_es.arb](../../lib/l10n/arb/app_es.arb)

## Acceptance Criteria

- [ ] **Topology guard:** inserting an instrument / multi-bus / wrong-channel plugin
  is rejected at insert with a localized message; **no partial slot** is created; a
  mono-only effect is adapted L→R and works.
- [ ] **Sealed model round-trips:** `BuiltInEffect` and `PluginEffect` both
  encode/decode; the **exact current bare-array string** for a built-in chain still
  decodes byte-for-byte (back-compat test).
- [ ] **No silent drop:** an unresolved plugin code decodes to a placeholder
  `PluginEffect`, never `none`.
- [ ] en + es ARB parity for the new keys.

## Testing Strategy

- Dart model: sealed encode/decode, dual-decode, v1-array back-compat, `fromCode`
  no-silent-drop, `copyWith`/`==` per variant.
- Native: topology-reject codes for instrument/multi-bus fixtures; mono→stereo
  adapter output.

## Out of Scope

`paramValues` + knob UI (part 5), opaque state blob + D-MISS relink UI (part 7).
</content>
