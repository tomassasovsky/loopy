---
title: "refactor: harden the native audio engine (separation of concerns + extensibility)"
type: refactor
date: 2026-06-19
---

## Harden the native audio engine - Extensive

## Overview

The `loopy_engine` package is a mature, real-time-correct audio engine with an
excellent C ABI (`loopy_engine_api.h`) and clean layering **above** the ABI
(`AudioEngine` interface → `LooperRepository` → cubits, with an injectable
`MockAudioEngine`). The robustness debt is concentrated **below** the ABI, inside
a single translation unit: [`packages/loopy_engine/src/engine.c`](../../packages/loopy_engine/src/engine.c)
is **3 817 lines** owning eight unrelated concerns, and its real-time callback
`le_engine_process()` is a **561-line** function.

This plan sequences the fix as **five independently-mergeable PRs**, ordered by
risk and value. The first three are *pure structure* (behaviour-preserving file
surgery and decomposition behind the unchanged ABI); the last two change the
*shape* of internal contracts (effect dispatch, command encoding, Dart interface)
without changing observable behaviour.

| PR | Phase | Concern | One-line change |
|----|-------|---------|-----------------|
| **PR 1** | **S1** | god-file | Split `engine.c` into per-concern translation units behind the unchanged ABI |
| **PR 2** | **S2** | god-function | Decompose `le_engine_process()` into named, individually-testable RT steps |
| **PR 3** | **S3** | effects coupling | Give effects a uniform vtable; one effect = one unit (unblocks plugin hosting) |
| **PR 4** | **S4** | command footgun | Replace ring arg-packing with a typed command union |
| **PR 5** | **S5** | fat interface | Segment the Dart `AudioEngine` into role interfaces (ISP) |

**Goals served:** *maintainability* (S1, S2, S5), *correctness/safety* (S2, S4),
*extensibility* (S3, S4, S5). All five together address "more robust" as one
program of work, sequenced so every PR lands green.

This is a **behaviour-preserving refactor**. The acceptance bar for every PR:
the native test suite (`test_engine_core.c`, `test_midi_core.c`) stays green, all
Dart package + app tests stay green, `flutter analyze` / `bloc_lint` stay clean,
and **no audio output changes** (verified by the existing deterministic
`le_engine_process` golden tests).

## What is deliberately NOT in scope

- No DSP algorithm changes (effects produce bit-identical output).
- No ABI changes in S1–S3 (`loopy_engine_api.h` is frozen). S4 is internal-only
  (ring encoding is private; the public `le_engine_post_command` signature and the
  per-command producer functions are unchanged). S5 is Dart-only.
- No new features (no new effects, backends, or transport modes).
- No threading-model change: the SPSC ring + per-field atomic snapshot + "RT
  callback does no alloc/lock/IO" contract is preserved exactly.

## Problem Statement

### The engine.c monolith (symbol census)

One translation unit currently owns all of:

1. **DSP effects** (~700 lines): `fx_drive/filter/delay/tremolo/octaver/echo/reverb`,
   the phase-vocoder (`le_pv_*`), and the PSOLA pitch tracker (`le_psola_*`).
2. **Looper transport state machine**: `handle_record/stop/play/clear`,
   `finalize_master`, `finalize_master_xfade`, undo/redo, arm/quantize.
3. **The RT callback**: `le_engine_process` (561 lines), `apply_command` (320 lines).
4. **Lifecycle**: `le_engine_create/destroy/configure/start/stop`.
5. **Device enumeration / loopback detection / id resolution**.
6. **Sample-format conversion**: `le_deinterleave_in` / `le_interleave_out`.
7. **Snapshot publishing**: `le_fill_track_snapshot`, viz buffers.
8. **Session persistence**: `export/import/commit`.
9. **Command-ring producers**: every `le_engine_set_*` public setter.

Thread ownership (audio vs control) is encoded only in **comments and field
prefixes** (`a_*` atomics, `audio-thread-local`, `control-thread-owned`), not in
structure. A reviewer cannot see from the file tree which code runs on the RT
thread — the single most important invariant in the system.

### Secondary smells

- **Arg-packing footgun.** `loopy_engine_api.h:108-159` documents *two different*
  bit encodings for lane commands — FX commands pack `(input<<16)|(lane<<8)|index`
  in `arg_i`; output/volume/mute use a flat `input*LE_MAX_LANES+lane` — and the
  header says *"This matches the track lane convention, not a bug."* Needing to
  write "not a bug" marks this as a defect-magnet.
- **God-struct.** `struct le_engine` (engine_private.h:247) holds ~60 fields across
  transport, per-lane FX DSP, monitors, the latency harness, quantize bookkeeping,
  device handles, and the ring.
- **Fat Dart interface.** `AudioEngine` (audio_engine.dart:65) is ~60 methods
  mixing lifecycle, transport, routing, FX, monitoring, session I/O, and metering;
  every consumer and the mock must satisfy all 60.

---

## PR 1 — S1: Split engine.c into per-concern translation units

**Goal:** maintainability. **Risk:** low (no logic moves, only file boundaries).

### Approach

Move functions verbatim into new TUs compiled into the same `loopy_engine` target
(CMakeLists `add_library` source list grows; `add_subdirectory(../src)` on
Windows/Linux and the macOS include-shims pick them up unchanged). Cross-TU helpers
that were `static` get an `engine_private.h` (or a new `engine_dsp.h`) declaration
and lose `static`. The RT-hot inner helpers stay `static inline` in headers where
the audio path needs zero call overhead.

### Target file layout

| New TU | Moved from engine.c | Notes |
|--------|---------------------|-------|
| `engine_fx.c` + `engine_fx.h` | all `fx_*`, `le_pv_*`, `le_psola_*`, reverb tables/reset | the DSP island; consumed by `engine_process.c` only |
| `engine_transport.c` | `handle_*`, `finalize_*`, `track_acquire_slot`, undo/redo, arm/quantize helpers | control-thread + RT-shared transport logic |
| `engine_process.c` | `le_engine_process`, `apply_command`, `le_latency_resolve`, routing helpers | **the only RT-thread TU** — make that explicit in its header banner |
| `engine_snapshot.c` | `le_engine_get_snapshot/track/lane`, `le_fill_track_snapshot`, viz reads, `le_max_fx_latency` | publish side |
| `engine_session.c` | `le_engine_export/import_track`, `le_engine_commit_session` | |
| `engine_devices.c` | enumeration, `le_find_loopback`, `le_resolve_device_id`, `le_classify_*`, `le_*_loopback`, deinterleave/interleave, `le_asio_pick_buffer`, `le_select_backend` | the "talks to miniaudio/ASIO" island |
| `engine_commands.c` | every public `le_engine_set_*` producer + `le_push` | control-thread ring producers |
| `engine_lifecycle.c` | `le_engine_create/destroy/configure/start/stop`, resets, version | |
| `engine.c` (residual) | atomic/bit helpers (`store_f32`, `load_i32`, `comp_pos`), shared utilities | shrinks to a small shared-utility TU |

### Acceptance

- Native + Dart + app suites green; **zero diff in `le_engine_process` golden
  outputs** (the proof the move was mechanical).
- Each new `.c` has a header banner stating its thread ownership.
- `engine.c` drops from 3 817 lines to a small utility core.

---

## PR 2 — S2: Decompose le_engine_process()

**Goal:** maintainability + correctness. **Risk:** low-medium (function-internal).

### Approach

Carve the 561-line RT callback into named `static inline` steps in
`engine_process.c`, each taking the engine + block pointers + frame count:

```
drain_commands()      → apply queued ring commands (calls apply_command)
advance_transport()   → loop clock, master pos, arm/quantize firing
capture_lanes()       → record/overdub into lane buffers (latency-compensated write head)
mix_playback()        → sum active lanes/tracks into the output bus
apply_monitors()      → per-input live-monitor lanes through their FX chains
apply_master_bus()    → master gain + limiter
publish_metering()    → RMS/peak/viz atomics
```

`static inline` keeps it a single compilation unit with no call overhead on the
hot path (verify with `-S` that the inlined assembly is unchanged from today).

### Why it helps correctness

Today you can only test the whole callback as a black box. After this, the
existing `engine_internal.h` test surface can grow targeted entry points
(`le_engine_capture_lanes_for_test`, etc.) so overdub-feedback math, the loop-seam
crossfade, and metering are each provable in isolation — the exact edge cases where
RT bugs hide.

### Acceptance

- Golden RT outputs bit-identical (this is the contract).
- Inlined object code equivalent (spot-check hot path isn't pessimized).
- New per-step deterministic tests added for at least overdub feedback and the
  loop-seam crossfade.

---

## PR 3 — S3: Uniform effect vtable

**Goal:** extensibility. **Risk:** medium (touches every effect + chain dispatch).

### Approach

Replace the per-type `switch` in `fx_apply_chain` with a dispatch table:

```c
typedef struct le_fx_vtable {
  void  (*reset)  (le_fx_state*, int slot, int chan);
  void  (*prepare)(le_fx_state*, int slot, int sr, int cap);   /* lazy alloc */
  void  (*process)(le_fx_state*, int slot, int sr, int cap,
                   float* l, float* r, const float* params);   /* always stereo */
  int   (*latency)(const le_fx_state*, int slot);
} le_fx_vtable;

static const le_fx_vtable LE_FX[LE_FX_TYPE_COUNT] = { ... };
```

Each effect becomes a self-contained file (`fx_reverb.c`, `fx_octaver.c`, …) behind
`engine_fx.h`. `process` is **stereo-in/stereo-out** — this aligns with the
[[effects-always-stereo]] memory (process every FX as stereo, no mono/stereo
juggling). The chain loop becomes `for (i<count) LE_FX[type[i]].process(...)`.

### Payoff

The API header already anticipates *"a hosted VST3/CLAP plugin can later slot in as
just another type."* A vtable is exactly the seam that unblocks it: a hosted plugin
becomes one more `le_fx_vtable` entry whose `process` calls into the plugin host —
no change to the chain runner, the command set, or the snapshot.

### Acceptance

- Per-effect golden outputs bit-identical to pre-refactor.
- `le_engine_lane_fx_chain_for_test` (the stereo-decorrelation test) still passes.
- Adding a no-op `LE_FX_NONE` through the table is the regression guard for empty
  chains.

---

## PR 4 — S4: Typed command union

**Goal:** correctness + extensibility. **Risk:** medium (internal contract change).

### Approach

`le_command` (in `lockfree_ring.h`) becomes a tagged union keyed on
`le_command_code`, so producers write **named fields** and `apply_command` reads
named fields. The SPSC ring mechanics (capacity, atomics, drain) are untouched —
only the payload shape changes.

```c
typedef struct le_command {
  int32_t code;
  union {
    struct { int32_t channel, lane, index, type; } fx;
    struct { int32_t channel, lane; uint32_t mask; } route;
    struct { int32_t channel, lane; float value;   } gain;
    /* … one arm per command family … */
  } u;
} le_command;
```

This **deletes the dual-encoding footgun** (`(input<<16)|(lane<<8)|index` vs
`input*LE_MAX_LANES+lane`) entirely. The public `le_engine_post_command` and each
`le_engine_set_*` keep their signatures; only their *bodies* change to fill the
union instead of bit-packing.

### Acceptance

- All lane/monitor command tests pass unchanged (they drive the public setters).
- A new test asserts a full round-trip of every command family through the ring
  (producer → drain → `apply_command` → observable state), which the packed
  encoding never had end-to-end.

---

## PR 5 — S5: Segment the Dart AudioEngine interface

**Goal:** maintainability + extensibility. **Risk:** low (Dart-only, type-checked).

### Approach

Split the ~60-method `AudioEngine` into role interfaces, with `AudioEngine`
composing them so existing consumers keep compiling:

```dart
abstract interface class EngineLifecycle  { /* start, stop, version, deviceName, dispose */ }
abstract interface class LooperTransport  { /* record, play, stop, clear, undo, redo, multiple, quantize, recDub, autoRecord */ }
abstract interface class EngineRouting    { /* lane count/input/output/volume/mute, masks */ }
abstract interface class EffectsControl   { /* setLaneFx*, setMonitorLaneFx* */ }
abstract interface class MonitorControl   { /* setMonitorInputEnabled, monitor lane setters */ }
abstract interface class SessionIo        { /* exportTrack, importTrack, commitSession */ }
abstract interface class EngineMetering   { /* snapshot, readVisual, readTrackVisual, detectLoopback, measureLatency, enumerate* */ }

abstract interface class AudioEngine
    implements EngineLifecycle, LooperTransport, EngineRouting,
               EffectsControl, MonitorControl, SessionIo, EngineMetering {}
```

Repositories then depend only on the slice they use (e.g. an effects-focused
repository takes `EffectsControl`, not the whole engine); mocks under test shrink
to the slice exercised. This dovetails with the in-flight
[repository-layer-boundaries](2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md)
work — narrower repository dependencies are exactly that effort's goal.

### Acceptance

- `NativeAudioEngine` and `MockAudioEngine` implement `AudioEngine` (compose all
  roles) with **no method bodies changed**.
- At least one repository narrowed to a role interface to prove the seam.
- All app + package tests green.

---

## Sequencing & rationale

```
S1 (split files) ─▶ S2 (decompose RT fn) ─▶ S3 (fx vtable)
                                              S4 (typed commands)  ─▶ S5 (Dart roles)
```

- **S1 first, always.** Every later phase is far easier to review against a split
  tree than a 3 817-line file. S1 is the lowest-risk, highest-leverage move.
- **S2 before S3.** Decomposing the callback exposes the clean `process(l,r)` call
  site the vtable plugs into.
- **S4 is independent of S3** but shares the "internal contract" review mindset; do
  it after S3 so the effects command family is already the cleanest.
- **S5 last.** Dart-only; benefits from a settled native surface and rides
  alongside the repository-boundaries refactor.

Each PR is independently revertible and green on its own. If priorities force a
stop, **S1 + S2 alone** capture the majority of the maintainability and
correctness value.

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| A "mechanical" move silently changes RT output | Golden `le_engine_process` outputs are the gate on every PR; bit-identical or it doesn't merge |
| Inlining regresses after S2 split | Spot-check hot-path assembly (`-S`); keep steps `static inline` in one TU |
| FX vtable adds indirection cost on the RT thread | Table is `static const`, indices are small ints; verify no measurable callback-time regression |
| Cross-platform build breakage from new TUs | Single source list in `src/CMakeLists.txt`; Win/Linux `add_subdirectory(../src)` and macOS shims need no per-file edits — confirm CI on all three OSes per PR |
| Union change desyncs an unported producer | Compiler enforces the union shape; the new per-family round-trip test catches any missed producer |
