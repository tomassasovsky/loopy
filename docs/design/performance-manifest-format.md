# Performance manifest format (`performance.json`)

Part 6 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`). This
pins the schema of `performance.json`, the sidecar manifest that is the
**canonical machine-readable record** of a performance capture — the input
`daw_export` (parts 9-10) and the offline renderer (parts 7-8) build fixtures
and read logic against. It is written so a reader can parse the file without
importing engine or Dart code — every field is plain JSON.

## Where it lives

`performance.json` sits at the root of a capture's bundle directory
(`{documents}/exports/perf-YYYYMMDD-HHMMSS/`, D-NAME) alongside `events.log`
(`docs/design/performance-event-log-format.md`), the raw/finalized master and
input PCM, and `loops/`. Unlike `events.log`, it is **atomically replaced**,
not appended to: `perf_drain.c` rewrites it in full every ~250ms while armed,
and `performance_repository` (`packages/performance_repository`) rewrites it
once more at finalize (normal disarm, or crash recovery) to fold in the
fields below `finalized: true`.

## Two authors, one file

| Phase | Author | Fields written |
|---|---|---|
| While armed (~250ms cadence) | `perf_drain.c` (native) | `slug`, `sample_rate`, `channel_layout`, `capture_frames`, `overrun_count`, `overrun_gaps`, `layers`, `stopped_early?`, `finalized: false` (always) |
| At finalize (disarm, or crash recovery) | `performance_repository` (Dart) | `armSnapshot`, `disarmSnapshot?`, `finalized: true` — every native field above is preserved verbatim, never re-derived |

A reader only ever needs to parse the file **once it is finalized**
(`finalized: true`) to see the complete picture; a capture found with
`finalized` absent or `false` is either still in progress or is exactly what
`PerformanceRepository.findUnfinalized` flags for crash recovery (D-SALVAGE).

## Top-level fields

```jsonc
{
  "slug": "perf-20260706-143015",
  "sample_rate": 48000,
  "channel_layout": { "master_channels": 2, "captured_inputs": [0, 1] },
  "capture_frames": 4800000,
  "overrun_count": 0,
  "overrun_gaps": [ { "frame": 12000, "duration_frames": 64 } ],
  "layers": [ /* see below */ ],
  "stopped_early": "disk_full",
  "armSnapshot": { /* see below */ },
  "disarmSnapshot": { /* see below */ },
  "finalized": true
}
```

| Field | Type | Notes |
|---|---|---|
| `slug` | string | The bundle directory's own name (D-NAME); redundant with the path but kept so the file is self-describing if moved. |
| `sample_rate` | int | Negotiated device sample rate at arm time. Every PCM file in the bundle shares this rate (D-RATE — no resampling). |
| `channel_layout.master_channels` | int | Channel count of `master.pcm`/`master.wav` (D-MASTER: stereo, or mono on a mono device). |
| `channel_layout.captured_inputs` | int[] | Hardware input indices monitored at arm time (frozen for the session, D-INPUT); each has an `input-<n>.pcm` / `live-input-<n>.wav`. |
| `capture_frames` | int | Total frames elapsed since arm, regardless of any ring drop. |
| `overrun_count` | int | Capture-ring overruns (frames dropped, then silence-filled) since arm. |
| `overrun_gaps` | array | Up to 128 individually-logged `{frame, duration_frames}` gaps (beyond that, frames are still silence-filled, just not itemized here). |
| `layers` | array | Every retired overdub layer's raw PCM, persisted before pool eviction/clear/redo could destroy it (part 5, D-LAYER) — see below. |
| `stopped_early` | string? | `"disk_full"` or `"device_changed"` when capture stopped abnormally; absent for a normal disarm. |
| `armSnapshot` | object? | See below. `null`/absent only if the app crashed before arm's own crash-survival file (`arm-snapshot.json`, deleted at finalize) could even be written. |
| `disarmSnapshot` | object? | See below. Absent for a capture recovered from a crash — there is no live engine left for a second pass. |
| `finalized` | bool | `true` once finalize completed. The sole crash-salvage marker (D-SALVAGE). |

### `layers[]` entries (part 5, unchanged by part 6)

```jsonc
{ "channel": 1, "slot": 4, "generation": 2, "frame": 4800, "frame_count": 480, "lane_count": 1, "filename": "layer-1-4800-4.pcm" }
```

`frame` is a best-effort, buffer-granularity snapshot (not sample-accurate);
cross-reference `channel`/`slot`/`generation` against `events.log`'s
`LE_PLOG_LAYER_RETIRED` entries for the exact retire frame. These raw files
are **not** copied into `loops/` — they exist for the offline renderer (parts
7-8) to reconstruct overdub-pass-by-pass audibility, not as a directly
playable deliverable of this part.

## `armSnapshot`

The state captured at the arm instant — everything the offline renderer and
`.als` generator need to establish t=0, since the engine snapshot alone
cannot supply lane FX chains, monitor configuration, or the limiter state
(those live in `performance_repository`'s caller-supplied `PerformanceChains`,
mirroring how `session_repository`'s `SessionChains` works for session saves).

```jsonc
{
  "clockFrame": 0,
  "masterLenFrames": 96000,
  "masterGain": 1.0,
  "limiterOn": true,
  "limiterCeiling": 0.99,
  "latencyOffsetFrames": 128,
  "tracks": [ /* see below */ ],
  "monitors": [
    { "input": 0, "enabled": true, "outputMask": 3, "volume": 1.0, "muted": false, "effects": [ /* see FX entries */ ] }
  ]
}
```

| Field | Notes |
|---|---|
| `clockFrame` | Master playhead position at the arm instant. |
| `masterLenFrames` | Master loop length in frames at arm time. |
| `masterGain` | Master output gain at arm time. |
| `limiterOn` / `limiterCeiling` | Master peak limiter state at arm time. |
| `latencyOffsetFrames` | The active device profile's record-offset latency compensation. |
| `tracks` | One entry per **non-empty** track (empty tracks are omitted). |
| `monitors` | One entry per hardware input the caller supplied chain/routing state for. |

### `tracks[]` entries

```jsonc
{ "channel": 0, "state": "playing", "volume": 1.0, "muted": false, "multiple": 1, "lanes": [ /* see below */ ] }
```

`state` is one of the native `le_track_state` names: `empty`, `recording`,
`overdubbing`, `playing`, `stopped`.

### `lanes[]` entries — the ER diagram's `LANE_SNAPSHOT` + `FX_ENTRY`

```jsonc
{ "lane": 0, "lenFrames": 96000, "deferred": false, "pcmRef": "loops/track0-lane0.wav", "effects": [ { "type": 3, "params": [0.35, 0.35, 0.35, 0.0] } ] }
```

| Field | Notes |
|---|---|
| `lane` | Lane index within the track. |
| `lenFrames` | Captured length in frames; `0` when `deferred`. |
| `deferred` | `true` when this lane was mid-overdub at snapshot time (D-SNAP) — the audio thread was still writing its buffer, so there is no stable PCM to export here. Its content instead reaches disk via the retired-layer path (`layers[]` above) once the pass retires, or via `disarmSnapshot` if it finishes before disarm. |
| `pcmRef` | The lane's exported WAV filename, relative to the bundle directory (e.g. `loops/track0-lane0.wav`). Absent when `deferred`, or when the lane was empty. |
| `effects` | The lane's effect chain, in order, **only on an arm-time snapshot** ("chain at t=0"). Each entry is a `TrackEffect.toJson()` map verbatim: `{type, params}` for a built-in effect (`type` = the native `le_fx_type` code, `params` = up to 4 normalized `0..1` values), or `{type: 8, plugin: {...}, paramValues?, state?, name?}` for a hosted VST3/CLAP plugin (`PluginRef` identity — `daw_export`'s `fx-chains.txt`, part 10, reads this for third-party plugin identity + passthrough notes). Absent (not an empty array) when there is nothing to report. |

A `disarmSnapshot` lane entry never carries `effects` — chain changes made
during the performance are already in `events.log` (D-LOG), not
re-snapshotted; re-deriving "the chain at disarm" from the log plus the arm
snapshot is a downstream reader's job if it ever needs it.

## `disarmSnapshot`

A second, lighter settled-lane pass taken just before disarm — covers a track
**recorded fresh during the performance and then just played**: recording
finalization produces no retire event (retires are overdub-only), so without
this pass its stem would have no PCM source anywhere (D-SNAP).

```jsonc
{ "tracks": [ { "channel": 2, "state": "playing", "volume": 1.0, "muted": false, "multiple": 1, "lanes": [ { "lane": 0, "lenFrames": 48000, "deferred": false, "pcmRef": "loops/track2-lane0.wav" } ] } ] }
```

Same `tracks[]`/`lanes[]` shape as `armSnapshot`, minus `effects` (see
above) and minus the top-level clock/master/limiter/monitor fields (nothing
there needs a second capture).

## Reconciling `armSnapshot` and `disarmSnapshot` for `loops/`

A downstream reader building the full "what PCM exists for track *t* lane
*l*" picture should prefer `disarmSnapshot`'s entry when present, falling
back to `armSnapshot`'s — this is exactly what `performance_repository`
itself does when writing `loops/*.wav` (the disarm pass simply re-exports
every currently-settled lane, overwriting the file arm already wrote for
anything unchanged and adding files for anything newly settled since arm).
A lane still `deferred` in **both** snapshots has no `loops/` entry at all;
its content, if it ever retires, lives only in `layers[]`.

## Crash consistency

Because `performance.json` is atomically replaced (not appended), a crash
mid-write leaves the **previous** cycle's complete, valid file on disk — there
is no torn-file case for this format itself (the operating system's own
atomic rename guarantees that, `perf_drain.c`'s `le_pd_atomic_rename`). The
crash-detectable state is purely the `finalized` flag: absent/`false` means
either "still armed" or "crashed before finalize ran," which
`PerformanceRepository.findUnfinalized` cannot itself distinguish (nor needs
to — both cases route to the same recovery path, `recoverCapture`).

The one field genuinely at risk of being lost to a crash is `armSnapshot`
itself, since the drain thread's own rewrites would otherwise clobber it if it
were merged into `performance.json` immediately at arm: `performance_repository`
writes it to its own crash-survival file, `arm-snapshot.json`, right at arm
time, and only folds it into `performance.json` (deleting `arm-snapshot.json`)
once finalize actually runs — normal disarm, or `recoverCapture` reading it
back after a crash.
