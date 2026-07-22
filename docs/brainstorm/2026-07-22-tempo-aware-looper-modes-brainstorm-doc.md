---
date: 2026-07-22
topic: tempo-aware-looper-modes
---

# Tempo-Aware Engine + Five Looper Modes (Sheeran Looper X parity)

## What We're Building

A tempo-aware rework of the engine and app that brings loopy to feature parity
with the Sheeran Looper X's tempo system: BPM (30–300) + time signature, a
synthesized click with count-in, tap tempo, musical (beat/bar) quantization,
and the Sheeran's **five looper modes** — Multi, Sync, Song, Band, Free — plus
MIDI clock send *and* receive, per-track length presets (AUTO / 1–64 bars with
auto tempo detection), and time-stretch (Sync Audio to Tempo, 0.5×–2×
pitch-preserved).

Today's tempo-free workflow is preserved exactly: it becomes **Multi mode with
all grid features off**, and that path must remain **bit-identical** to
current behavior (the existing native + Dart test suites pass unchanged —
the "acceptance gate: invisibility" pattern proven by the ASIO device-backend
seam).

## Why This Approach

Three delivery shapes were considered:

- **Phased PR series** ← chosen. Grid first, then modes, then clock I/O, then
  stretch. Each phase ships green behind the bit-identical guarantee. Matches
  the repo's stacked-PR workflow (the VST3 hosting stack shipped the same
  way at similar scale).
- **Big-bang rework branch** — rejected: unreviewable at this scale, and the
  repo's known squash-merge landmines make one giant long-lived branch risky.
- **Modes-first, tempo-second** — rejected: Sync/Band are meaningless without
  a grid to quantize against; it orders dependencies backwards.

Mode semantics follow the Sheeran exactly rather than redefining Free mode to
mean "today's loopy": today's behavior is structurally Multi (one master loop,
phase-locked tracks), while Sheeran Free mode (four un-synced,
independent-length tracks) is a genuinely new engine capability loopy gains.

## Key Decisions

- **Full parity scope**: core grid + MIDI clock send + MIDI clock receive +
  Track Length presets + time-stretch are all in scope. Nothing from the
  Sheeran tempo system is dropped.
- **8 tracks, one primary**: modes govern all 8 loopy tracks (banks stay
  presentation-only). Sync/Band designate a single engine-wide primary track
  (crown, Wave-view style). No change to `LE_MAX_TRACKS`.
- **Today's workflow = Multi with grid off**: the bit-identical guarantee
  attaches to this path. Free mode adopts Sheeran semantics
  (independent-length, un-synced tracks → per-track clocks in the engine).
- **Loop multiples (×N) fold into Sync semantics**: the existing
  auto-round-up multiple machinery is the seed of Sync/Band's
  multiple-or-division quantization; it stays available in grid-off Multi
  unchanged.
- **Phase order**: A) core grid in Multi (resurrect + modernize the deleted
  tempo stack from `2f0513a`: click synthesis, count-in, tap tempo, beat/bar
  quantize arming, loop↔tempo sync); B) five modes incl. primary-track sync
  and Free's independent clocks; C) MIDI clock send (loopy as master), then
  receive (slave, with drift correction and per-mode downbeat arming per
  Sheeran §6.2.1); D) time-stretch, vendoring the MIT-licensed Signalsmith
  Stretch library (repo is GPLv3 — compatible).
- **Mode naming**: the existing `LooperMode` enum (record/play) is a
  different axis — it gets renamed (interaction mode) and the new
  Multi/Sync/Song/Band/Free enum takes a distinct name. Resolved at planning.
- **Session manifest bumps 3→4**: adds tempo/time-signature/mode/primary
  fields; v3 sessions load as Multi with grid off (no migration loss).
- **Pedal protocol bump**: the wire `PedalMode` flag is a single bit and
  cannot carry five modes — the state-frame format gains a wider field, with
  a firmware + `PedalCodec` version bump.
- **Old code is reference, not revert**: `2f0513a` (−1,706 lines) documents
  the previous commands (`LE_CMD_SET_TEMPO/…_METRONOME/…_COUNT_IN/…_TAP_TEMPO/
  …_SYNC_TEMPO/…_QUANTIZE`), snapshot atomics, and Dart models; the engine
  has since gained lanes/monitors/perf-recording, so everything is
  re-implemented against the current core.

## Open Questions

- **Free-mode clock architecture**: per-track `le_loop_clock` instances vs. a
  master clock with per-track free-running offsets — decide in planning
  (affects perf-recording timeline and the viz tap).
- **Time signature scope**: Sheeran supports 15 signatures (2/4…15/8); the
  old loopy stack hard-coded 4/4. Full list from day one, or 4/4 + common
  signatures first?
- **Time-stretch RT budget**: Signalsmith Stretch quality presets vs. CPU on
  the audio thread across 8 tracks × lanes — needs a spike before Phase D is
  planned in detail.
- **MIDI clock receive edge cases**: behavior when external clock stops
  mid-record; Sheeran disables manual tempo changes and forces Sync Audio to
  Tempo on — adopt the same restrictions?
- **DAW export**: once BPM exists, `.als` export should emit real tempo +
  bar-aligned clips — in-scope for Phase A or a follow-up?
- **Quantize UI granularity**: Sheeran offers 1 bar / 1/2 / 1/4 / 1/8 / 1/16
  note; old loopy had beat/bar only. Adopt the Sheeran list.
