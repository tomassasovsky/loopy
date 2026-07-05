---
title: "fix: FX state robustness — one owner, sessions carry chains, fuzzed"
type: fix
date: 2026-07-04
---

## fix: FX state robustness — Standard

> **Status (2026-07-04):** planned from the bug-hunt findings in
> docs/brainstorm/2026-07-04-fx-state-robustness-brainstorm-doc.md. Builds
> AFTER PR #108 merges (F4 — dry-monitor wipe — is already fixed there; the
> ControlCubit consolidation also settles the layering conventions this plan
> follows). New branch off master, e.g. `fix/fx-state-robustness`.

## Overview

FX chains currently live in four stores — engine, `LooperRepository` Dart
caches (what the UI renders), settings (boot replay), and the session bundle
(which omits them entirely) — with no ownership or invalidation rules.
Symptoms: selection shows wrong, chains lost after recording / save-load /
restart, session B playing through session A's leftover chains.

Apply the control-state recipe: ONE Dart owner (`LooperRepository`) with
written rules, session apply flowing through that owner (composed at the
bloc level per the layered architecture — repositories never import
repositories), manifest v2 that carries chains, persist-on-every-write, and
an engine chain fingerprint so the invariant spec + fuzzer police the whole
thing.

## Context / findings

See the brainstorm doc for the full store table and evidence. Key code:

- `packages/looper_repository/lib/src/looper_repository.dart` — `_laneEffects`
  / `_monitorEffects` caches; `LooperState.lanes[].effects` built from the
  cache (line ~387); `_snapshotMonitorChainsOntoLanes` (record-time mirror);
  restart replay (~line 460).
- `packages/session_repository/lib/src/session_repository.dart` — `save` /
  `load` drive the ENGINE directly (`clear/importTrack/setLaneVolume/
  setLaneMute`); no FX anywhere; `Session` model in `src/models/session.dart`.
- `lib/looper/bloc/looper_bloc.dart` (~line 330) — `saveLaneEffects` persisted
  only on explicit UI edits.
- `lib/app/audio_bootstrap.dart` (~line 140) — boot replay of persisted chains.
- Engine: `handle_clear` keeps lane chains (engine_process.c:443); only
  create/configure resets `a_fx_count` (engine.c:129); snapshot exposes no
  chain readback (only `fx_added_latency_frames`).

## Acceptance Criteria

- [ ] Save session with lane + monitor chains (built-in and plugin entries) →
      clear rig → load → chains, volumes, mutes all restored; engine, cache,
      and settings agree (fingerprint-verified in tests).
- [ ] Loading a session fully resets chains the session does not define —
      session A's leftovers can never play under session B.
- [ ] Device reconnect / engine restart after a session load replays the
      LOADED state, not pre-load caches.
- [ ] Record a take through a monitor chain → restart loopy → the lane plays
      back and displays the take's chain (persisted at snapshot-copy time).
- [ ] Legacy (v1) session bundles still load (no chains → explicitly cleared
      chains, not leftovers).
- [ ] Cold boot with plugin chains: entries render a distinct
      loading/unavailable state until the scan lands; a completed scan
      rebinds without user action (existing `_ensureRestoredPluginsLoaded`
      path covered by a test).
- [ ] Fuzzer alphabet includes FX actions; a chain-fingerprint invariant
      (`cache == engine`) holds across every fuzzed sequence.
- [ ] `flutter analyze` clean; full suite + package suites green; coverage
      ≥ 90; native suite ALL PASSED; fuzz job ≤ 2 min.

## Tasks

### Phase A — session apply flows through the owner (F2)

- [ ] `SessionRepository` splits file I/O from engine driving: `load()`
      becomes `read(directory) -> (Session, stems)` (pure decode + validation,
      incl. the sample-rate check); `save()` gains a parameter object carrying
      the mix/chain data to write (it no longer reads mix state off the
      engine snapshot alone).
- [ ] `LooperRepository.applySession(Session, stems)` — the ONE apply path:
      clear via its own `clear()` (so `_forgetLaneMutes` runs), await settled,
      import stems, set volumes/mutes/chains through the cached setters (so
      `_laneVolume/_laneMute/_laneEffects` stay truthful), and explicitly
      reset chains the session does not define (lane + monitor). Restart
      replay then reproduces the loaded session by construction.
- [ ] `SessionCubit` composes the two repositories (bloc-level composition,
      per the layered architecture): read → apply on load; gather
      chains/mix from `LooperRepository` → hand to `save`. It gains the
      `LooperRepository` dependency in `looper_page.dart` wiring.
- [ ] Tests: reconnect-after-load replays loaded values; pre-load persisted
      lane mutes do not resurrect at next boot; leftover-chain reset.

### Phase B — sessions carry FX (F1)

- [ ] `Session` model v2: `formatVersion`, per-track per-lane encoded chains
      (reuse `encodeTrackEffects` — plugin entries carry id + params +
      captured opaque state exactly as settings do), per-input monitor
      chains, monitor routing/volume/mute. v1 bundles load with empty chains.
- [ ] Save path captures chains from `LooperRepository` (via `SessionCubit`),
      not from settings — the live rig is the truth being saved.
- [ ] Round-trip tests: built-in chains, plugin chains (mock plugin host),
      v1-manifest compatibility.

### Phase C — persist on every chain write (F3)

- [ ] `LooperRepository` exposes a `laneChainChanged` notification (same
      synchronous-callback pattern as domain stores elsewhere) fired by
      `_snapshotMonitorChainsOntoLanes` and any internal chain mutation;
      `LooperBloc` subscribes and persists via `saveLaneEffects` — the bloc
      stays the only settings writer for chains.
- [ ] Test: record through a monitor chain → assert the persisted encoded
      chain equals the lane's post-take chain.

### Phase D — visibility + the safety net (F5, F6)

- [ ] Engine: per-lane and per-monitor chain FINGERPRINT (order-sensitive
      hash of fx types + param blocks) in the snapshot (additive ABI).
- [ ] Debug assert in the repository poll: every cached chain's fingerprint
      matches the snapshot's (mirrors `debugControlInvariantsHold`).
- [ ] Fuzzer: FX actions in the alphabet (set/clear lane chain, set monitor
      chain, record-over, session save+load via a temp dir) + the
      fingerprint invariant; corpus entries for F1/F2/F3 repros.
- [ ] Plugin boot UX: placeholder entries render as "loading…" until the
      scan resolves, "unavailable" (distinct style) on failure, with a retry
      affordance; widget test for both states.

## Files touched (primary)

`packages/session_repository/lib/src/{session_repository,models/session}.dart`,
`packages/looper_repository/lib/src/looper_repository.dart`,
`lib/session/cubit/session_cubit.dart`, `lib/looper/view/looper_page.dart`,
`lib/looper/bloc/looper_bloc.dart`, `lib/app/audio_bootstrap.dart`,
`packages/loopy_engine/src/core/{engine_snapshot.c,loopy_engine_api.h}` (+
ffigen regen + `dart format`), signal-graph FX row widgets (F5 states),
`test/fuzz/control_sequence_fuzz_test.dart` + new `test/fuzz` FX corpus,
mirrored test files throughout.

## Verification

1. Native suite: `bash packages/loopy_engine/src/test/run_native_tests.sh`.
2. `flutter test` + `flutter test packages/...` (looper, session) + coverage.
3. Fuzz: `export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"`,
   `flutter test --tags fuzz` (+ one extended fresh-seed sweep).
4. Manual: stage FX → save → clear-all → load → listen + inspect; record a
   take through a monitor chain → restart → listen; load session B over
   session A with different chains.

## Dependencies & Prerequisites

- PR #108 merged (contains F4 — the dry-monitor fix — and the ControlCubit
  layering this plan's composition rules follow). Re-test the reported
  "lost after clear + record" symptom on that build first; it should already
  be gone.
- No new packages; fingerprint is an additive engine ABI change (new
  snapshot fields only).

## Notes / accepted trade-offs

- Master output has NO engine FX chain today — "master FX" symptoms need a
  concrete repro; out of scope here (tracked as an open question in the
  brainstorm doc).
- Multi-lane session stems remain lane-0-only (existing documented
  follow-up); chains are still saved for ALL lanes since they exist
  independent of audio.
- Fingerprint is for divergence DETECTION, not full chain readback — the
  repository stays the Dart-side owner; the engine confirms, never narrates.
