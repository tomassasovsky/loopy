---
date: 2026-07-13
topic: export-engineperformancecapture-barrel
---

# Export EnginePerformanceCapture from loopy_engine barrel

## What We're Building

`packages/loopy_engine/lib/src/audio_engine.dart` defines `AudioEngine` as a
composition of role-segregated interfaces, explicitly documented as enabling
"a consumer can depend on the slice it needs ... instead of the whole
surface." Every role interface in that `implements` clause is re-exported
from the package barrel `lib/loopy_engine.dart` except one:
`EnginePerformanceCapture` (perfArm/perfDisarm/renderBegin/renderPoll/
renderTrackStatuses/renderCancel). Consumers who only need the
performance-capture slice currently cannot import it through the public
barrel and must reach into `package:loopy_engine/src/audio_engine.dart`,
which trips the repo's `implementation_imports` lint.

The fix is to add `EnginePerformanceCapture` to the `show` list of the
`export 'src/audio_engine.dart'` statement in `lib/loopy_engine.dart`,
keeping the list alphabetically ordered to match the existing convention.

## Why This Approach

This is a single, mechanical, additive export fix — there is no alternative
design worth weighing. The only decision point was verifying scope:

- Re-read `lib/loopy_engine.dart` (current state, 61 lines) and confirmed the
  `src/audio_engine.dart` show-list is exactly: `AudioEngine, EffectsControl,
  EngineException, EngineLifecycle, EngineMetering, EnginePluginHosting,
  EngineResult, EngineRouting, LooperTransport, MasterBusControl,
  MonitorControl, SessionIo` — `EnginePerformanceCapture` is indeed absent.
- Re-read `lib/src/audio_engine.dart`'s `AudioEngine implements` clause
  (lines 613-624): `EngineLifecycle, EngineMetering, LooperTransport,
  EngineRouting, MasterBusControl, EffectsControl, MonitorControl,
  EnginePluginHosting, EnginePerformanceCapture, SessionIo`. Every one of
  these 9 role interfaces is already exported from the barrel except
  `EnginePerformanceCapture` — confirming it is the *only* missing role
  interface. No other gap to flag.

Fix direction: add `EnginePerformanceCapture` alphabetically (it sorts
between `EnginePluginHosting` and `EngineResult` — "EnginePerformanceCapture"
< "EnginePluginHosting" < "EngineResult" lexicographically... actually need
to double check exact ordering at implementation time, not guess here).

## Key Decisions

- Decision 1: Scope is strictly the one-line export addition described in the
  issue. No other refactor, no fixing of other potentially-missing exports،
  no touching unrelated files.
- Decision 2: No new branch created — already operating inside an isolated
  worktree (`worktree-agent-a660e305185700585`) dedicated to this single fix,
  per the parallelized-fix process. Treated as the equivalent of an existing
  feature branch.
- Decision 3: Verification = `dart analyze` (or `flutter analyze` per repo
  convention/gotcha) on `packages/loopy_engine` cleanly passing, plus running
  the package's existing test suite, per the documented
  `loopy-test-runner-gotcha` (very_good MCP test runner is broken for this
  repo; use the absolute flutter path directly instead).
- Decision 4: Proceeding autonomously without interactive user dialogue,
  since this task is running as one of 21 parallelized, pre-verified fixes
  with no live user to ask — per explicit instruction from the orchestrating
  agent.

## Open Questions

None — the fix is fully specified by the issue report and confirmed by
re-reading both files. The only thing to nail down precisely during
implementation is the exact alphabetical insertion point in the show-list,
which will be done by inspection at edit time rather than guessed here.
