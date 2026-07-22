---
title: "feat: tempo-aware looper — part 2: five looper modes (Phase B)"
type: feat
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## feat: five looper modes (Phase B) — 9 PRs

Part 2 of the tempo-aware rework. **Read the
[index plan](2026-07-22-feat-tempo-aware-looper-modes-plan.md) first**
(architecture §4, decisions D4, D10–D12, D16–D20, manifest schema, UI
conventions, tracking contract: `Part of #263` on every PR).

## Dependencies

- **B0 and B1 have no dependency on part 1** — land B0 first in the whole
  series (before A1) and B1 early.
- B2a–B5c require part 1 (the tempo grid) merged.
- Internal edges: B2b ← B2a; B3 ← B2b; B4 ← B1 + B2b; B5a ← B2a;
  B5b ← B5a; B5c ← B5a (not B5b).

## Overview

Introduce the five-mode axis (Multi/Sync/Song/Band/Free) with Sheeran
semantics: per-track independent clocks for Free, primary-track ("crown")
sync with multiples **and divisions** for Sync/Band, section sequencing for
Song, mode locked while content exists (D4), pedal protocol v2 with a
bidirectional degrade policy (D11).

## Tasks

- [ ] **B0 — `LooperMode` → `InteractionMode` rename** (`autonomy:auto`;
  lands before A1)
  - Mechanical rename of `lib/looper/model/looper_mode.dart` + ~40 sites
    (`lib/control/`, `lib/looper/view/`, `lib/theme/looper_theme.dart`) +
    tests; **preserve persisted token strings** under `looper.default_mode`
    (D10). Zero behavior change.
- [ ] **B1 — Song-mode + downbeat-arming spec** (doc;
  `autonomy:plan-gate` — this is a design review checkpoint)
  - **DRAFTED**: `docs/plan/2026-07-22-song-mode-spec.md` — transcribed from
    the manual (§4.2/§5.9/§6.2.1) with the six B1 questions answered and the
    per-mode clock-arming table for part 5. Outcomes: sections are tracks
    (no separate object, no advance gesture — `advanceSection` dropped from
    D20); `songSections`/`bandGroups` manifest fields dropped; per-track
    **One Shot** flag added to B scope; Band section transport quantizes to
    the primary cycle. **Awaiting user plan-gate review — B4 blocked on it.**
- [ ] **B2a — engine mode field** (`autonomy:auto`)
  - `le_looper_mode` enum + atomic, `LE_CMD_SET_LOOPER_MODE`; rejected while
    any track has content (D4). ffigen regen in-PR.
  - Tests: mode-switch rejection with content; free switching when empty;
    persistence of mode across configure.
- [ ] **B2b — per-track clocks + Free mode** (`autonomy:auto`; **the
  highest-risk PR of the series — isolated, unhurried review**)
  - Per-track `le_loop_clock` + iteration counter on `le_track`
    (`engine_private.h`), dormant outside Free.
  - Free-mode branches implemented as extracted helpers (e.g.
    `advance_track_clock_frame`) so `mix_tracks_frame` /
    `advance_transport_frame` each gain only a single guarded call (index
    Architecture §4).
  - Viz per-track length/position in Free mode.
  - Tests: 8 mutually-prime lengths over long runs (iteration wrap); dormant
    paths bit-identical (full old suite); per-track quantize/arming in Free;
    perf-recording timeline ordering unaffected.
- [ ] **B3 — Sync + Band + primary** (`autonomy:auto`)
  - `a_primary_track` + crown command + D18 lifecycle (persists through
    clear, explicit re-crown, no auto-reassignment).
  - Division playback (1/2, 1/4 of primary) extending the `seg_base`
    derivation (D16); Band = primary + independently start/stoppable
    section tracks quantized to the primary cycle (song-mode-spec §2 Q3);
    per-track One Shot flag; preset restriction to valid
    multiples/divisions.
  - Tests: division vs. undone-primary; crown persistence; Band section
    start/stop quantization; One Shot stop-at-end. Size watch: if diff
    exceeds ~600 LOC, peel Band section transport into a follow-on PR.
- [ ] **B4 — Song mode engine** (`autonomy:auto`; blocked on B1 review)
  - Sections, quantized advance, `advanceSection` action (D20), in-flight
    recording rule per B1.
  - Tests: section advance at the spec'd boundary; advance mid-record.
- [ ] **B5a — pedal protocol v2 codec** (`autonomy:auto`)
  - `packages/pedal_repository`: version byte 0x02, 3-bit mode field +
    counting-in bit, degrade policy both directions (D11);
    `firmware/loopy_pedal/pedal_protocol.h` doc-comment fix (16→17-byte
    payload lag noted in research).
  - Contract fixtures for all four app/firmware pairings in
    `firmware/test/test_pedal_protocol.c`.
- [ ] **B5b — firmware v2** (`autonomy:blocked-verify`; hardware flash
  required)
  - `firmware/loopy_pedal/`: emit/parse v2, mode + counting-in LED
    patterns.
- [ ] **B5c — app mode UI + manifest B fields** (`autonomy:merge-gate`;
  depends on B5a only)
  - Mode picker with clear-all confirmation (D4; not a pedal action), crown
    UI (Wave-view style), `crownPrimary` action; manifest `looperMode` /
    `primaryTrack` / `oneShot` fields live (`songSections`/`bandGroups`
    dropped per B1); UI conventions per index. Session round-trip tests
    incl. Free-mode lengths.

## Success Criteria

```success-criteria
GOAL: All five modes selectable, persistent, and Sheeran-faithful; pedal shows mode + counting-in on v2 firmware and degrades cleanly on v1; grid-off Multi stays bit-identical.

SUCCESS CRITERIA:
- Existing suites unchanged; new mode/clock/division behaviors have named C tests | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- ASAN-clean (Free-mode clocks are new hot-path memory) | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Pedal contract holds across v1/v2 × v1/v2 | verify: gcc -std=c11 -Wall -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests
- Dart suites green with coverage gates; rename PR is behavior-neutral | verify: /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
- Free-mode session round-trips 8 independent lengths | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository
- v2 firmware shows mode + counting-in; v1 degrades with update notice | verify: manual 1. flash v2, cycle modes, count-in 2. flash v1, confirm legacy frames + notice
- Song-mode engine matches the reviewed B1 spec | verify: manual review of B1 doc against Sheeran manual before B4 starts

NON-GOALS: clock I/O (parts 3/5), stretch (part 4), mode transitions with content (locked, D4).

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && gcc -std=c11 -Wall -I firmware/loopy_pedal firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c -o /tmp/pedal_protocol_tests && /tmp/pedal_protocol_tests && /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
```

## References

Index plan (architecture §4, D4, D10–D12, D16–D20); `seg_base` math
`engine_process.c:1732-1737`; pedal codec `pedal_codec.dart:76-106`;
`pedal_mode.dart:6-18`; firmware `firmware/loopy_pedal/`; rename target
`lib/looper/model/looper_mode.dart:8-23`.
