---
title: "feat: performance recording — part 3: sample-accurate event log"
type: feat
date: 2026-07-05
---

## feat: performance recording — part 3: sample-accurate event log — Standard

> **Split note:** part 3 of 12 (umbrella:
> `2026-07-05-feat-performance-recording-daw-export-plan.md`). This part is
> the **event-log subsystem**: the log ring, frame-tagged emission in the
> audio thread, and the append-only raw log file. The log is the backbone of
> both the offline renderer (parts 7–8) and the `.als` generator (parts
> 9–10) — its on-disk format is pinned here and documented, which is what
> unblocks the parallel `daw_export` track.

## Overview

While armed, every applied command that affects audibility — plus transport
facts (loop length locked, layer retired, record start/end) — is tagged with
the current capture frame and pushed to a new dedicated **4096-slot perf log
ring**, drained by the part 2 thread into an **append-only raw log file**.
**No coalescing anywhere in the capture path** (umbrella D-LOG): events are
~16 bytes, a 1 kHz encoder sweep is 16 KB/s, and a coalesced log would
diverge from what the live master heard, weakening the part 8 parity gate.
Breakpoint thinning happens only in `daw_export` (part 10).

## Context / findings

- The logged set is an **audited table, not a prose list**: derive it by
  auditing every `LE_CMD_*` in `apply_command`
  ([engine_process.c:553+](../../packages/loopy_engine/src/core/engine_process.c))
  for audibility effects. It must include at minimum: record/play/stop, track
  + per-lane volume and mute, multiple, FX type/count/param changes, clear,
  undo/redo, per-lane output routing (`SET_LANE_OUTPUT`), the output-enabled
  mask, master gain, limiter enable/ceiling, overdub feedback, and monitor
  enable/volume/mute/FX changes. Ship the table as a comment block next to
  the emission switch **and** in the log-format doc.
- FX **param** changes bypass the command ring today (direct atomic stores,
  `le_engine_set_lane_fx_param`, engine_commands.c:784+). Emission for those
  happens control-side at the setter (tagged with the snapshot-read capture
  frame — accuracy within one buffer is acceptable for params; they are not
  part of the bit-parity path the limiter/volume math is).
- Transport facts are emitted from the audio thread at their exact frame
  (record start/end, length lock, retire).
- "A command that changes output but isn't logged" becomes a standing review
  checklist item (umbrella).
- Log file format (binary, little-endian, versioned header) is documented in
  `docs/design/` so `daw_export` (part 9) can build fixtures against it
  without importing engine code.

## Acceptance Criteria

- [ ] Audited `LE_CMD_*` table exists (comment + doc) and the emission switch
      covers exactly that table; a native test iterates the table and
      asserts every entry round-trips through ring → file.
- [ ] Events carry the correct capture frame: a scripted command applied at
      frame N appears in the log tagged N (native test).
- [ ] A command storm (≥ 2000 events in one drain interval) loses nothing
      (4096 ring + 250 ms drain headroom test).
- [ ] FX param sweeps are logged (control-side emission) with monotonic
      frames.
- [ ] Log file: versioned header, append-only, readable after abrupt stop up
      to the last flush.
- [ ] Format doc committed (`docs/design/performance-event-log-format.md`).
- [ ] Native suite "ALL PASSED"; `flutter analyze` clean; format stable.

## Tasks

- [ ] `packages/loopy_engine/src/core/engine_private.h` — perf log ring
      (4096-slot `le_command`-shaped entries + frame tag) on `le_engine`.
- [ ] `packages/loopy_engine/src/core/engine_process.c` — emission in
      `apply_command` per the audited table + transport-fact emission at
      exact frames.
- [ ] `packages/loopy_engine/src/core/engine_commands.c` — control-side
      emission for direct-atomic param setters while armed.
- [ ] `packages/loopy_engine/src/core/perf_drain.c` — log-ring drain → append
      to `events.log` (binary, versioned header), same flush cadence.
- [ ] `docs/design/performance-event-log-format.md` — wire format + audited
      command table.
- [ ] Native tests: table round-trip, frame accuracy, storm survival, param
      sweep, abrupt-stop readability.

## Files touched (primary)

`packages/loopy_engine/src/core/{engine_private.h,engine_process.c,engine_commands.c,perf_drain.c}`,
`packages/loopy_engine/src/test/test_engine_core.c`,
`docs/design/performance-event-log-format.md`.

## Verification

1. `bash packages/loopy_engine/src/test/run_native_tests.sh` — "ALL PASSED".
2. `flutter analyze` clean; `dart format --set-exit-if-changed .` stable.

## Dependencies

- **Part 2** (drain thread that persists the log ring).
