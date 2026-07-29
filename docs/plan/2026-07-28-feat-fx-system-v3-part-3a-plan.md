---
title: "feat(domain): stage-addressed FX model, slotIds, chain envelope, inheritance rules"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Fable at high effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

Land the domain half of FX v3's data model in `looper_repository`: the
stage-addressed `FxAddress` with canonical JSON + stable per-slot ids [A9],
`enabled` + `slotId` on `TrackEffect` in both hierarchies [R16], the
`{chainEnabled, meta, entries}` chain envelope with legacy decode [R15], the
inheritance rules (by-value copy with provenance [R13], inheritance×enabled +
D-CHAINDIS [R18], overdub-never-re-inherits [A7], multi-input [A8]), the
four-stage repository APIs with `LooperBloc` owning Track/Master state [VGV],
and the CI gate fix that gives the five domain packages real merge gates
[VGV-critical]. Session formatVersion 5, `SessionRig` growth, and the
performance-arm fix are part 3b — this part is the model + repository layer
they build on.

## Dependencies

Must be merged before this part starts:

- `docs/plan/2026-07-28-feat-fx-system-v3-part-1a-plan.md` — engine universal
  bypass + track bus + Track/Master inserts: the
  `le_engine_set_{lane,monitor,track,master}_fx_enabled` /
  `..._fx_chain_enabled` setters and full track/master chain setters (plus
  their Dart bindings) that this part's repository APIs call.
- `docs/plan/2026-07-28-feat-fx-system-v3-part-1b-plan.md` — chain
  fingerprint folds enabled bits natively, with the Dart mirror
  (`trackChainFingerprint`) folding the default `enabled=1` until this part
  carries the real field [R4][R16]. This part switches the mirror to the real
  bit and must fold **exactly the layout 1b landed** — the agreement test is
  the tripwire.

## Context

Key files (all paths repo-relative unless absolute):

- `packages/looper_repository/lib/src/models/track_effect.dart` — domain
  `TrackEffectParam` (:25) and sealed `TrackEffect` (:138); the named
  boundary mappers `_trackEffectToEngine` (:288) / `_trackEffectFromEngine`
  (:307) — named explicitly because object-pattern churn won't flag them
  [R16]; codec bridge to the engine entries codec (:337, :343);
  `trackChainFingerprint` (:357).
- `packages/loopy_engine/lib/src/track_effect.dart` — engine-side
  `TrackEffectParam` (:156) and sealed `TrackEffect` (:229) + the engine
  entries codec (`encodeTrackEffects` / `decodeTrackEffects`). The C engine
  receives chains via FFI structs — `slotId` never crosses the FFI boundary;
  `enabled` crosses via the part-1a surface.
- `packages/looper_repository/lib/src/looper_repository.dart` —
  `_laneEffects` (:236) / `_monitorEffects` (:257) caches;
  re-apply-on-restart recovery (~:648–:696); D2 doc comment on
  `_snapshotMonitorChainsOntoLanes` (:829–:843) [R18]; the empty-chain dry
  bail inside it (~:850); `_capturePluginForLane` (:887);
  `_snapshotForClearRestore` (:957) / `_restoreClearedTake` (:988) [R15];
  `laneChainFingerprint` (:1389) / `monitorChainFingerprint` (:1394).
- `packages/looper_repository/lib/looper_repository.dart:59` — barrel export
  of `trackChainFingerprint` (rename ripples here).
- Direct engine-codec call sites that migrate to the envelope
  [VGV-critical, pinned list]: `lib/app/audio_bootstrap.dart:291`,
  `lib/app/monitor_migration.dart:162`,
  `lib/audio_setup/cubit/monitor_cubit.dart:84`,
  `lib/session/session_mapping.dart:47,57`. Their encode twins live in the
  same files: `monitor_cubit.dart:143,210,261,283,345` and
  `session_mapping.dart:19,33` (see the sequencing task for which flip now).
- `lib/looper/bloc/looper_bloc.dart` + `lib/looper/bloc/looper_event.dart` —
  gains Track/Master chain events + state [VGV].
- `.github/workflows/main.yaml` — root app job (`flutter_package.yml@v1`,
  `min_coverage: 90` at :37), `daw_export` job (`min_coverage: 100` at :49),
  fuzz job (builds `LOOPY_ENGINE_LIB`, runs `flutter test --tags fuzz`,
  ~:172–:190). The five domain packages have **no jobs today**.
- Tests to extend: `packages/looper_repository/test/fx_fingerprint_agreement_test.dart`
  (fuzz-tagged, self-skips without `LOOPY_ENGINE_LIB`),
  `packages/looper_repository/test/models/track_effect_test.dart`.

Constraints lifted from the index (pinned decisions — do not change):

- **Stable effect identity [A9]:** every chain entry gets a stable per-slot
  id — generated at insert, persisted, never reused within a session. Pedal
  bindings (part 6) and expression mappings (part 7) reference
  `{FxAddress-of-chain, slotId}`; effect-level bindings go inert (never
  retarget) when the id is gone.
- **Chain wire envelope [R13][R15]:** `{chainEnabled, meta (inherited
  provenance), entries: [...]}`; decode accepts the legacy bare array
  (chainEnabled = true, no meta). One codec everywhere — sessions
  (`SessionLaneChain.encoded` stays opaque, unchanged), settings keys,
  clear-restore snapshots, and the new track/master stages reuse the same
  string format. Migration defaults every level to enabled.
- **Canonical `FxAddress` JSON serialization** is declared once here; parts
  6 and 7 reference it [R19].
- **Type ownership + dependency arrows [VGV-critical]:** `FxAddress` (and
  slotIds) live in `looper_repository` (domain model). Binding/mapping
  targets cross the `controller_repository` / `pedal_repository` boundary as
  canonical-JSON strings — those packages gain no looper/engine dependency.
  The chain envelope is **owned by `looper_repository`**, wrapping
  `loopy_engine`'s existing entries codec — the engine never consumes
  provenance/meta.
- **State ownership [VGV]:** `LooperBloc` owns Track and Master chain state
  (events + push, like lane chains today); `MonitorCubit` stays input-only.
- **Inheritance = by-value copy with provenance [A6][R13]:** record() copies
  the input chain onto the loop chain exactly as today (plugin state frozen
  via `_capturePluginForLane`), stamps `inheritedFrom` in the envelope meta;
  part 4's detach clears the marker only; nothing ever propagates to
  existing takes.
- **Inheritance × enabled [R18]:** per-slot `enabled` copies by value
  (disabled entries inherit disabled — the take reproduces the monitored
  sound). **D-CHAINDIS: a chain-disabled monitor chain is treated as dry** —
  the existing empty-chain bail extends to chain-disabled, the lane keeps
  its prior chain.
- **Overdub never re-inherits [A7]**; the domain exposes "input chain ≠ loop
  chain" during overdub for part 4's hint.
- **Multi-input inheritance [A8]:** loop inherits from its routed input;
  multi-input mixes concatenate in input order, provenance lists all.

## Tasks

### T1 — `FxAddress` + canonical JSON + stable slotIds [A9][R19]

- [ ] Create `packages/looper_repository/lib/src/models/fx_address.dart`:
      `FxAddress {stage, index, lane?}` with `FxStage {input, loop, track,
      master}`. Semantics: `index` = input index for the Input stage, channel
      for Loop/Track, unused (0) for Master; `lane` only meaningful for the
      Loop stage. Equatable, `copyWith`, doc comments spelling out the
      per-stage field meaning.
- [ ] Declare the **canonical JSON serialization** in the same file (this is
      the single declaration parts 6 and 7 reference [R19]): fixed key order,
      no optional-key omission ambiguity (absent `lane` is omitted, never
      null-valued), and a `canonicalString()` helper producing a byte-stable
      string so binding targets can cross the `controller_repository` /
      `pedal_repository` boundary as plain strings with equality ==
      target-identity. Document the compatibility contract on the class
      (fields are additive-only; unknown keys are ignored on decode).
- [ ] **Stable slotIds:** add `slotId` to the domain `TrackEffect`
      (see T2). Identity ownership lives in `looper_repository` [A9]:
      recommended shape is `String? slotId` on the model (const constructors
      survive) with **minting at the repository write boundary** — every
      repo path that accepts a chain (`setLaneEffects`,
      `setMonitorEffects`, the new track/master setters, envelope decode of
      legacy payloads) assigns a fresh unique id to any entry lacking one.
      The invariants (pinned by tests, whatever the minting mechanism):
      unique within a session, never reused, preserved across `copyWith` /
      param edits / reorders, stable across persist→restore, minted exactly
      once for legacy payloads.
- [ ] Export `FxAddress`, `FxStage`, and the slotId helpers from the
      `looper_repository` barrel.

### T2 — `TrackEffect` gains `enabled` + `slotId` in BOTH hierarchies [R16]

- [ ] Domain hierarchy
      (`packages/looper_repository/lib/src/models/track_effect.dart:138`):
      every `TrackEffect` subclass gains `bool enabled` (default `true`) and
      `String? slotId`, threaded through `copyWith` / `props` / `toJson` /
      `fromJson` on every subclass. Decode defaults: missing `enabled` →
      `true`; missing `slotId` → left null for the repo boundary to mint.
- [ ] Engine hierarchy (`packages/loopy_engine/lib/src/track_effect.dart:229`):
      same two fields + codec support in `encodeTrackEffects` /
      `decodeTrackEffects` (entries carry both fields; the C engine never
      parses `slotId` — it is Dart-side passthrough; `enabled` reaches the
      engine through the part-1a chain setters / per-slot enabled bindings).
- [ ] Thread both fields through the **named boundary mappers**
      `_trackEffectToEngine` (:288) and `_trackEffectFromEngine` (:307) —
      both the built-in and plugin arms. These are named explicitly because
      object-pattern churn won't flag them [R16]; a field silently dropped
      here round-trips as default and the bug is invisible until a stomp
      un-bypasses a chain.
- [ ] Audit existing equality assertions that adding `slotId` to `props`
      breaks (two otherwise-identical effects with different ids are now
      unequal — that is the point [A9]); update tests to compare
      sound-identity via fingerprint where identity is not what's under
      test.
- [ ] Repo enabled-setter plumbing: per-slot `enabled` flips call the
      part-1a direct-atomic engine bindings (they work while stopped — no
      ring), and the repo cache updates in the same call so cache == engine
      always holds.

### T3 — `trackChainFingerprint` → `fxChainFingerprint` + real enabled bit [R16][VGV]

- [ ] Rename the free function `trackChainFingerprint` →
      `fxChainFingerprint` (it becomes four-stage generic) across:
      definition (`track_effect.dart:357`), barrel export
      (`lib/looper_repository.dart:59`), internal uses
      (`looper_repository.dart:1390,1395`), and every test
      (`track_effect_test.dart`, `fx_fingerprint_agreement_test.dart`).
      After the rename `grep -rn trackChainFingerprint` over `lib`,
      `packages`, `test` returns nothing.
- [ ] Switch the fold from the part-1b hard-coded `enabled=1` default to the
      real per-effect bit — folding **exactly the native layout part 1b
      landed** (do not re-derive the fold; read 1b's landed code).
      `slotId` must NOT fold into the fingerprint (fingerprint = sound
      identity; ids are entry identity — folding them would break part 2's
      cache-hot toggle pairs and fingerprint-identical loads).
- [ ] **Agreement test with mixed enabled/disabled chains [R16]:** extend
      `fx_fingerprint_agreement_test.dart` — chains with some slots
      disabled, all slots disabled, and a toggle round-trip must agree
      exactly between `fxChainFingerprint`, `repo.laneChainFingerprint` /
      `monitorChainFingerprint`, and the native
      `le_engine_*_fx_fingerprint` values (lane + monitor stages, where the
      native per-chain fingerprint APIs exist). Keep the `@Tags(['fuzz'])`
      self-skip pattern so plain `flutter test` stays green without
      `LOOPY_ENGINE_LIB`.

### T4 — Chain envelope `{chainEnabled, meta, entries}` [R13][R15]

- [ ] New envelope codec in `looper_repository` (suggested:
      `lib/src/models/fx_chain_envelope.dart`): `encodeFxChain` /
      `decodeFxChain` producing/consuming
      `{chainEnabled: bool, meta: {...}?, entries: [...]}` where `entries`
      is the engine entries codec's payload (the envelope **wraps**
      `loopy_engine`'s codec; the engine never consumes `chainEnabled` or
      `meta` [VGV-critical]). `meta` carries inherited provenance:
      `inheritedFrom` as a **list of input indices in input order** [A8]
      (single-input inherits produce a one-element list).
- [ ] **Legacy bare-array decode:** a payload that is a JSON array decodes
      as `chainEnabled = true`, no meta, entries as today; entries missing
      `enabled` default `true` ("migration defaults every level to enabled"
      [R15]); entries missing `slotId` get fresh ids minted once at the repo
      boundary (T1). Unknown envelope keys are ignored (additive-only
      contract).
- [ ] **One codec everywhere:** the envelope is the single string format for
      sessions (`SessionLaneChain.encoded` stays an opaque string — its
      content becomes the envelope), settings keys (no new per-flag keys
      needed [R15] — `chainEnabled` rides inside), clear-restore snapshots,
      and the new track/master stages.
- [ ] **Clear-restore carries the chain flag [R15]:**
      `_snapshotForClearRestore` (:957) snapshots the lane's chain-enabled
      flag alongside the chain; `_restoreClearedTake` (:988) restores it.
      Disable a chain → clear → restore ⇒ still disabled.
- [ ] **Migrate the four named direct engine-codec call sites** (the pinned
      read-side list) to envelope-aware decode:
      - `lib/app/audio_bootstrap.dart:291`
      - `lib/app/monitor_migration.dart:162` (its non-empty check reads the
        envelope's entries)
      - `lib/audio_setup/cubit/monitor_cubit.dart:84`
      - `lib/session/session_mapping.dart:47,57`
- [ ] **Write-side sequencing (explicit seam):** with every reader now
      envelope-aware, flip the **settings** write twins in the same file as
      the named :84 site (`monitor_cubit.dart:143,210,261,283,345`) to
      envelope encode in this part. Leave the **session** write twins
      (`session_mapping.dart:19,33`) to part 3b, landing together with the
      formatVersion 4→5 bump so the session format changes move as one
      reviewed unit. After this part, the only direct
      `encodeTrackEffects` / `decodeTrackEffects` calls left under `lib/`
      are the two session write sites earmarked for 3b (guard: the success
      criterion greps for exactly this).

### T5 — Inheritance rules [R13][R18][A7][A8]

- [ ] **By-value copy with provenance [A6][R13]:** `record()` keeps copying
      the input chain onto the loop chain exactly as today
      (`_snapshotMonitorChainsOntoLanes`, plugin state frozen via
      `_capturePluginForLane` :887) and now stamps `inheritedFrom` in the
      chain meta (repo keeps a per-lane meta cache beside `_laneEffects`,
      ridden through the envelope on persist). Nothing ever propagates to
      existing takes; part 4's detach clears the marker only — this part
      just exposes the meta (on `LooperState` for part 4's badge).
- [ ] **Inheritance × enabled [R18]:** per-slot `enabled` copies by value —
      a disabled monitor slot inherits disabled (the take reproduces the
      monitored sound). Copied entries get **fresh slotIds** (the take's
      entries are new identities; bindings on the input chain must not
      follow the copy [A9]).
- [ ] **D-CHAINDIS [R18]:** extend the existing empty-chain dry bail in
      `_snapshotMonitorChainsOntoLanes` (~:850) to also bail when the
      monitor chain's `chainEnabled` is false — a chain-disabled monitor
      chain is treated as dry and the lane keeps its prior chain. Update the
      D2 doc comment (`looper_repository.dart:829–843`) to state both dry
      shapes (empty OR chain-disabled).
- [ ] **Overdub never re-inherits [A7]:** document on `record()` /
      the overdub path that overdub passes never re-copy the input chain;
      add a domain query exposing "input chain ≠ loop chain" during overdub
      (fingerprint comparison between the lane's chain and its routed
      input's monitor chain) for part 4's mismatch hint.
- [ ] **Multi-input inheritance [A8]:** the loop inherits from its routed
      input; where a record path mixes multiple inputs, the inherited chain
      is the concatenation of the input chains **in input order**, and
      `inheritedFrom` lists all source inputs. Today's
      `_snapshotMonitorChainsOntoLanes` resolves one routed input per lane —
      the rule lands as the documented + tested provenance shape
      (`inheritedFrom` is a list) plus the concatenation helper, so any
      current or future multi-input record path has pinned semantics.

### T6 — Four-stage repository APIs + `LooperBloc` ownership [VGV]

- [ ] `LooperRepository` gains the Track/Master stage mirroring the lane
      set: `_trackEffects` / `_masterEffects` caches + per-stage
      chain-enabled caches for all four stages; setters
      (`setTrackEffects(channel, effects)`, `setMasterEffects(effects)`),
      per-slot enabled setters and per-chain enabled setters for **all
      four stages**, each updating cache + engine together (part-1a
      bindings). Per-stage fingerprint getters for track/master mirroring
      `laneChainFingerprint` / `monitorChainFingerprint` (pure-Dart
      `fxChainFingerprint` over the cache).
- [ ] **Re-apply-on-restart extended to track/master** (the recovery path at
      ~:648–:696): after `startEngine`, remembered track/master chains and
      every stage's chain-enabled flags re-push, same as lane/monitor
      today.
- [ ] Settings persistence for the new stages: track/master chains ride the
      same envelope string in `settings_repository` keys (mirroring the
      monitor/lane chain keys; no new per-flag keys [R15]); restored at
      bootstrap in `lib/app/audio_bootstrap.dart` (already churning as a
      migrated call site).
- [ ] `LooperState` exposes: track/master chains, all per-stage
      chain-enabled flags, per-entry `enabled`/`slotId` (they ride the
      chains), and lane-chain inheritance meta + the overdub divergence
      query result — everything part 4 (badges, power controls) and part 5
      (chain-state LEDs via the trackLeds projection) read.
- [ ] `LooperBloc` owns Track and Master chain state [VGV]: new events
      (chain set, per-slot enabled toggle, chain-enabled toggle for Track
      and Master) in `lib/looper/bloc/looper_event.dart`, handled by
      pushing through the repo (events + push, like lane chains today).
      `MonitorCubit` stays input-only — no track/master anything grows
      there.

### T7 — CI gate fix [VGV-critical]

- [ ] Add CI jobs for the five gate packages that have none today:
      `looper_repository`, `session_repository`, `performance_repository`,
      `pedal_repository`, `controller_repository` — per-package
      `VeryGoodOpenSource/very_good_workflows/.github/workflows/flutter_package.yml@v1`
      jobs (or one matrix job) in `.github/workflows/main.yaml` with
      `working_directory: packages/<name>`.
- [ ] **Deliberate `min_coverage`:** measure each package's current coverage
      first and pin the floor at (not above) the measured value — a blind
      100 blocks every later part; a blind 0 is not a gate. Record the
      chosen floors in the PR description.
- [ ] Native-lib-dependent tests (the agreement test) keep the
      `@Tags(['fuzz'])` self-skip so the new package jobs stay green
      without an engine build; extend the existing fuzz job (which already
      builds `LOOPY_ENGINE_LIB`) to also run
      `flutter test --tags fuzz` inside `packages/looper_repository`, so
      the [R16] mixed-enabled agreement test is genuinely CI-gated rather
      than silently skipped everywhere.
- [ ] This lands with this first Dart part so every later part
      (3b, 4, 5, 6, 7) is genuinely CI-gated [VGV-critical].

### T8 — Test enumeration (all new/extended tests this part ships)

- [ ] `FxAddress`: JSON round-trip for all four stages; canonical string is
      byte-stable and key-order-pinned; absent `lane` omitted; unknown keys
      ignored; equality/props.
- [ ] slotId invariants: minted on every repo write path for id-less
      entries; unique within a session; preserved across `copyWith`, param
      edit, reorder; legacy decode mints exactly once; persist→restore
      stable.
- [ ] `TrackEffect` both hierarchies: `enabled`/`slotId` through
      `toJson`/`fromJson`/`copyWith`/`props`; boundary mappers thread both
      fields in built-in AND plugin arms [R16]; legacy decode defaults
      enabled=true.
- [ ] `fxChainFingerprint`: enabled-bit changes the hash; slotId does not;
      mixed enabled/disabled agreement vs native (lane + monitor, fuzz-tag)
      [R16].
- [ ] Envelope: round-trip with meta; legacy bare-array decode (enabled
      defaults, fresh ids, chainEnabled=true); settings and clear-restore
      carry `chainEnabled` (disable → clear → restore → still disabled
      [R15]).
- [ ] Inheritance [R13]: edit input chain post-record → take chain
      byte-identical; `inheritedFrom` marker survives envelope round-trip;
      copied entries carry fresh slotIds.
- [ ] Inheritance × enabled [R18]: disabled slot copies disabled; both
      D-CHAINDIS dry shapes (empty chain, chain-disabled) bail and the lane
      keeps its prior chain.
- [ ] Overdub [A7]: overdub pass does not re-copy; divergence query flips
      true when input ≠ loop chain during overdub.
- [ ] Multi-input [A8]: concatenation in input order; provenance lists all
      inputs.
- [ ] Four-stage APIs: track/master setters update cache + engine (fake
      engine expectations); enabled setters work while stopped;
      re-apply-on-restart replays track/master chains + all chain flags.
- [ ] `LooperBloc` bloc_tests for the new Track/Master events; existing
      `MonitorCubit` suites still pass untouched (input-only proof).
- [ ] Migrated call sites: bootstrap restores both envelope and legacy
      strings; `monitor_migration` counts non-empty via envelope;
      `monitor_cubit` save/load round-trips the envelope;
      `session_mapping` decode accepts both formats.

### T9 — Logistics

- [ ] Create the child issue for this part (per the epic's build
      convention), labeled one `stage:*` + one `autonomy:*` — suggested
      `autonomy:auto` (fully verifiable by the listed suites, reversible,
      no UI taste); escalate to `plan-gate` if a model-shape call emerges
      that the pinned decisions don't cover.
- [ ] PR body carries `Closes #<child-issue>`, labels `stage:in-review` +
      autonomy + `ci:*` + `review:pending`; `ready-to-merge` only when CI is
      green AND `/code-review` is clean.

## Success Criteria

```success-criteria
GOAL: The FX v3 domain model — FxAddress + stable slotIds, enabled TrackEffects in both hierarchies, the chain envelope with legacy decode, pinned inheritance rules, four-stage repo APIs under LooperBloc — lands in looper_repository with real CI gates for the five domain packages.

SUCCESS CRITERIA:
- FxAddress canonical JSON declared once, byte-stable, round-trips all four stages; slotId invariants (mint-once, unique, stable across edits/persist) pinned by tests [A9][R19] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- TrackEffect carries enabled + slotId in BOTH hierarchies through the named boundary mappers + copyWith/props/toJson, with mapper tests covering built-in and plugin arms [R16] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- trackChainFingerprint fully renamed to fxChainFingerprint and folding the real enabled bit; agreement test covers mixed enabled/disabled chains [R16][VGV] | verify: ! grep -rn "trackChainFingerprint" lib packages test && /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Chain envelope {chainEnabled, meta, entries} owned by looper_repository wraps the engine codec; legacy bare-array decode defaults every level enabled; clear-restore carries the chain flag; the four named call sites decode the envelope and only the two 3b-earmarked session write sites still touch the engine codec under lib/ [R15] | verify: test "$(grep -rln "decodeTrackEffects\|encodeTrackEffects" lib/ | sort)" = "lib/session/session_mapping.dart" && /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository test/audio_setup
- Inheritance rules pinned by tests: by-value copy with provenance survives round-trip and never mutates takes [R13]; disabled copies disabled + both D-CHAINDIS dry shapes [R18]; overdub never re-inherits + divergence query [A7]; multi-input concatenation order + full provenance list [A8] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Four-stage repo APIs + re-apply-on-restart + settings persistence for track/master; LooperBloc owns Track/Master chain state, MonitorCubit stays input-only [VGV] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository test/looper test/audio_setup
- CI gates exist for all five domain packages with deliberate coverage floors, and the agreement test runs in CI via the fuzz job [VGV-critical] | verify: for p in looper_repository session_repository performance_repository pedal_repository controller_repository; do grep -q "packages/$p" .github/workflows/main.yaml || echo "MISSING $p"; done

NON-GOALS:
- Part 3b owns: session formatVersion 4→5 migration + SessionRig trackEffects/masterEffects + leftover reset [R17]; the PerformanceRepository.arm() fix + performanceChainsFromLooper + limiter cache [R14]; PerformanceChains/armSnapshot version marker [R20]; flipping the session write sites (session_mapping.dart:19,33) to envelope encode; docs/design/session-bundle-format.md v5 history.
- Parts 1a/1b own everything native: engine flags, track bus, inserts, plog, native fingerprint folding, ffigen bindings.
- Part 2 owns the wet cache (this part only guarantees fingerprints it can key on).
- Part 4 owns all UI: Signal-page stages, power controls, inherited badge + detach action, dead-code deletion, goldens.
- Parts 6/7 own the binding/mapping models that consume FxAddress canonical strings; part 5 owns the pedal projection reading chain-enabled state.

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository test/looper test/audio_setup
```

## Notes

- **No native changes in this part.** If a binding gap from parts 1a/1b
  surfaces (a missing enabled setter or fingerprint API), fix it in those
  parts' surface — and remember ffigen regen emits short-style formatting
  (whole-file churn): always run `dart format` after any regen.
- **Test runner gotcha:** the very_good MCP test tool is broken in this
  environment — use the absolute flutter path
  (`/Users/Tomas/development/flutter/bin/flutter`), as the verification
  commands already do. The agreement test self-skips without
  `LOOPY_ENGINE_LIB`; to run it locally:
  `export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"`.
- **Before opening the PR:** check the cspell dictionary for new vocabulary
  (`FxAddress`, `slotId`/`slotIds`, `chainEnabled`, envelope terms — the
  epic already added stomp/plog/FS-6/TRS) and the semantic PR title
  (`feat(domain): ...` must satisfy the semantic-PR check) — check both
  BEFORE CI does, not after it fails.
- **Stacked-PR squash landmines:** if this lands while 1a/1b PRs are still
  open, use per-part branches and rebase the child onto the parent's
  post-squash master state — squash breaks child merge-refs (CI silently
  absent) and API-side branch deletion auto-closes children. Part 3b stacks
  on this part: same discipline applies downstream.
- **Goldens:** none touched here (no UI). But the `LooperState` shape change
  can ripple into widget tests under `test/looper` / `test/audio_setup`
  fakes — fix fakes, do not regen goldens in this part (screenshot goldens
  are author-machine-only and belong to part 4's redesign pass).

### Risks

| Risk | Mitigation |
|------|------------|
| slotId in `props` breaks existing equality assertions wholesale | Audit test churn deliberately; compare via fingerprint where identity is not under test; minting at the repo boundary keeps const constructors alive |
| A boundary mapper silently drops `enabled`/`slotId` (round-trips as default) | The mappers are named tasks with dedicated tests on both arms [R16] — this is exactly why |
| Dart fingerprint fold drifts from 1b's native layout | Fold is copied from 1b's landed code, never re-derived; the mixed-enabled agreement test is the tripwire, now CI-gated via the fuzz job |
| Envelope strings written before every reader migrates | Read-side migrates first (the four pinned sites) in this part; session write flip deferred to 3b with the formatVersion bump — the grep criterion pins the seam |
| Legacy sessions/settings decode with missing fields | Bare-array fallback + enabled=true default + mint-once slotIds, all tested [R15] |
| Blind coverage floors block later parts or gate nothing | Measure per package first, pin at measured value, record floors in the PR |
| `LooperState` growth ripples through app fakes | Scoped verify includes `test/looper` + `test/audio_setup`; fix fakes in this PR |
