---
title: fix — export EnginePerformanceCapture from loopy_engine barrel
type: fix
date: 2026-07-13
---

## fix: export EnginePerformanceCapture from loopy_engine barrel - Minimal

`packages/loopy_engine/lib/src/audio_engine.dart` composes `AudioEngine` from
9 role-segregated interfaces, documented as letting "a consumer ... depend on
the slice it needs ... instead of the whole surface." Every role interface in
that `implements` clause is re-exported from the package barrel
`lib/loopy_engine.dart` except `EnginePerformanceCapture`
(perfArm/perfDisarm/renderBegin/renderPoll/renderTrackStatuses/renderCancel).
A consumer that wants only the performance-capture slice must currently
import `package:loopy_engine/src/audio_engine.dart` directly, which trips the
`implementation_imports` lint the repo enforces. Fix: add
`EnginePerformanceCapture` to the `show` list in `lib/loopy_engine.dart`'s
`export 'src/audio_engine.dart'` statement, alphabetically ordered.

## Success Criteria

```success-criteria
GOAL: EnginePerformanceCapture is importable from package:loopy_engine/loopy_engine.dart (the public barrel) without reaching into src/, matching every other role interface composed into AudioEngine.

SUCCESS CRITERIA:
- lib/loopy_engine.dart's export show-list for src/audio_engine.dart includes EnginePerformanceCapture, alphabetically ordered among the existing names | verify: grep -A15 "export 'src/audio_engine.dart'" packages/loopy_engine/lib/loopy_engine.dart | grep -q EnginePerformanceCapture
- No other role interface implemented by AudioEngine (packages/loopy_engine/lib/src/audio_engine.dart implements clause) is missing from the same show-list | verify: manual — re-diff the AudioEngine implements-clause interface list against the show-list and confirm all 10 (9 existing + EnginePerformanceCapture) are present, noting but not fixing any other newly-discovered gap
- packages/loopy_engine analyzes with zero issues | verify: cd packages/loopy_engine && /Users/Tomas/development/flutter/bin/flutter analyze --no-fatal-infos
- packages/loopy_engine's existing test suite still passes | verify: cd packages/loopy_engine && /Users/Tomas/development/flutter/bin/flutter test

NON-GOALS:
- Adding any new export for role interfaces other than EnginePerformanceCapture, even if another gap is spotted (flag separately, do not fix here)
- Any refactor of audio_engine.dart itself, or of AudioEngine's implements clause
- Adding new tests exercising EnginePerformanceCapture behavior (this is an export-visibility fix, not a behavior change)

VERIFICATION COMMAND: cd packages/loopy_engine && /Users/Tomas/development/flutter/bin/flutter analyze --no-fatal-infos && /Users/Tomas/development/flutter/bin/flutter test
```

## Context

- File to edit: `packages/loopy_engine/lib/loopy_engine.dart`, the
  `export 'src/audio_engine.dart' show ...` statement currently at lines
  9-22:
  ```dart
  export 'src/audio_engine.dart'
      show
          AudioEngine,
          EffectsControl,
          EngineException,
          EngineLifecycle,
          EngineMetering,
          EnginePluginHosting,
          EngineResult,
          EngineRouting,
          LooperTransport,
          MasterBusControl,
          MonitorControl,
          SessionIo;
  ```
  `EnginePerformanceCapture` sorts alphabetically between `EngineMetering`
  and `EnginePluginHosting` ("EngineM..." < "EnginePe..." < "EnginePl...").
- Source of truth for the role interface: `packages/loopy_engine/lib/src/audio_engine.dart`,
  `AudioEngine`'s `implements` clause (~lines 613-624), which lists all 9
  interfaces currently exported plus `EnginePerformanceCapture` — confirming
  it is the only interface in that clause missing from the barrel.
- Institutional gotcha (`loopy-test-runner-gotcha`): the `very_good` MCP test
  runner is broken for this repo; run `flutter test` with the absolute
  flutter path instead (`/Users/Tomas/development/flutter/bin/flutter`).
- Scope discipline: this is 1 of 21 independently-parallelized fixes from a
  multi-agent review pass, each running in its own isolated worktree. Stay
  narrowly scoped to this one export; do not touch unrelated findings even if
  noticed in passing.

## MVP

```dart
export 'src/audio_engine.dart'
    show
        AudioEngine,
        EffectsControl,
        EngineException,
        EngineLifecycle,
        EngineMetering,
        EnginePerformanceCapture,
        EnginePluginHosting,
        EngineResult,
        EngineRouting,
        LooperTransport,
        MasterBusControl,
        MonitorControl,
        SessionIo;
```

## References

- Issue source: multi-agent code review finding, re-verified against commit
  `f3f5b76` (origin/master HEAD).
- Brainstorm doc: `docs/brainstorm/2026-07-13-export-engineperformancecapture-barrel-brainstorm-doc.md`
