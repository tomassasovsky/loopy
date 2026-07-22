---
title: "feat: tempo-aware looper — part 1: core grid in Multi (Phase A)"
type: feat
date: 2026-07-22
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

## feat: core grid in Multi (Phase A) — 8 PRs

Part 1 of the tempo-aware rework. **Read the
[index plan](2026-07-22-feat-tempo-aware-looper-modes-plan.md) first** — it
holds the architecture (§1–5), decisions D1–D20, the manifest v4 schema, the
UI conventions, and the tracking contract (every PR: `Part of #263`, never
`Closes`).

## Dependencies

- None on other parts. B0 (`InteractionMode` rename, part 2) is encouraged to
  land **before A1** to minimize rebase churn, but nothing here requires it.
- Within this part: A2 and A3 are **siblings off A1** (independent of each
  other). A4a needs A1–A3 merged; A4b needs A4a; A5/A6/A7 need A4b.

## Overview

Resurrect and modernize the tempo stack deleted in `2f0513a` against the
current engine (lanes, monitors, perf recording): tempo + all 15 time
signatures, routable click + count-in, tap tempo, musical quantization, loop↔
tempo sync, track length presets, manifest v4, `.als` real tempo. Everything
defaults off; the grid-off path stays bit-identical (existing suites pass
unchanged on every PR).

## Tasks

- [ ] **A1 — tempo grid + engine state** (`autonomy:auto`)
  - New `packages/loopy_engine/src/core/tempo_grid.c` + `tempo_grid.h`: pure
    math over `{bpm, ts_num, ts_den, sample_rate}` — frames-per-beat-unit,
    frames-per-bar, `next_boundary(pos, subdivision)`, loop-length↔BPM
    derivation (D7). Beat unit = denominator note (verify vs. manual, index
    Architecture §1).
  - Grid atomics + snapshot fields on `le_engine`
    (`engine_private.h`, `engine_snapshot.c`, `loopy_engine_api.h`).
  - Commands (free slots 9–12, 18–19): `LE_CMD_SET_TEMPO`,
    `LE_CMD_SET_TIME_SIGNATURE`, `LE_CMD_TAP_TEMPO`, `LE_CMD_SET_SYNC_TEMPO`,
    `LE_CMD_SET_QUANTIZE_DIV` + exported `le_engine_set_*` wrappers
    (`engine_commands.c`, reference `2f0513a`).
  - Tempo-source precedence enum + tempo/time-signature locks (D6, D7).
  - Loop↔tempo sync modernized from `2f0513a` (`sync_tempo_to_loop`,
    `beat_at`), generic over signatures.
  - ffigen regen + `dart format` **in this PR** (snapshot struct grew); zero
    Dart *behavior* change.
  - Tests (`packages/loopy_engine/src/test/test_engine_core.c`): modernize
    the 13 deleted tempo tests (`git show 2f0513a`), add signature-generic
    grid math, lock, and precedence cases (derive-only-from-none, tap vs.
    manual last-writer, dead-tempo survival).
  - *Exit:* `run_native_tests.sh` green incl. new tests; existing tests
    unchanged.
- [ ] **A2 — click + count-in** (sibling of A3, off A1; `autonomy:auto`)
  - Click voice (sine 1000/1500 Hz, 30 ms decay, amp 0.25) + routable click
    bus: `LE_CMD_SET_CLICK_OUTPUT`, `LE_CMD_SET_CLICK_VOLUME`; summed
    post-`perf_tap_master_frame` (index Architecture §3, D5) in
    `engine_process.c`.
  - Count-in state machine (D9): idle-only, record-press cancels, auto-record
    mutual exclusion, counting-in snapshot fields + beat countdown.
  - Tests: click energy on masked channels only; zero click in master render
    and perf capture; count-in cancel/precedence; count-in never fires while
    anything plays.
- [ ] **A3 — musical quantize arming** (sibling of A2, off A1;
  `autonomy:auto`)
  - Extend arm machinery (`engine_commands.c:519-746`,
    `engine_process.c:805-820,1462-1475`) from loop-top to grid subdivisions
    via `next_boundary`.
  - Quantized record-end rounding (D8: nearest, min 1 unit, capture to
    boundary on round-up); arm re-evaluation on granularity change.
  - Tests: D8 table row by row; 3.49/3.51-bar rounding; disarm race at the
    boundary sample; one-capturer hand-off with a pending quantized end.
- [ ] **A4a — FFI seam** (`autonomy:auto`)
  - New role interface `TempoControl` in
    `packages/loopy_engine/lib/src/audio_engine.dart` (compose at `:643-654`
    pattern); impls in `native_audio_engine.dart` + `mock_audio_engine.dart`
    (mock parity is the compile-time seam guarantee).
  - `EngineSnapshot` tempo fields + `QuantizeDiv`/`TempoSource`/`ClockMode`
    Dart enums (`engine_snapshot.dart`).
  - Tests: `engine_snapshot_test.dart` fromNative round-trips;
    `pumped_native_engine_test.dart` smoke for new setters; mock behavior
    tests.
- [ ] **A4b — repository plumbing** (`autonomy:auto`)
  - `looper_repository`: passthroughs, `TransportState` tempo/beat/bars
    fields, `Track.armed`; re-apply persisted tempo settings on engine
    (re)start (pattern: `looper_repository.dart:475-480`).
  - `settings_repository`: keys for tempo, signature, quantize div,
    metronome, count-in, click mask/volume.
  - `controller_repository`: actions `tapTempo`, `toggleMetronome`,
    `cancelArm` (D20) + default-mapping updates.
  - Tests: repository passthrough/ordering tests (pattern of the deleted
    "tempo commands forward to the engine" test), fake-engine capture fields,
    settings round-trips, mapping tests.
- [ ] **A5 — app UI** (`autonomy:merge-gate`)
  - New `lib/looper/view/tempo_settings_section.dart` wired into
    `lib/looper/view/settings_page.dart` (index UI conventions: LooperTheme
    tokens, no pixel params, extracted widget classes): BPM control, tap,
    signature picker (15), quantize-granularity selector, metronome +
    count-in toggles, click output/volume routing.
  - Transport tempo/beat display in the looper chrome
    (`lib/looper/view/tracks_chrome.dart`); armed indication via
    `Track.armed`.
  - New `lib/looper/cubit/tempo_cubit.dart` (pattern:
    `quantize_cubit.dart`); bloc events for tempo actions; l10n strings.
  - Tests: cubit unit tests, widget tests per new widget, bloc tests;
    regenerate screenshot goldens (author-only; they rot silently).
- [ ] **A6 — track length presets** (`autonomy:auto` engine +
  `merge-gate` UI review)
  - AUTO / 1–64 bars per track (D7 rounding, D17 auto-finalize extending
    `engine_process.c:1445`; allocation validation vs. `max_loop_frames`
    before record with surfaced error).
  - Per-track preset UI in the tracks section / routing dialog.
  - Tests: native preset finalize/early-press/inert-change cases; the
    64×15/8×30 BPM rejection; Dart preset UI + repository tests.
- [ ] **A7 — manifest v4 + `.als` tempo** (`autonomy:auto`)
  - Full v4 schema per index ERD (later-phase names provisional, D12):
    `packages/session_repository/lib/src/models/session.dart` +
    `session_repository.dart`.
  - `daw_export`: `ManifestReader`/`DawProject` read real `tempoBpm`
    (`daw_project.dart:18-28`) — 100 % coverage gate.
  - File the bar-aligned-clips follow-up issue (D2).
  - Tests: v3→defaults load, v4 round-trip, absent-field tolerance,
    future-version rejection; daw_export tempo assertions.

## Success Criteria

```success-criteria
GOAL: Musician can set/tap tempo in any of 15 signatures, hear a routed click, count in, and record beat/bar-quantized loops in Multi — with the grid-off path bit-identical.

SUCCESS CRITERIA:
- Existing native suites pass unchanged on every PR; new A1–A3/A6 behaviors have named C tests | verify: bash packages/loopy_engine/src/test/run_native_tests.sh
- ASAN-clean | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/loopy_engine/src/test/run_native_tests.sh
- Dart suites green with coverage gates (root ≥90, daw_export 100) | verify: /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
- v3 loads as grid-off defaults; v4 round-trips A fields | verify: /Users/Tomas/development/flutter/bin/flutter test packages/session_repository
- .als emits session tempo | verify: /Users/Tomas/development/flutter/bin/flutter test packages/daw_export
- Grid-off UI visually unchanged; new tempo UI follows UI conventions | verify: manual 1. regen goldens 2. diff grid-off screens 3. review tempo screens

NON-GOALS: modes (part 2), clock I/O (parts 3/5), stretch (part 4), bar-aligned .als clips.

VERIFICATION COMMAND: bash packages/loopy_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter analyze && /Users/Tomas/development/flutter/bin/flutter test --coverage
```

## References

Index plan (architecture §1–3, D1–D2, D5–D9, D12, D17, D20); deleted stack
`git show 2f0513a`; arm machinery `engine_commands.c:519-746`; frame chain
`engine_process.c:2018-2054`; ffigen gotcha `ffigen.yaml:2-8`.
