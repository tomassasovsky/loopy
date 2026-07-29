---
title: "fix: PerformanceRepository.arm() gets real chains (standalone)"
type: fix
date: 2026-07-28
issue: 351
parent-plan: 2026-07-28-feat-fx-system-v3-plan.md
---

> **Session setup:** Opus at medium effort · `autonomy:auto` · check the status table in [the execution guide](2026-07-28-feat-fx-system-v3-execution-guide.md) before starting, and update it before ending.

## Overview

`PerformanceRepository.arm()` accepts a `PerformanceChains` snapshot but every
call site passes nothing, so exported wet stems are identical to dry stems and
DAW device chains come out empty (epic Problem Statement #6;
`packages/performance_repository/lib/src/performance_repository.dart:133-135`).
This part lifts the arm()-fix bullet from Part 3 [R14] and ships it standalone,
scoped to **today's** chains only (lane + monitor + limiter — no track/master
fields, no FX v3 dependency): add `performanceChainsFromLooper(...)` beside
`chainsFromLooper` in `lib/session/session_mapping.dart`, give
`LooperRepository` a limiter state cache + getter, and wire both `arm()` call
sites. Pre-existing bug fix; ships first, before any FX v3 part.

## Dependencies

- None. This part is standalone off `master` — no other part file must merge
  first, and no FX v3 part depends on landing order beyond "this ships first."
  (Part 3's `-part-3-plan.md` later extends `PerformanceChains` with
  track/master fields + a presence-keyed version marker [R20] on top of this.)

## Context

Key files:

- `packages/performance_repository/lib/src/performance_repository.dart:133-135`
  — `arm({PerformanceChains chains = const PerformanceChains()})`; the
  repository side already consumes the chains correctly (arm snapshot at
  :152-164 records `limiterEnabled`/`limiterCeiling` and the chains into
  `arm-snapshot.json`). The bug is purely that no caller supplies them.
- `packages/performance_repository/lib/src/models/performance_chains.dart` —
  `PerformanceChains { laneChains, monitors, limiterEnabled = false,
  limiterCeiling = 0.99 }`. Note `PerformanceLaneChain.effects` /
  `PerformanceMonitorState.effects` hold **engine** `TrackEffect`s
  (`package:loopy_engine`), not the domain hierarchy.
- `lib/session/session_mapping.dart:13-36` — `chainsFromLooper(looper)`, the
  pattern to mirror: lanes from `looper.allLaneEffects()`, monitors from
  `looper.allMonitors().values` (every **configured** monitor, not just
  FX-bearing ones — a dry-but-enabled monitor must be captured too).
- `packages/looper_repository/lib/src/looper_repository.dart:582` — the only
  limiter write: `..setLimiter(enabled: true)` inside `startEngine`, ceiling
  left at the engine default `0.99`
  (`packages/loopy_engine/lib/src/audio_engine.dart:457`). The engine limiter
  surface is **write-only** — snapshot read-back is not an option, so a
  repository-side cache is the only source of truth [R14].
- `packages/looper_repository/lib/src/looper_repository.dart:1333` /
  `:1347` — `allLaneEffects()` / `allMonitors()`, the enumeration sources.
- `packages/looper_repository/lib/src/models/track_effect.dart:288,307` —
  `_trackEffectToEngine` / `_trackEffectFromEngine` are **library-private**;
  the public delegation surface is `encodeTrackEffects` (domain →
  wire string, :335) and `loopy_engine`'s `decodeTrackEffects` (wire string →
  engine models). The wire codec is the declared single source of truth.
- Call sites to wire:
  `lib/performance/cubit/performance_recorder_cubit.dart:201`
  (`toggleArm` → `await _performance.arm();`) and
  `lib/control/cubit/control_cubit.dart:653` (`togglePerformanceRecord` →
  `unawaited(_performance.arm());`).
- `lib/performance/cubit/performance_recorder_cubit.dart:37-51` —
  `PerformanceRecorderCubit` deliberately does **not** take a
  `LooperRepository`; it uses narrow injected function dependencies
  (`currentTempoBpm` precedent), wired at the composition root
  `lib/app/view/app.dart` (`ControlCubit` at :289,
  `PerformanceRecorderCubit` at :335).

Constraints lifted from the index (relevant to this part only):

- **[R14] pinned decision:** add `performanceChainsFromLooper(...)` beside
  `chainsFromLooper` in `lib/session/session_mapping.dart`, building
  `PerformanceChains` directly (domain → engine effects via the existing
  per-effect delegation; monitors from `allMonitors()`); give
  `LooperRepository` a limiter state cache + getter (today hard-coded
  `{true, 0.99}` at the `setLimiter` call — engine surface is write-only),
  re-applied on `startEngine`; wire both call sites.
- **NO track/master fields** on `PerformanceChains`/`armSnapshot` and no
  version marker — that is part 3 [R20]. No enabled bits in the arm manifest
  — that rides part 3's enabled work [R3]. No `daw_export` reader changes —
  part 9.
- **[VGV] feature boundary:** `lib/control/` must not import `lib/session/`;
  cross-feature access goes through injected dependencies wired at the
  composition root.
- **CI reality (index [VGV-critical], assigned to part 3):** the
  `looper_repository` / `performance_repository` package suites have **no CI
  jobs today** — only the root app Dart job (which gates `test/` with
  `min_coverage` 90) and `daw_export` run. Package suites are verified
  locally via the verification command; put the new mapping/cubit tests under
  `test/` where CI actually sees them. Do not pull part 3's CI-gate task into
  this part.

## Tasks

- [ ] **LooperRepository limiter cache + getter**
  - [ ] Add private cache fields defaulting to today's effective state:
        `_limiterEnabled = true`, `_limiterCeiling = 0.99` (hard-coded
        `{true, 0.99}` today [R14]).
  - [ ] `startEngine` re-applies from the cache instead of literals:
        `..setLimiter(enabled: _limiterEnabled, ceiling: _limiterCeiling)`
        (`looper_repository.dart:582`) — behavior-identical today; keep the
        existing "safety default" comment, updated to point at the cache.
  - [ ] Public read surface (e.g. `bool get limiterEnabled` / `double get
        limiterCeiling`), doc-commented: the engine limiter surface is
        write-only (no snapshot read-back), so this cache is the only truth a
        caller can read. No public setter in this part — nothing writes the
        limiter yet; the cache exists so `arm()` can record the real state.
  - [ ] Package tests (`packages/looper_repository/test/`): getters read
        `{true, 0.99}`; `startEngine` pushes the cached values to the engine
        (extend the existing start/re-apply coverage).
- [ ] **`performanceChainsFromLooper` in `lib/session/session_mapping.dart`**
  - [ ] `PerformanceChains performanceChainsFromLooper(LooperRepository
        looper)` beside `chainsFromLooper` [R14], with a doc comment mirroring
        its "the rig is the truth being saved" rationale.
  - [ ] `laneChains`: for each `looper.allLaneEffects()` entry, a
        `PerformanceLaneChain(channel, lane, effects)` with **engine**
        effects. Domain → engine conversion uses the existing public
        delegation — round-trip through the wire codec
        (`engine.decodeTrackEffects(encodeTrackEffects(effects))`), which is
        lossless by design (session saves rely on it). If taste prefers, a
        public `trackEffectsToEngine` export from `looper_repository` wrapping
        the private mapper is an acceptable substitute — either satisfies
        [R14]; do **not** hand-duplicate the per-field mapping in app code.
  - [ ] `monitors`: for each `looper.allMonitors().values` entry, a
        `PerformanceMonitorState(input, enabled, outputMask, volume, muted,
        effects)` — same "every configured monitor" rule as
        `chainsFromLooper:22-34`, same effects conversion.
  - [ ] `limiterEnabled` / `limiterCeiling` from the new repository getters.
  - [ ] App tests (`test/session/session_mapping_test.dart`, existing file):
        lane chains map with correct channel/lane and engine-model fidelity
        (built-in params and plugin ref/state/name survive); monitors carry
        routing/mix; dry-but-enabled monitor included; limiter reads
        `{true, 0.99}`; empty rig maps to empty chains with limiter still
        real.
- [ ] **Wire both call sites via an injected provider**
  - [ ] `PerformanceRecorderCubit`: new narrow dependency `PerformanceChains
        Function() currentChains` defaulting to a `const
        PerformanceChains()` provider (match the `currentTempoBpm`
        precedent and its doc-comment style,
        `performance_recorder_cubit.dart:37-51`); `toggleArm` passes
        `chains: _currentChains()` at :201.
  - [ ] `ControlCubit`: same injected `PerformanceChains Function()`
        dependency; `togglePerformanceRecord` passes it at :653. Do not
        import `lib/session/` from `lib/control/` [VGV] — the cubit already
        holds `_looper`, but the mapping function lives in the session
        feature, so the provider is injected, not called directly.
  - [ ] Composition root `lib/app/view/app.dart` wires
        `() => performanceChainsFromLooper(looper)` into both cubits
        (`ControlCubit` :289, `PerformanceRecorderCubit` :335).
  - [ ] App tests: `test/performance/cubit/` — `toggleArm` forwards the
        provider's chains to `arm(chains: ...)` (mocktail capture);
        `test/control/control_cubit_test.dart` — `togglePerformanceRecord`
        does the same; default-provider paths keep existing tests green.
- [ ] **Verification sweep**: run the directive suites
      (`packages/performance_repository`, `packages/looper_repository`) plus
      the app suites touched (`test/session`, `test/performance`,
      `test/control`); confirm root-app coverage (min_coverage 90) still
      passes with the new lines covered.

## Success Criteria

```success-criteria
GOAL: Every PerformanceRepository.arm() call records the real lane/monitor chains and master-limiter state, so performance captures stop snapshotting an empty rig.

SUCCESS CRITERIA:
- LooperRepository caches limiter state {true, 0.99}, exposes getters, and re-applies the cache on startEngine (write-only engine surface worked around) [R14] | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- performanceChainsFromLooper builds PerformanceChains from allLaneEffects() + allMonitors() with lossless domain-to-engine effect conversion and real limiter state [R14] | verify: /Users/Tomas/development/flutter/bin/flutter test test/session
- Both arm() call sites (performance_recorder_cubit.dart:201, control_cubit.dart:653) pass the provider's chains; no lib/control import of lib/session [VGV] | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance test/control
- Package suites named by the scope directive stay green end-to-end | verify: /Users/Tomas/development/flutter/bin/flutter test packages/performance_repository packages/looper_repository

NON-GOALS:
- Track/master fields on PerformanceChains + the armSnapshot presence-keyed version marker — part 3 owns them [R20]
- Enabled bits in the arm manifest (rides part 3's enabled/slotId work [R3]); chain envelope, FxAddress, slotIds — part 3
- daw_export reader changes for new stages — part 9
- Any engine/native change, any UI, any limiter setter/UI (nothing writes the limiter yet)
- Package CI jobs for looper_repository/performance_repository — part 3's [VGV-critical] CI-gate task

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test packages/performance_repository packages/looper_repository
```

## Notes

- **No native code in this part** — no ffigen regen / `dart format` churn
  applies. If a build detour ever touches `loopy_engine`'s native surface,
  stop: that is out of scope here.
- **Test runner gotchas:** invoke flutter by absolute path
  (`/Users/Tomas/development/flutter/bin/flutter`) — the very_good MCP test
  runner is broken in this repo. Avoid `await sub.cancel()` inline in any
  `testWidgets` body (known hang, flutter/flutter#139870) — use
  `unawaited()`/`tearDown()`; the new tests here are plain cubit/unit tests,
  so this should not arise.
- **Before opening the PR:** check the cspell dictionary (this part should
  need no new vocabulary, but confirm — "disarm"/"stomp" class words) and the
  semantic PR title (`fix: ...`). Label per `docs/TRACKING.md`: child issue
  under epic #351, `stage:in-review`, `ci:*` + `review:pending`; autonomy is
  a judgment at issue creation — this is verifiable, reversible, and narrow
  (an `autonomy:auto` candidate), but the epic is `plan-gate`, so confirm.
  Put `Closes #<child-issue>` in the PR body.
- **Stacked-PR landmines do not apply** (this branches straight off
  `master`, no parent PR), but part 3 will later churn the same functions
  (`PerformanceChains` fields, arm snapshot) — merge this part first and let
  part 3 rebase on the squash-merged result, not on this branch.
- **Goldens:** not relevant — no UI change, no screenshot goldens to regen.
- **CI visibility:** only the app-level tests (`test/session`,
  `test/performance`, `test/control`) are CI-gated today (root app Dart job,
  min_coverage 90). The package-suite runs in the verification command are a
  local gate until part 3 adds package CI jobs — run them, do not assume CI
  covers them.
- The `arm-snapshot.json` write path and `PerformanceArmSnapshot` already
  handle a populated `PerformanceChains`
  (`performance_repository.dart:152-164`) — expect no repository-side
  changes in `performance_repository`; its suite runs to prove no
  regression, not because it changes.
