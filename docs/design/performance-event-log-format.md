# Performance event log format

Part 3 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`). This
pins the on-disk format for `events.log`, the sample-accurate record of every
audibility-affecting change made during an armed performance-recording
session — the backbone the offline renderer (parts 7-8) and the `.als`
generator (parts 9-10) build on. It is written so a reader can parse the file
without importing engine code.

## Where it lives

`events.log` sits alongside `master.pcm`, `input-<N>.pcm`, and
`performance.json` under the capture directory passed to `le_perf_arm`
(`packages/loopy_engine/src/core/perf_drain.c`). It is opened once at arm,
appended to every ~250ms drain cycle, and never truncated or rewritten —
unlike `performance.json`, which is atomically replaced each cycle.

## File layout

```
[header: 12 bytes]
[entry 0: 28 bytes]
[entry 1: 28 bytes]
...
```

### Header (12 bytes, written once)

| Offset | Size | Field         | Notes                                   |
|--------|------|---------------|------------------------------------------|
| 0      | 4    | magic         | ASCII `"PLEV"` (Perf Log EVents)          |
| 4      | 4    | version       | `uint32`, little/native-endian; `1` today |
| 8      | 4    | sample_rate   | `int32`, the session's sample rate        |

### Entry (28 bytes each, one per logged event)

| Offset | Size | Field   | Notes                                              |
|--------|------|---------|------------------------------------------------------|
| 0      | 8    | frame   | `uint64`, frames elapsed since arm (same epoch as `performance.json`'s `capture_frames` and the PCM files) |
| 8      | 4    | code    | `int32`, one of the codes in the table below          |
| 12     | 16   | payload | raw union bytes; interpretation keyed on `code`, see below |

Every field is written via explicit fixed-width `fwrite` calls
(`perf_drain.c`'s `le_pd_write_events_header` / `le_pd_write_log_entry`)
rather than one `fwrite` of `sizeof(le_perf_log_entry)` — that in-memory
struct is actually 32 bytes (its `uint64_t frame` gives it 8-byte alignment,
padding 4 trailing bytes onto the 28 bytes of real content), so a naive dump
would write 4 bytes of uninitialised garbage per entry. Writing exactly 28
bytes across three `memcpy`s sidesteps that trailing pad; a portable reader
only needs to know the two fixed record sizes above.

### Two independent streams, not one global timeline

Every entry is produced by one of two single-producer rings:

- **`log_ring`** (audio thread producer): the audited `LE_CMD_*` commands
  below, plus the four transport facts, tagged at the exact frame they were
  applied.
- **`log_ctrl_ring`** (control thread producer): the handful of direct-atomic
  setters that bypass the command ring entirely (FX/monitor params, the
  limiter, overdub feedback) plus the common in-track undo/redo swap, tagged
  with a snapshot of the elapsed-frame counter at the moment the setter ran
  (accurate within one buffer).

Each drain cycle appends `log_ring`'s backlog, then `log_ctrl_ring`'s. Within
a single stream, `frame` is monotonically non-decreasing. **Across the two
streams, entries are not globally frame-sorted** — a control-side param
change and an audio-thread command from the same ~250ms interval can appear
in either order in the file. A reader that needs one merged, time-ordered
timeline must sort all entries by `frame` before use (a stable sort keeps
same-frame entries in file order, which is the best tie-break available
without finer-grained timestamps). Splitting into two rings by producer
thread is what keeps each one single-producer/single-consumer with no new
synchronization primitive — see `perf_log_ring.h`.

## The audited command table

Every `LE_CMD_*` the audio thread applies (`engine_process.c`'s
`apply_command`) was audited for whether it affects audibility. The logged
subset reuses `le_command`'s own code and union arm verbatim — the `payload`
bytes are that command's union, unchanged, so a reader already familiar with
`loopy_engine_api.h`'s command-arm documentation can interpret them directly.

| Code (from `loopy_engine_api.h`)   | Value | Arm         | Logged? | Why |
|--------------------------------------|-------|-------------|---------|-----|
| `LE_CMD_MEASURE_LATENCY`              | 1     | —           | No      | Device-calibration workflow, not a performance action |
| `LE_CMD_RECORD`                       | 2     | generic     | Yes     | Explicitly required (record/play/stop) |
| `LE_CMD_STOP`                         | 3     | generic     | Yes     | ” |
| `LE_CMD_PLAY`                         | 4     | generic     | Yes     | ” |
| `LE_CMD_CLEAR`                        | 5     | generic     | Yes     | Erases a track: audible |
| `LE_CMD_UNDO`                         | 6     | —           | No*     | Never posted to the ring (control-thread swap) — see `LE_PLOG_UNDO` below |
| `LE_CMD_SET_VOLUME`                   | 7     | generic     | Yes     | Track volume |
| `LE_CMD_SET_MUTE`                     | 8     | generic     | Yes     | Track mute |
| `LE_CMD_SET_RECORD_OFFSET`            | 13    | generic     | No      | Calibration/config value, not changed mid-performance |
| `LE_CMD_SET_INPUT_MASK`               | 14    | trackmask   | Yes     | Track record-source routing |
| `LE_CMD_SET_OUTPUT_MASK`              | 15    | trackmask   | Yes     | Track playback routing |
| `LE_CMD_ARM`                          | 16    | —           | No      | Scheduling intent only — the eventual fire is `LE_PLOG_RECORD_START` |
| `LE_CMD_DISARM`                       | 17    | —           | No      | Cancels an intent that was never logged |
| `LE_CMD_SET_LANE_FX`                  | 20    | fx          | Yes     | FX type change |
| `LE_CMD_SET_LANE_FX_COUNT`            | 21    | fxcount     | Yes     | FX chain length |
| `LE_CMD_COMMIT_SESSION`               | 23    | —           | No*     | Logged as `LE_PLOG_LOOP_LENGTH_LOCKED` (the semantic fact, not a raw copy) |
| `LE_CMD_SET_LANE_INPUT`               | 26    | lanei       | Yes     | Lane record-source routing |
| `LE_CMD_SET_LANE_OUTPUT`              | 27    | lanei       | Yes     | Lane playback routing |
| `LE_CMD_SET_LANE_VOLUME`              | 28    | lanef       | Yes     | Lane volume |
| `LE_CMD_SET_LANE_MUTE`                | 29    | lanef       | Yes     | Lane mute |
| `LE_CMD_SET_MONITOR_INPUT`            | 30    | generic     | Yes     | Monitor enable |
| `LE_CMD_SET_MONITOR_INPUT_FX`         | 31    | fx          | Yes     | Monitor FX type change |
| `LE_CMD_SET_MONITOR_INPUT_FX_COUNT`   | 32    | fxcount     | Yes     | Monitor FX chain length |
| `LE_CMD_SET_MONITOR_INPUT_OUTPUT`     | 33    | trackmask   | Yes     | Monitor playback routing |
| `LE_CMD_SET_MONITOR_INPUT_VOLUME`     | 34    | generic     | Yes     | Monitor volume |
| `LE_CMD_SET_MONITOR_INPUT_MUTE`       | 35    | generic     | Yes     | Monitor mute |
| `LE_CMD_SET_MASTER_GAIN`              | 36    | generic     | Yes     | Explicitly required |
| `LE_CMD_SET_OUTPUT_ENABLED`           | 37    | generic     | Yes     | Structural output gate |
| `LE_CMD_DUB_SHADOW`                   | 38    | —           | No      | Internal shadow-pool bookkeeping, not itself an audible change |
| `LE_CMD_UNDO_TO_EMPTY`                | 39    | —           | No*     | Logged as `LE_PLOG_UNDO` (the to-EMPTY edge case) |
| `LE_CMD_REDO_FROM_EMPTY`              | 40    | —           | No*     | Logged as `LE_PLOG_REDO` (the from-EMPTY edge case) |
| `LE_CMD_PERF_ARM` / `LE_CMD_PERF_DISARM` | 41/42 | —        | No      | Meta — arming/disarming the session isn't part of what it captures |
| `LE_CMD_SET_TRACK_FX`                 | 49    | fx          | No      | No replay — manifest-only; stems stay per-stage dry-of-downstream (part 9), arm manifest carries track/master chains (part 3) |
| `LE_CMD_SET_TRACK_FX_COUNT`           | 50    | fxcount     | No      | ” (same manifest-only verdict) |
| `LE_CMD_SET_MASTER_FX`                | 51    | fx          | No      | ” |
| `LE_CMD_SET_MASTER_FX_COUNT`          | 52    | fxcount     | No      | ” |

The track/master FX **param and enabled setters** (direct-atomic, no ring
command) push nothing either — deliberately NOT mirroring the lane family's
306/310/311 control-side events: the whole track/master chain state is
manifest-only per the same part-9 stems decision, so `perf_render` replays
nothing from this family.

\* Logged under a different, semantically unified code — see below.

A command that changes output but isn't in this table is a standing
review-checklist item for every future part that touches `apply_command`
(umbrella-plan note).

## Perf-log-only codes (`le_perf_log_code`, `perf_log_ring.h`)

Values below 300 above are audited `LE_CMD_*` codes reused verbatim. These
are new codes with no `LE_CMD_*` equivalent — either transport facts (fired
from inside the audio thread's per-frame loop, so they carry the *exact*
sample-accurate frame rather than a buffer-start approximation) or
control-side-only concepts:

| Code                            | Value | Arm     | Payload                                                   |
|----------------------------------|-------|---------|------------------------------------------------------------|
| `LE_PLOG_RECORD_START`            | 300   | generic | `arg_i` = channel. A track actually began recording — immediate press or a deferred quantized/sound-triggered fire, both logged at the frame it actually happened. |
| `LE_PLOG_RECORD_END`              | 301   | generic | `arg_i` = channel. A track left RECORDING (stop, punch-out, or the record/dub toggle into overdub). |
| `LE_PLOG_LOOP_LENGTH_LOCKED`      | 302   | generic | `arg_i` = length in frames. The master loop length was (re-)established — the live-record finalize path or `LE_CMD_COMMIT_SESSION`'s session-import path. |
| `LE_PLOG_LAYER_RETIRED`           | 303   | evt     | `{channel, slot, generation}`, mirroring `LE_EVT_LAYER_RETIRED`'s payload. A completed overdub pass retired. |
| `LE_PLOG_UNDO`                    | 304   | generic | `arg_i` = channel. Every undo path — the common in-track swap or the to-EMPTY edge case — logs this one code. |
| `LE_PLOG_REDO`                    | 305   | generic | `arg_i` = channel. Same unification for redo. |
| `LE_PLOG_SET_LANE_FX_PARAM`       | 306   | fx      | `channel`, `lane`, `index` = `(fx_index << 8) \| param`, `type` = the float value bit-cast to `int32` (`f32_to_bits`). Control-side emission — params bypass the command ring. |
| `LE_PLOG_SET_MONITOR_FX_PARAM`    | 307   | fx      | Same packing; `channel` = input index, `lane` = -1. |
| `LE_PLOG_SET_LIMITER`             | 308   | generic | `arg_i` = enabled (0/1), `arg_f` = ceiling. |
| `LE_PLOG_SET_OVERDUB_FEEDBACK`    | 309   | generic | `arg_f` = feedback (0..1). |
| `LE_PLOG_SET_LANE_FX_ENABLED`     | 310   | fx      | `channel`, `lane`, `index` = fx slot, `type` = enabled (0/1). Control-side emission (direct-atomic setter, no ring). **Replayed in the lane wet pass** (`perf_render`, channel + lane-0 filter). |
| `LE_PLOG_SET_LANE_FX_CHAIN_ENABLED` | 311 | lanef   | `channel`, `lane`, `value` = enabled (0.0/1.0) — `LE_CMD_SET_LANE_MUTE`'s shape. Control-side emission. **Replayed in the lane wet pass.** |
| `LE_PLOG_SET_MONITOR_FX_ENABLED`  | 312   | fx      | `channel` = input index, `lane` = -1, `index` = fx slot, `type` = enabled (0/1) — 307's addressing convention. Logged for the manifest/reader, **not replayed in the lane pass** (mirrors `LE_PLOG_SET_MONITOR_FX_PARAM`'s treatment). |
| `LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED` | 313 | generic | `arg_i` = input index, `arg_f` = enabled (0.0/1.0) — the monitor volume/mute shape. Logged for the manifest/reader, **not replayed in the lane pass**. |

The replayed lane chain seeds all enable bits to 1 at arm: the arm manifest
carries no arm-time enabled state until part 3 of the FX-v3 epic adds it (a
pre-arm disable is invisible to the offline render until then).

Ordering caveat (same accepted tolerance class as the control-side param
events): enable flips are stamped with the control thread's buffer-base
`a_perf_frames` snapshot, while `LE_CMD_SET_LANE_FX`/`_FX_COUNT` are stamped
at audio-thread apply time — so an enable flip and a type/count change issued
within the same buffer can sort into the opposite order from the live engine,
and the replay's D-ENSEED re-seed then lands on the other side of the flip.
Bounded by one buffer, like the documented `LE_PLOG_SET_LANE_FX_PARAM` skew.

### Why record start/end are separate from the raw `LE_CMD_RECORD`/`LE_CMD_STOP` entries

Both the raw command *and* the transport fact are logged, deliberately: the
raw command captures "the user pressed record/stop this buffer"; the
transport fact captures "a track's RECORDING state actually changed, at this
exact frame." These usually coincide, but not always — a quantized
(loop-top) or sound-activated arm logs `LE_CMD_ARM` as *intent* (not logged;
see the table), and the actual `LE_PLOG_RECORD_START` fires later, at the
loop boundary or the input-level crossing, sample-accurately from inside the
per-frame loop. Likewise a deferred seam-crossfade finalize
(`request_master_finalize`) can push `LE_PLOG_RECORD_END` several frames
after the `LE_CMD_STOP` that requested it. A downstream consumer that only
needs "when did recording actually start/stop" should read the transport
facts, not try to infer them from the raw commands.

## Frame-tagging semantics

- Entries from `log_ring` (audio-thread-applied commands) are tagged with the
  elapsed-frame count at the **start of the buffer** the command was applied
  in (`apply_command` runs once per `le_engine_process` call, before the
  per-frame loop) — this is as fine-grained as a ring-applied command can be,
  since the engine only ever applies commands at buffer boundaries.
- Transport facts fired from *inside* the per-frame loop (record start/end,
  loop length locked via the live-record path, layer retired) carry the
  exact sample index within that buffer — genuinely sample-accurate.
- Entries from `log_ctrl_ring` (control-thread direct-atomic setters) are
  tagged with a plain `atomic_load` snapshot of the elapsed-frame counter at
  the moment the setter ran — accurate within one buffer, the documented
  tolerance for parameter changes (`docs/plan/.../part-3-plan.md`).

## Crash / abrupt-stop consistency

`events.log` is append-only and flushed every drain cycle (~250ms), the same
cadence as the PCM files. A crash or kill mid-capture leaves every entry
written before the last flush intact and parseable — there is no
finalization step for this file (unlike `performance.json`'s `finalized`
flag), since an append-only log has no "torn" state to guard against beyond
a possibly-incomplete final entry, which a reader detects by simply running
out of bytes mid-record (fewer than 28 bytes remaining) and discarding it.
