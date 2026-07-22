---
title: "feat: tempo-aware looper — part 4: time-stretch (Phase D)"
type: feat
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## feat: time-stretch / Sync Audio to Tempo (Phase D) — 4 PRs

Part 4 of the tempo-aware rework. **Read the
[index plan](2026-07-22-feat-tempo-aware-looper-modes-plan.md) first**
(decisions D6, D13, tracking contract: `Part of #263`).

## Dependencies

- Requires part 1 (tempo grid). Independent of parts 2 and 3.
- Part 5 (clock receive) hard-depends on this part (Sheeran slave
  restrictions force Sync Audio to Tempo on).
- **D0 is a hard gate**: D2/D3 are not fully specced until the spike lands.

## Overview

Pitch-preserved time-stretch 0.5×–2× via the MIT-licensed Signalsmith Stretch
library, so recorded loops follow tempo changes. Layer architecture per D13:
always stretch from original per-layer buffers at ratio
`original_tempo / current_tempo`; never compound.

## Tasks

- [ ] **D0 — spike** (timeboxed; lands as doc + benchmark harness;
  `autonomy:plan-gate` on its conclusions)
  - Benchmark Signalsmith quality presets on the audio thread: 8 tracks ×
    lanes at 48 kHz; decide preset + render model (inline vs. worker thread
    with crossfade fallback); validate the D13 double-memory budget.
  - Manual-verified: the Sheeran has a **two-toggle model** (§5.9.5) — Sync
    Audio to Tempo (follow tempo, varispeed-style pitch shift) and Time
    Stretch (pitch preserved) are independent. Spike decides whether loopy
    adds the cheap varispeed leg (resample) or ships pitch-preserved-only
    (current default; document as deviation if skipped).
  - Harness home: `packages/loopy_engine/src/test/bench/` — **excluded from
    `run_native_tests.sh`** (must not join the golden gate or rot untracked).
  - Confirms provisional manifest names (`syncAudioToTempo`,
    `originalTempoBpm`) per D12.
- [ ] **D1 — vendor Signalsmith Stretch** (`autonomy:auto`)
  - Into `packages/loopy_engine/src/stretch/` (MIT under repo GPLv3;
    precedent: ASIO/VST3 vendoring); wire into `src/CMakeLists.txt`, podspec
    forwarders, and `run_native_tests.sh` source globs; license notice.
- [ ] **D2 — engine integration** (`autonomy:auto`)
  - Per-layer stretch-from-original (D13); `originalTempoBpm` captured at
    record; BPM-lock relaxation to the 0.5×–2× window (D6); ratio deadband +
    crossfade on retarget (index G26 lineage); ffigen regen in-PR.
  - Tests: overdub-after-stretch undo integrity (layers at different native
    rates); no compounding (120→100→120 ≡ identity vs. originals); clamp at
    2×/0.5×; CPU guard per D0 numbers.
- [ ] **D3 — app UI + manifest D fields** (`autonomy:merge-gate`)
  - Sync Audio to Tempo toggle (quantized, crossfaded disable), per-track
    original-tempo display; settings + repository plumbing; manifest fields
    live. UI conventions per index.

## Success Criteria

```success-criteria
GOAL: Loops follow tempo changes 0.5x-2x pitch-preserved with intact undo layering; grid-off behavior unchanged.

SUCCESS CRITERIA:
- Existing suites unchanged; stretch integrity tests (undo layers, no compounding, clamps) pass | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- ASAN-clean (stretch buffers are significant new allocation) | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Dart suites green with coverage gates | verify: /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
- D fields round-trip in the manifest | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository
- Stretch quality at the chosen preset is acceptable on real material at 8 tracks | verify: manual 1. record 8-track session 2. sweep tempo 0.5x-2x 3. listen for artifacts/dropouts, watch xrun counter

NON-GOALS: stretch during clock receive (part 5), varispeed (non-pitch-preserved), per-track independent stretch ratios beyond the session tempo.

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
```

## References

Index plan (D6, D13); Signalsmith Stretch
https://github.com/Signalsmith-Audio/signalsmith-stretch; vendoring precedent
`packages/loopy_engine/src/asio/` + `src/host/`; layer/undo machinery
`engine_private.h:346-372`, pool `LE_POOL_SLOTS`.
