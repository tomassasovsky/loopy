---
title: feat: Sheeran-style FX racks — part 2 (domain + session migration)
type: feat
date: 2026-07-26
issue: 351
part: 2
---

## feat: Sheeran-style FX racks — part 2 (domain + session migration) - Standard

> Epic index: [2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md](2026-07-26-feat-sheeran-style-fx-racks-pre-post-plan.md)
> Issue: [#351](https://github.com/tomassasovsky/loopy/issues/351)
> Branch: `feat/sheeran-style-fx-racks`

## Dependencies

**Requires part 1 merged** (native Pre/Post + Live Signal API / shims).

## Overview

Expose Pre/Post chains and Live Signal in Dart domain (`looper_repository`), bump
session schema, migrate old Input/Lane FX → Post chains, and retire
snapshot-on-record as the primary path. No dedicated FX page yet (part 3).

## Problem Statement / Motivation

Part 1 makes the engine Sheeran-capable; Dart still speaks single stageless
monitor/lane chains and snapshots on record. Without domain + session migration,
UI and persistence cannot use Pre/Post safely.

## Proposed Solution

### Domain model (prefer extend, not new hierarchy)

On `InputMonitor` (or successor fields):

- `List<TrackEffect> preEffects`, `List<TrackEffect> postEffects`

On track (channel-level; not per-lane until Phase 5):

- `List<TrackEffect> preEffects`, `List<TrackEffect> postEffects`
- `LiveSignalMode liveSignal` (`off` / `auto` / `on`)

Until lane overrides exist: repository pushes **track** Pre/Post to the engine
for that channel; lane-level `Lane.effects` become a migrated view of track Post
(lane 0 wins if lanes disagree — document in migration).

### Repository APIs

- `setInputPreEffects` / `setInputPostEffects` (+ param helpers)
- `setTrackPreEffects` / `setTrackPostEffects`
- `setTrackLiveSignal` / `setLiveSignalFocus` (from presentation selection)
- Keep old `setMonitorEffects` / `setLaneEffects` as **Post shims** during
  transition; mark `@Deprecated` or doc as Post-only
- **Disable** `_snapshotMonitorChainsOntoLanes` for new records once Pre/Post
  APIs are the source of truth (bridge: if only legacy fields present, migrate
  in-memory then stop snapshotting)

### Session persistence (critical layering)

- Bump `Session.formatVersion` to **5** in
  `packages/session_repository/lib/src/models/session.dart`
- Add **opaque** fields (encoded strings/JSON blobs) for input/track pre/post +
  liveSignal — **do not** import `TrackEffect` into `session_repository`
- Update `lib/session/session_mapping.dart` (`chainsFromLooper` / `rigFromBundle`)
- v4 load path: Input FX → Input **Post**; Lane FX → Track **Post** (epic P4)
- Extend `test/session/session_fx_roundtrip_test.dart` + session_repository tests

### FFI / AudioEngine

- Expose new setters in `packages/loopy_engine/lib/src/audio_engine.dart`
- Run `dart run ffigen --config ffigen.yaml` + `dart format` on bindings after
  API edits (per `docs/PROGRESS.md`)

### Tasks

- [ ] Models + `LiveSignalMode` enum in `looper_repository`
- [ ] Repository setters + engine push; retire snapshot-as-primary
- [ ] Session v5 + opaque encoding + mapping
- [ ] Migration tests (v4→v5, lane conflict policy)
- [ ] Bloc/Cubit events minimal surface for Live Signal focus (enough for part 3)
- [ ] Update `SessionRig` / apply path
- [ ] Unit tests: `packages/looper_repository/test/` named `FxRack` / PrePost

## Technical Considerations

- **Architecture:** Presentation must not call repository FX setters from widgets
  in part 3; part 2 may add Bloc events that part 3 consumes.
- **Performance:** Negligible vs DSP.
- **Security:** Opaque session blobs — validate length/count on decode.

## Success Criteria

```success-criteria
GOAL: Dart domain and sessions speak Input/Track Pre+Post + Live Signal; old sessions migrate to Post without data loss; snapshot-on-record is no longer primary.

SUCCESS CRITERIA:
- Repository Pre/Post + Live Signal unit tests pass | verify: cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test --name "FxRack|PrePost|LiveSignal"
- Session v4 fixtures migrate to v5 Post racks; roundtrip preserves chains | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_fx_roundtrip_test.dart packages/session_repository/test --name "rack|migration|FxRack|formatVersion"
- Snapshot-on-record is not invoked for new empty-track records when Pre/Post fields are authoritative | verify: cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test --name "snapshot|PrePost"
- AudioEngine exposes Pre/Post/Live Signal setters used by repository | verify: rg -n "setInput.*[Pp]re|setTrack.*[Pp]ost|LiveSignal|live_signal" packages/loopy_engine/lib/src/audio_engine.dart packages/looper_repository/lib
- Analyzer clean on touched packages | verify: /Users/Tomas/development/flutter/bin/flutter analyze packages/looper_repository packages/session_repository packages/loopy_engine lib/session
- FFI bindings regenerated if API changed | verify: manual 1) after native header edits run `cd packages/loopy_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/loopy_engine_bindings.dart` 2) commit bindings with the PR

NON-GOALS:
- Dedicated FX page UI
- Factory presets
- daw_export Pre/Post manifest (part 5)
- Per-lane overrides

VERIFICATION COMMAND: cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test --name "FxRack|PrePost|LiveSignal|snapshot" && cd ../.. && /Users/Tomas/development/flutter/bin/flutter test test/session/session_fx_roundtrip_test.dart --name "rack|migration|FxRack|formatVersion" && /Users/Tomas/development/flutter/bin/flutter analyze packages/looper_repository packages/session_repository packages/loopy_engine lib/session
```

> Adjust `--name` filters to match actual test names landed in the PR. Snapshot
> bridge may remain one release for old in-flight clients — document removal
> date in the PR.

## Success Metrics

- Existing saved sessions open without crash; playback tone matches pre-migration
  Post-equivalent chains
- New sessions persist pre/post + liveSignal across restart

## Dependencies & Risks

- Part 1 native API
- Migration surprise: old “prints into new takes” copy → Post default (P4) —
  document in release notes (part 5/docs)
- Lane disagreement on multi-lane tracks: lane 0 wins for Track Post migration

## References & Research

- Epic + part 1 plans
- `packages/looper_repository/lib/src/looper_repository.dart`
- `packages/session_repository/lib/src/models/session.dart`
- `lib/session/session_mapping.dart`
- `test/session/session_fx_roundtrip_test.dart`
