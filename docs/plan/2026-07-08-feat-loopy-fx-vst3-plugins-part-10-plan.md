---
title: "feat(daw): export real Loopy VST3 device chains in .als (part 10)"
type: feat
date: 2026-07-08
part: 10 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 10 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-ALL-EFFECTS, D-LANE-CHAIN, D-CHAIN-FALLBACK,
> D-WETDRY, D-CHAIN-SOURCE, Data Model) lives in the umbrella. **This part
> supersedes and replaces the original part 5** (`useLoopyPlugins` toggle
> between a stock-Ableton-device approximation and real plugins) — the
> stock-device approximation system was never built and is now dropped
> entirely, per the
> [2026-07-08 all-effects brainstorm](../brainstorm/2026-07-08-all-effects-vst3-plus-daw-export-brainstorm-doc.md).
> `daw_export` now has exactly two export paths for a track's effects: (a)
> a real Loopy VST3 device chain, when representable, or (b) today's
> existing wet-bounce-only export, unchanged, as the sole fallback — no
> user-facing choice between two device-XML shapes, because only one exists.

## Dependencies

Parts 2, 3, 5, 6, 7, 8, 9 (all seven plugins' permanent GUIDs must exist to
reference — this part cannot start meaningfully before the last plugin,
Octaver, lands, since `loopy_vst3_plugins.dart`'s constant table is
per-effect-complete or it isn't useful).

## Overview

Two gaps close together in this part:

**1. Effects never reach `daw_export`'s model at all today.** Confirmed by
direct inspection: `DawTrack`
([daw_project.dart:35-64](../../packages/daw_export/lib/src/daw_project.dart))
has `name`, `arrangementClip`, `sessionClips`, `automationLanes` — no
effects field. `DawManifestReader.read`
([manifest_reader.dart:25-141](../../packages/daw_export/lib/src/manifest_reader.dart))
never reads the manifest's `effects` key. `als_builder.dart`'s
`<DeviceChain>` block
([als_builder.dart:111-190](../../packages/daw_export/lib/src/als_builder.dart))
emits only `<Mixer>` (volume/activator automation) — no device or plugin
XML exists anywhere in the package today. This part is the **first** time
`daw_export` reads or emits effects-chain data at all.

**2. A Loopy channel's lanes can each carry an independently different
effects chain** ([`Lane.effects`](../../packages/looper_repository/lib/src/models/lane.dart#L21)),
but an Ableton track has exactly one device chain. [D-LANE-CHAIN](#decisions)
(umbrella) resolves this: only emit a device chain for a channel when every
captured lane's effects chain is identical; otherwise the whole track falls
back to today's wet-bounce/no-devices behavior, same "honest degrade"
principle applied to two further edge cases ([D-CHAIN-FALLBACK](#decisions)):
a chain containing a third-party hosted plugin (`type: 8`/`LE_FX_PLUGIN` in
the manifest — out of scope, pre-existing gap, unaffected by this part), and
any effect entry this part can't confidently represent (a forward-compat
guard for effect types added after this plan, if any).

When a device chain **is** emitted, the arrangement clip switches from the
wet stem to the **dry** stem ([D-WETDRY](#decisions)) — otherwise Ableton
would apply the effects twice (baked into the wet audio, then again via the
live device chain). `DawManifestReader` already has a working
wet-then-dry-fallback path
([manifest_reader.dart:67-70](../../packages/daw_export/lib/src/manifest_reader.dart),
`_firstExisting(['stems/wet/...', 'stems/dry/...'])`) proving dry stems are
already captured today — this part reorders that preference specifically
for channels that resolve a device chain, rather than adding new stem
capture. If the dry stem is unexpectedly missing for a channel that
otherwise resolved a device chain, treat it as if resolution failed (fall
all the way back to today's wet-preferred behavior with no device chain) —
never silently double-apply effects.

Effects are read from **`armSnapshot` only**
([D-CHAIN-SOURCE](#decisions)), matching the existing, already-shipped
`fx_chains.dart` precedent
([fx_chains.dart:53-59](../../packages/daw_export/lib/src/fx_chains.dart))
and the manifest format doc's own documented reason
([performance-manifest-format.md:136-139](../../docs/design/performance-manifest-format.md)):
a disarm snapshot never carries `effects` — in-performance chain edits are
logged to `events.log`, not re-snapshotted, and reconciling that log against
the arm snapshot is out of scope here (this resolves the brainstorm's open
question about `armSnapshot`-only vs. reconciliation: no reader in this
codebase reconciles today, and building that machinery is a separate,
unscoped follow-up, consistent with the brainstorm's own note that
FX-parameter automation during a performance is deferred).

**No existing corpus fixture covers any device XML.** Confirmed:
`packages/daw_export/test/corpus/README.md` states the corpus "does not
exist yet" — `als_builder.dart` was written from documented/public
knowledge, never verified against a real Live 12 save, for *any* device
shape (the original stock-device work never captured one either, and it's
now moot since that path is dropped). This part performs `daw_export`'s
**first ever** real corpus capture, reusing the documented "save from Live,
diff the XML" methodology
([corpus/README.md:36-58](../../packages/daw_export/test/corpus/README.md))
for a `<PluginDevice>`-or-whatever-Live-actually-emits real hosted VST3
shape — genuinely unknown until captured, not guessed (brainstorm Open
Question).

## Tasks

- [ ] New `packages/daw_export/lib/src/daw_effect.dart`: `DawEffect`
  (`type` — the `LE_FX_*` integer, `params` — `List<double>`, matching the
  manifest's `TrackEffect.toJson()` shape
  ([performance-manifest-format.md:80-139](../../docs/design/performance-manifest-format.md))
  parsed independently, no import of `looper_repository`/`loopy_engine` per
  this package's existing own-input-model rule
  ([manifest_reader.dart:9-11](../../packages/daw_export/lib/src/manifest_reader.dart))).
- [ ] New `packages/daw_export/lib/src/device_chain_resolver.dart`: a pure
  function taking a channel's captured lanes' raw `effects` JSON and
  returning either a resolved `List<DawEffect>` chain or a
  `DeviceChainFallbackReason` (`mixedLaneChains`, `thirdPartyPlugin`,
  `unrepresentedEffectType`) — unit-testable in isolation from manifest
  parsing.
- [ ] `DawTrack` ([daw_project.dart](../../packages/daw_export/lib/src/daw_project.dart))
  gains two new optional fields: `deviceChain` (`List<DawEffect>?`, null =
  fallback) and `deviceChainFallbackReason` (`DeviceChainFallback?`, set
  only when effects existed but couldn't be represented — never set for a
  channel with no effects at all, since there's nothing to explain there).
- [ ] `DawManifestReader.read` extended: reads each channel's lanes'
  `effects` from `armSnapshot`, calls `resolveDeviceChain`, and — when a
  chain resolves — prefers the dry stem over wet for that channel's
  `arrangementClip` (falling back to today's wet-preferred behavior if the
  dry stem file is missing, per Overview).
- [ ] New `packages/daw_export/lib/src/loopy_vst3_plugins.dart`: seven
  `const LoopyVst3Ref` values (one per `LE_FX_*` built-in type, keyed by
  type int), each carrying the class GUID minted in its plugin's part (2, 3,
  5, 6, 7, 8, 9), subcategory, and vendor — the umbrella Data Model.
- [ ] Capture a real Live 12 `.als` with a chain of several Loopy plugins
  (built via parts 2/3/5-9, loaded locally) on a single track, following the
  existing corpus methodology; document the capture + findings as a new
  section in `packages/daw_export/test/corpus/README.md` (the package's
  first real device-XML capture).
- [ ] New `_deviceChainXml(List<DawEffect>, _IdAllocator)` in
  `als_builder.dart`, built from the captured corpus shape — emits each
  effect's real plugin device block (class id from `loopy_vst3_plugins.dart`
  keyed by `DawEffect.type`, plain param values matching the plugin's own
  `RangeParameter` ranges from its part — must agree exactly, a mismatch
  here silently detunes the exported project relative to what was played).
- [ ] `_writeAudioTrack`'s `<DeviceChain>` block
  ([als_builder.dart:111-190](../../packages/daw_export/lib/src/als_builder.dart))
  gains the device-chain emission when `track.deviceChain` is non-null and
  non-empty, alongside the existing `<Mixer>` block, in the order the corpus
  capture reveals Live actually expects.
- [ ] Corpus/structural tests: the new device-chain XML round-trips against
  the captured fixture for a single-effect chain and a multi-effect chain; a
  track with `deviceChain: null` (today's default for every existing test
  fixture) still produces byte-for-byte-unchanged `<DeviceChain>` XML — a
  regression guard proving this part doesn't alter any existing export.
- [ ] `device_chain_resolver_test.dart`: unit coverage for all three
  fallback reasons, identical-chain resolution across 1/2/3+ lanes, and the
  no-effects (chain stays empty, no fallback reason) case.

## File References

- New: `packages/daw_export/lib/src/daw_effect.dart`
- New: `packages/daw_export/lib/src/device_chain_resolver.dart` (+ test)
- New: `packages/daw_export/lib/src/loopy_vst3_plugins.dart`
- [daw_project.dart:35-64](../../packages/daw_export/lib/src/daw_project.dart) (`DawTrack`, extended)
- [manifest_reader.dart:25-141](../../packages/daw_export/lib/src/manifest_reader.dart) (extended to read `effects`, resolve chain, prefer dry stem)
- [als_builder.dart:111-190](../../packages/daw_export/lib/src/als_builder.dart) (`<DeviceChain>` block, extended)
- [fx_chains.dart:53-59](../../packages/daw_export/lib/src/fx_chains.dart) (armSnapshot-only precedent, D-CHAIN-SOURCE)
- [lane.dart:11-66](../../packages/looper_repository/lib/src/models/lane.dart) (confirms per-lane independent effects chains — read-only reference, no new dependency added)
- [performance-manifest-format.md:80-139](../../docs/design/performance-manifest-format.md) (`effects` shape, arm-only semantics)
- [test/corpus/README.md](../../packages/daw_export/test/corpus/README.md) (extended with the new capture + methodology)
- `packages/loopy_engine/vst3/*/ids.h` (GUID source, parts 2/3/5-9)

## Acceptance Criteria

- [ ] `flutter test packages/daw_export` passes, including new
  `device_chain_resolver_test.dart` and corpus tests for the device-chain
  XML.
- [ ] A channel whose lanes share an identical, fully-representable effects
  chain exports a `.als` with that chain's plugins referenced by permanent
  GUID, and its arrangement clip sources the dry stem.
- [ ] A channel with mixed-lane chains, a third-party hosted plugin, or an
  unrepresented effect type exports exactly like today (wet-preferred stem,
  no device XML) — proven by the byte-for-byte regression test.
- [ ] Manual: a project exported with a resolved device chain opens in Live
  12 with the correct Loopy plugins loaded (not offline/missing) when
  installed locally, parameter values matching what was played, and audio
  identical in character to what was heard live (not literally identical
  samples, since the arrangement clip is now dry — the golden-parity harness
  from parts 4/6/9 already proves the live device reproduces the same DSP).
- [ ] `daw_export` remains a pure Dart package — no new dependency on
  `loopy_engine`, `looper_repository`, or any native code.

## Out of Scope

App-facing export feedback UI (part 11); the third-party hosted-plugin
export gap (unaffected, pre-existing); FX-parameter automation mid-performance
(deferred per brainstorm, `armSnapshot`-only chain-state-at-arm-time is the
full scope here).
