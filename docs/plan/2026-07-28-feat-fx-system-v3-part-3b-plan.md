---
title: "feat(session): format v5 migration, leftover reset, performance manifest stages"
type: feat
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

## Overview

The persistence tier of the four-stage FX model (Input → Loop → Track →
Master): session bundle format v4 → v5 with a lossless presence-keyed
migration, `SessionRig` + `applySession` leftover reset extended to the new
Track/Master stages and per-chain enabled flags [R17], settings persistence of
the new stages via the part-3a chain envelope string [R15], and the
performance arm manifest growing track/master fields, a presence-keyed version
marker [R20], and enabled bits [R3]. Closes with the overdue
`docs/design/session-bundle-format.md` rewrite (it documents v3 while the code
writes v4) brought to v5 with a full history section.

## Dependencies

Must be merged before this part starts:

- `docs/plan/2026-07-28-feat-fx-system-v3-part-0-plan.md` — CI package gates:
  per-package CI jobs for `looper_repository` / `session_repository` /
  `performance_repository` (among others) so this part's suites are genuinely
  CI-gated [VGV-critical].
- `docs/plan/2026-07-28-feat-fx-system-v3-part-3a-plan.md` — the domain half
  of Part 3 this part persists: `FxAddress` + canonical JSON serialization +
  stable slotIds [A9]; `TrackEffect` gains `enabled` + `slotId` in both
  hierarchies (mappers + `copyWith/props/toJson`) [R16]; the chain envelope
  `{chainEnabled, meta, entries}` with legacy bare-array decode, owned by
  `looper_repository` [R13][R15]; inheritance-by-value provenance meta
  [A6][R13]; four-stage chain APIs + enabled setters + caches in
  `looper_repository`; `LooperBloc` events for Track/Master [VGV];
  `fxChainFingerprint` (renamed from `trackChainFingerprint`) folding real
  enabled bits [R16]; the `PerformanceRepository.arm()` wiring fix +
  `performanceChainsFromLooper` + limiter state cache [R14].

## Context

Key files (line numbers from the current worktree):

- `packages/session_repository/lib/src/models/session.dart` —
  `Session.fromJson` presence-keyed loader (`:477`), `formatVersion = 4`
  (`:526`), writer stamps `'version': formatVersion` (`:608`). The v3→v4
  precedent to match: every added field is presence-keyed with a default, no
  version `switch`; `version > formatVersion` throws
  `SessionUnsupportedVersion`.
- `packages/session_repository/lib/src/session_repository.dart:29` —
  `SessionChains {laneChains, monitors}`, the save-side chain hand-off;
  `_sessionFrom(captured, chains)` (`:419`) builds the manifest.
- `packages/looper_repository/lib/src/models/session_rig.dart:131` —
  `SessionRig {baseLengthFrames, tracks, laneEffects, monitors, looperMode,
  primaryTrack, oneShotChannels}`.
- `packages/looper_repository/lib/src/looper_repository.dart:1042` —
  `applySession`, the ONE session-apply path (F2); the existing leftover-reset
  discipline for lanes/monitors lives around `:1272-1290` ("leftovers can
  never sound under the loaded session").
- `packages/looper_repository/test/looper_repository_test.dart:3150,3531,3567,3594`
  — the F2a/F2b/F2c leftover-reset test family to mirror.
- `lib/session/session_mapping.dart:13,42` — `chainsFromLooper` (save side)
  and `rigFromBundle` (load side), the only `SessionRig` construction site.
- `packages/performance_repository/lib/src/models/performance_chains.dart:10`
  — `PerformanceChains {laneChains, monitors, limiterEnabled,
  limiterCeiling}`; `PerformanceLaneChain` stores structured
  `TrackEffect.toJson` maps (the manifest is `daw_export`'s machine-readable
  record — NOT the opaque encoded string sessions use).
- `packages/performance_repository/lib/src/models/performance_manifest.dart:129`
  — `PerformanceArmSnapshot` (+ `fromJson`/`toJson`).
- `packages/performance_repository/lib/src/performance_repository.dart:133-174`
  — `arm()` builds and writes `arm-snapshot.json`.
- `lib/app/audio_bootstrap.dart:290` — boot-time chain restore from settings
  via `decodeTrackEffects(await settings.loadLaneEffects(...))`; the
  persistence-write twins are `lib/looper/bloc/looper_bloc.dart:368,382`
  (lanes) and `lib/audio_setup/cubit/monitor_cubit.dart:210,261,283`
  (monitors).
- `docs/design/session-bundle-format.md` — stale: documents `"version": 3`
  (`:56`) while the code writes v4.

Constraints pinned by the epic index (do not re-litigate):

- **Chain wire envelope [R13][R15]:** one codec everywhere —
  `{chainEnabled, meta, entries}` with legacy bare-array decode
  (chainEnabled = true, no meta). `SessionLaneChain.encoded` stays **opaque
  and unchanged** on the `session_repository` side; the envelope's
  encode/decode lives in `looper_repository` (part 3a) and the app-side
  mappers (`lib/session/session_mapping.dart`) bridge the two. Migration
  defaults **every level to enabled** [R15].
- **Migration invariants [flow SC-6]:** presence-keyed (matching
  `Session.fromJson`'s v3→v4 style); a v4 load under v5 code is
  **fingerprint-identical** (slotIds are NOT part of `fxChainFingerprint` —
  it folds params + enabled bits only [R16]); **save→load→save is
  idempotent** (fresh slotIds are minted once at legacy decode, persisted,
  never regenerated per load).
- **Leftover reset [R17]:** `applySession` must reset every remembered
  track/master chain and every chain-enabled flag the rig doesn't define —
  the F2 leftover class extended to the new stages.
- **Settings [R15]:** the new stages ride the same envelope string; the
  chain-level and per-slot enabled flags live INSIDE the string — **no new
  per-flag settings keys**.
- **Performance manifest [R20][R3]:** `PerformanceChains` + arm snapshot gain
  track/master fields + a **presence-keyed version marker** (absent = legacy,
  defaults enabled-true / stages-empty); manifest fx entries carry enabled
  bits so `le_pr_fx_chain_init_from_lane` seeds arm-time state. **Part 9 owns
  the `daw_export` reader side** — this part touches only the writer/model.
- **State ownership [VGV]:** `LooperBloc` owns Track/Master chain state;
  `MonitorCubit` stays input-only. Type ownership: `FxAddress`/slotIds live
  in `looper_repository`; `session_repository` never learns the envelope's
  insides.

## Tasks

### Session format v5 (`packages/session_repository`)

- [ ] Bump `Session.formatVersion` 4 → 5
      (`packages/session_repository/lib/src/models/session.dart:526`); the
      writer emits v5 manifests whose chain strings are part-3a envelopes
      (entries now carry `slotId` + `enabled`; `chainEnabled` + provenance
      meta ride the wrapper). Existing manifest keys for the Input/Loop
      stages keep their names (`monitors`, `laneChains`) — v5 re-documents
      them as the Input and Loop stages; renaming keys would be churn with no
      presence-keyed payoff.
- [ ] Add presence-keyed Track/Master fields to the manifest + `Session`
      model: per-channel track-stage chains and one master chain, each an
      opaque encoded envelope string (the `SessionLaneChain.encoded`
      pattern). A v4-or-earlier manifest simply lacks them → both stages
      load **empty** [R15].
- [ ] Presence-keyed migration in `Session.fromJson` (`:477`) — matching the
      v3→v4 precedent, no version `switch`: monitor chains load as the Input
      stage, lane chains as the Loop stage; legacy bare-array chain strings
      decode (at the `looper_repository` envelope layer) with
      `chainEnabled = true`, per-slot `enabled = true`, and **fresh slotIds
      minted once at decode**; track/master default empty. Zero data loss;
      the result is indistinguishable from a v5 session deliberately saved
      with those defaults. `version > 5` still throws
      `SessionUnsupportedVersion` (`:478-482`).
- [ ] `SessionChains` (`session_repository.dart:29`) gains track/master
      fields; `_sessionFrom` (`:419`) writes them into the manifest.
- [ ] Migration tests: v4 fixture load → chain content identical +
      `fxChainFingerprint`-identical to pre-migration (enabled defaults fold
      as 1) [flow SC-6]; save→load→save byte-idempotent at v5 (slotIds
      stable across the round-trip); v1/v2/v3 fixtures keep their existing
      lossless-load guarantees; unsupported-future-version still throws.

### SessionRig + leftover reset (`packages/looper_repository`) [R17]

- [ ] `SessionRig` (`models/session_rig.dart:131`) gains `trackEffects`
      (keyed by channel) + `masterEffects` + per-chain enabled flags for
      **every** stage (input monitors, loop lanes, track, master) — decoded
      data, since the flags travel inside the envelope strings.
- [ ] Save side: `chainsFromLooper`
      (`lib/session/session_mapping.dart:13`) includes the track/master
      chains + flags from `looper_repository`'s four-stage caches (part 3a);
      load side: `rigFromBundle` (`:42`) decodes the new manifest fields into
      the rig.
- [ ] `applySession` (`looper_repository.dart:1042`): extend the F2 reset —
      reset every remembered track/master chain and every chain-enabled flag
      the rig doesn't define, in the engine AND the repository caches,
      following the existing lane/monitor leftover reset at `:1272-1290`;
      then apply the rig's values.
- [ ] F2-style leftover test [R17]: session A with track + master FX and at
      least one disabled chain flag → load session B defining none → engine
      chain lengths zeroed, every chain flag back to its enabled default,
      repository caches clean (mirror the F2a/F2b/F2c shape at
      `looper_repository_test.dart:3150,3531,3567`).

### Settings persistence (`settings_repository` + app wiring) [R15]

- [ ] Add per-stage settings keys for track chains (per channel) and the
      master chain in `settings_repository`, following the
      `saveLaneEffects`/`loadLaneEffects` + `saveMonitorEffects` pattern.
      Values are envelope strings — chainEnabled and per-slot enabled ride
      inside; **no new per-flag keys**.
- [ ] Persist on change from `LooperBloc`'s track/master handlers (part 3a's
      events), mirroring the lane sites at
      `lib/looper/bloc/looper_bloc.dart:368,382`.
- [ ] Restore on boot in `lib/app/audio_bootstrap.dart` beside the lane
      restore (`:290`), applied through `looper_repository` so the caches and
      the engine agree.

### Performance manifest stages (`packages/performance_repository`) [R20][R3]

- [ ] `PerformanceChains` (`models/performance_chains.dart:10`) gains
      per-channel track-stage chains + a master chain + chain-enabled flags
      for all four stages; `PerformanceLaneChain` /
      `PerformanceMonitorState` gain `chainEnabled`. Per-slot `enabled` +
      `slotId` arrive for free via `TrackEffect.toJson` (part 3a) — the
      manifest keeps its structured-JSON (not opaque-string) convention.
- [ ] `performanceChainsFromLooper` (part 3a, in
      `lib/session/session_mapping.dart`) fills the new fields from the
      four-stage caches.
- [ ] `PerformanceArmSnapshot` (`models/performance_manifest.dart:129`) gains
      track/master chain fields + a **presence-keyed version marker** [R20]:
      `fromJson` treats an absent marker as legacy (stages empty, everything
      enabled); no version `switch`, matching the session precedent.
- [ ] `arm()` (`performance_repository.dart:133-174`) writes the extended
      snapshot; the manifest now carries every enabled bit so
      `le_pr_fx_chain_init_from_lane` can seed arm-time bypass state on
      replay [R3]. **Writer/model side only — `daw_export`'s reader for the
      new stages and the stomp export-replay test are part 9** [R20][R3].
- [ ] Tests: arm-snapshot round-trip with track/master chains, disabled
      entries, and disabled chain flags; legacy arm-snapshot JSON (no
      marker) still parses with legacy defaults; enabled bits survive
      `toJson`/`fromJson`.

### Documentation

- [ ] `docs/design/session-bundle-format.md` v5 rewrite: the four stages,
      the envelope schema (`chainEnabled`/`meta`/`entries`, slotIds,
      legacy bare-array decode), the new track/master manifest fields, the
      presence-keyed migration rules and invariants (fingerprint-identical
      load, save→load→save idempotence), plus a **full version-history
      section v1 → v5** — the doc currently stops at v3, so the history must
      also recover v4 (tempo grid / click / count-in, per
      `session.dart:519-527`'s doc comment).

## Success Criteria

```success-criteria
GOAL: Four-stage FX state persists everywhere it must — session bundles (v5, presence-keyed migration), settings, and the performance arm manifest — with no leftovers across session loads and no data loss from any older format.

SUCCESS CRITERIA:
- Session v5: v4 fixture loads fingerprint-identical with enabled/slotId defaults, track/master empty; save→load→save idempotent; v1-v3 fixtures still lossless; future versions rejected [flow SC-6][R15] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository
- Leftover reset: SessionRig carries trackEffects/masterEffects + per-chain flags through capture/rigFromBundle/chainsFromLooper; applySession resets every undefined track/master chain and chain flag (F2-style test green) [R17] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Performance manifest: PerformanceChains + armSnapshot round-trip track/master fields, chain flags, per-slot enabled bits; presence-keyed marker keeps legacy snapshots parsing [R20][R3] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/performance_repository
- Settings: track/master chains + flags persist and restore via the envelope string alone — no new per-flag keys [R15] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository packages/looper_repository packages/performance_repository

NON-GOALS:
- The domain model itself — FxAddress, slotIds, envelope codec, enabled fields, inheritance provenance, the arm() wiring fix (part 3a owns all of it)
- Engine enabled flags, track bus, master insert (part 1); wet cache (part 2)
- daw_export reader for the new manifest stages + the stomp export-replay test (part 9 [R20][R3])
- Any UI: Signal-page stages, enable toggles, badges (part 4)
- Pedal protocol/mode (part 5), remap/momentary (part 6), expression mapping persistence (part 7)
- CI package-gate jobs (part 0)

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository packages/looper_repository packages/performance_repository
```

## Notes

- **Test runner gotcha:** the very_good MCP test tool is broken in this repo —
  always invoke `/Users/Tomas/development/flutter/bin/flutter test` (absolute
  path) directly. See `docs/PROGRESS.md` "How to build / test".
- **No native surface expected:** this part is pure Dart. If any
  `loopy_engine` API does end up churning, remember ffigen regen emits
  short-style formatting → run `dart format` on the generated bindings or the
  diff drowns (documented in `ffigen.yaml`).
- **Idempotence trap:** fresh slotIds for legacy entries must be minted
  exactly once (at decode) and then persisted — regenerating on every load
  silently breaks the save→load→save invariant AND churns nothing visible in
  fingerprints (slotIds are excluded from `fxChainFingerprint`), so only the
  dedicated idempotence test catches it.
- **Envelope opacity boundary:** `session_repository` must not learn the
  envelope's insides — encoded strings stay opaque there; decode happens in
  `looper_repository` / `lib/session/session_mapping.dart`. Keep the
  dependency arrows clean [VGV].
- **testWidgets stream-cancel hang:** `await sub.cancel()` inline in a test
  body can hang forever (flutter/flutter#139870) — use `unawaited(...)` or
  cancel in `tearDown`.
- **Before opening the PR:** check the cspell dictionary (plog, slotId, and
  any new manifest key vocabulary) and the semantic-PR-title check — the
  title `feat(session): ...` must pass the repo's semantic rule.
- **Stacked-PR landmines:** this branch stacks on part 3a. After 3a
  squash-merges, the child's merge-ref CI can silently vanish — rebase onto
  the updated base and confirm CI actually ran; never delete the parent
  branch via the API (it closes the child PR).
- **Goldens:** no UI in this part — screenshot goldens are untouched (they
  are author-machine-only; irrelevant here, noted so nobody "regenerates"
  them incidentally).
- **PR hygiene:** body carries `Closes #<child issue>` for this part's child
  issue under epic #351; labels `stage:in-review`, the issue's `autonomy:*`,
  `ci:*` + `review:pending` per `docs/TRACKING.md`.
