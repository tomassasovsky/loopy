---
title: "feat: tempo-aware looper — part 5: MIDI clock receive (Phase E)"
type: feat
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## feat: MIDI clock receive (Phase E) — 3 PRs

Part 5 (final) of the tempo-aware rework. **Read the
[index plan](2026-07-22-feat-tempo-aware-looper-modes-plan.md) first**
(architecture §5, decisions D3, D14, tracking contract). **The last PR of
this part carries `Closes #263`** — every other PR in the series carries
`Part of #263`.

## Dependencies

- Requires part 3 (tri-state `clock_mode`) and part 4 (stretch — the Sheeran
  slave restrictions force Sync Audio to Tempo on while slaved, D3).
- E2 consumes the per-mode downbeat-arming table from the B1 spec (part 2).

## Overview

Loopy as MIDI clock slave: a native follower that timestamps 0xF8 arrivals,
smooths tempo, and drives the engine grid directly. Dart sees only derived
state (BPM, locked/lost). While slaved: manual tempo disabled, Sync Audio to
Tempo forced on (D3).

## Tasks

- [ ] **E1 — native clock follower** (`autonomy:auto`)
  - Lift the real-time-byte drop (`midi.c:84,99-100`) **for the follower
    only** (0xF8/FA/FB/FC routed to the follower; still never delivered to
    the Dart controller stream).
  - Follower in `packages/loopy_engine/src/midi/`: interval smoothing
    (window spec'd in-PR), freewheel on >250 ms silence (clock-lost), MIDI
    Stop = transport stop distinct from loss (D14); lock-free state into the
    engine; in-flight recordings finalize on the frozen grid; ffigen regen
    in-PR.
  - Tests: jittered-clock lock (±1 %); 300 ms dropout mid-record →
    freewheel finalize; Stop vs. loss; tick→BPM smoothing convergence.
- [ ] **E2 — slave restrictions + downbeat arming** (`autonomy:auto`)
  - D3 restrictions: manual tempo/tap rejected while slaved (engine-side
    guard + `TempoSource.external`); Sync Audio to Tempo forced on.
  - Downbeat: bar 1 beat 1 = first MIDI Start; slave-enable against running
    clock anchors at enable moment; `realignDownbeat` action (D20); per-mode
    arming per the transcribed table in
    `docs/plan/2026-07-22-song-mode-spec.md` §3 (clock-not-running → start
    on MIDI Start, playback locked otherwise; running+Multi → next downbeat;
    running+Sync/Band → primary top; **receive inactive in Song/Free** —
    entering them while slaved drops to internal clock with a notice); SPP
    explicitly ignored (D14).
  - Tests: restriction enforcement; downbeat anchor cases; per-mode arming
    table row by row incl. the Song/Free drop-to-internal path.
- [ ] **E3 — app UI** (`autonomy:merge-gate`; carries `Closes #263`)
  - Receive option in the clock-mode setting; locked/lost indicators;
    disabled tempo controls while slaved (with hint); pedal counting/lost
    indication if B1 assigned one. UI conventions per index.
  - Tests: cubit/widget tests; settings round-trip.
  - Closeout: update `docs/PROGRESS.md` tempo-system section;
    verify #263 auto-closes.

## Success Criteria

```success-criteria
GOAL: Loopy records bar-locked against an external MIDI clock under the Sheeran slave restrictions; grid-off behavior unchanged.

SUCCESS CRITERIA:
- Existing suites unchanged; follower robustness tests (jitter, dropout, Stop-vs-loss) pass | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- ASAN-clean | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Dart suites green with coverage gates | verify: /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
- Real-time bytes still never reach the Dart controller stream (regression guard) | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- Slaved to Ableton over USB-MIDI: records bar-locked, tempo controls disabled, freewheel on master stop mid-record | verify: manual 1. master Ableton 2. record a loop slaved 3. confirm bar lock + disabled controls 4. stop master mid-record, confirm freewheel finalize

NON-GOALS: SPP, MTC, Ableton Link, drift-tolerant receive without stretch.

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
```

## References

Index plan (architecture §5, D3, D14, D20); real-time drop
`packages/loopy_engine/src/midi/midi.c:84,99-100`; B1 spec doc (part 2) for
§6.2.1 arming table.
