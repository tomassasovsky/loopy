---
title: "feat: tempo-aware looper — part 3: MIDI clock send (Phase C)"
type: feat
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## feat: MIDI clock send (Phase C) — 2 PRs

Part 3 of the tempo-aware rework. **Read the
[index plan](2026-07-22-feat-tempo-aware-looper-modes-plan.md) first**
(architecture §5, decision D15, tracking contract: `Part of #263`).

## Dependencies

- Requires part 1 (tempo grid). Independent of parts 2 and 4.
- Part 5 (clock receive) reuses the tri-state `clock_mode` introduced here.

## Overview

Loopy as MIDI clock master: a native 24-PPQN emitter driven from the
audio-thread grid position, sent through the existing verbatim
`le_midi_out_send` path (which already carries real-time bytes for the pedal
loop-top pulse).

## Tasks

- [ ] **C1 — native 24-PPQN emitter** (`autonomy:auto`)
  - New emitter in `packages/loopy_engine/src/midi/` driven by the grid
    position each block; 0xF8 ticks, Start/Stop/Continue per D15 (Start at
    loop downbeat — end of count-in, never count-in start; ticks free-run at
    set BPM while transport stopped — confirm vs. the Sheeran manual at
    review).
  - Tri-state clock mode `off / send / receive` atomic +
    `LE_CMD_SET_CLOCK_MODE` (receive rejected until part 5); ffigen regen
    in-PR.
  - Tests (`test_midi_core.c` / `test_engine_core.c`): tick spacing at fixed
    BPM within jitter bound; 24×beats ticks between Starts;
    Start-not-at-count-in; no bytes emitted in `off`.
- [ ] **C2 — app UI + manifest field** (`autonomy:merge-gate`)
  - Clock-mode setting in the tempo settings section (UI conventions per
    index); `clockMode` manifest field live (name per D12 provisional
    review); repository + settings plumbing.
  - Tests: cubit/repository/settings round-trips; widget test.

## Success Criteria

```success-criteria
GOAL: An external device locks to loopy's clock; grid-off behavior unchanged.

SUCCESS CRITERIA:
- Existing suites unchanged; emitter timing tests pass | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- ASAN-clean | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Dart suites green with coverage gates | verify: /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
- Ableton slaved to loopy stays bar-locked over 5 minutes; Start lands on the loop downbeat after a count-in | verify: manual 1. connect loopy MIDI out to Ableton sync 2. record with count-in 3. confirm downbeat alignment + 5-min lock

NON-GOALS: clock receive (part 5), MTC, Ableton Link.

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
```

## References

Index plan (architecture §5, D15); MIDI out verbatim path
`loopy_engine_api.h:1317-1370`; existing loop-top 0xFA pulse
`pedal_codec.dart:58-66`.
