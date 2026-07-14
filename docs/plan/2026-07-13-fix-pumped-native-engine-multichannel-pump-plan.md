---
title: PumpedNativeEngine.pump() sizes I/O buffers by frames only, ignoring channel count
type: fix
date: 2026-07-13
---

## PumpedNativeEngine.pump() sizes I/O buffers by frames only, ignoring channel count - Minimal

`PumpedNativeEngine.pump()` in
`packages/loopy_engine/lib/src/native_audio_engine.dart` allocates its native
scratch buffers as `calloc<Float>(frames == 0 ? 1 : frames)` for both input
and output, then passes them to `_bindings.le_engine_process`. The native
block processor (`packages/loopy_engine/src/core/engine_process.c`) reads and
writes both buffers **interleaved** across the engine's configured channel
counts (`ch_in`/`ch_out`, sourced from `e->in_channels`/`e->out_channels`,
which `PumpedNativeEngine.start()` sets verbatim from
`EngineConfig.inputChannels`/`outputChannels`). A caller configuring
`inputChannels: 2` / `outputChannels: 2` and then calling `pump(frames: N)`
with `N > 0` makes native code read/write `N * 2` floats against Dart buffers
sized for only `N` floats each — a native heap overflow with no Dart-side
error. This is currently latent: the one in-repo 2-channel caller
(`packages/loopy_engine/test/pumped_native_engine_test.dart`,
`'importTrackLane restores multiple lanes...'`) only ever calls
`pump(frames: 0)`, which touches zero elements regardless of channel count.

See `docs/brainstorm/2026-07-13-pumped-native-engine-multichannel-pump-brainstorm-doc.md`
for the full investigation and the rejected alternative (guarding `start()`
against non-mono channel counts — rejected because it would break the
already-passing 2-channel `importTrackLane` test).

## Success Criteria

```success-criteria
GOAL: PumpedNativeEngine.pump() allocates input/output native buffers sized
by frames*channels (using the engine's actual configured channel counts),
eliminating the native heap-overflow risk on multi-channel configs, proven by
a new test that pumps real frames (not just frames: 0) against a 2-channel
engine and checks correct recorded/exported sample values.

SUCCESS CRITERIA:
- pump()'s inPtr allocation uses frames * _inputChannels (not frames alone) | verify: grep -n "calloc<Float>(frames == 0 ? _inputChannels : frames \* _inputChannels)" packages/loopy_engine/lib/src/native_audio_engine.dart
- pump()'s outPtr allocation uses frames * _outputChannels (not frames alone) | verify: grep -n "calloc<Float>(frames == 0 ? _outputChannels : frames \* _outputChannels)" packages/loopy_engine/lib/src/native_audio_engine.dart
- PumpedNativeEngine.start() tracks the configured channel counts | verify: grep -n "_inputChannels =" packages/loopy_engine/lib/src/native_audio_engine.dart && grep -n "_outputChannels =" packages/loopy_engine/lib/src/native_audio_engine.dart
- Package analyzes clean (no new lints/errors) | verify: cd packages/loopy_engine && /Users/Tomas/development/flutter/bin/flutter analyze --no-fatal-infos lib/src/native_audio_engine.dart test/pumped_native_engine_test.dart
- New multi-channel pump test exists and passes against the real native engine | verify: cd packages/loopy_engine && LOOPY_ENGINE_LIB="$(bash tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test --tags fuzz test/pumped_native_engine_test.dart
- Full existing fuzz-tagged pump suite still passes (no regression) | verify: cd packages/loopy_engine && LOOPY_ENGINE_LIB="$(bash tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test --tags fuzz test/pumped_native_engine_test.dart

NON-GOALS:
- Changing pump()'s public signature (still `void pump({int frames = 512, double input = 0})`) — no per-channel input injection or output readback added.
- Adding a mono-only guard/assertion in start() — would regress the existing 2-channel importTrackLane test.
- Adding ASAN/sanitizer build flags to tool/build_test_lib.sh — out of scope for this Dart-side fix; the new test proves functional correctness, not instrumented memory-safety.
- Any change outside packages/loopy_engine/lib/src/native_audio_engine.dart and packages/loopy_engine/test/pumped_native_engine_test.dart (this is 1 of 21 parallelized single-issue fixes; other agents own other findings in the same repo).

VERIFICATION COMMAND: cd packages/loopy_engine && /Users/Tomas/development/flutter/bin/flutter analyze --no-fatal-infos lib/src/native_audio_engine.dart test/pumped_native_engine_test.dart && LOOPY_ENGINE_LIB="$(bash tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test --tags fuzz test/pumped_native_engine_test.dart
```

## Context

- File: `packages/loopy_engine/lib/src/native_audio_engine.dart`
  - `PumpedNativeEngine` class starts at line ~1185.
  - Existing `int _sampleRate = 48000;` field at line ~1192 — the new
    `_inputChannels`/`_outputChannels` fields follow the same pattern.
  - `start()` at line ~1196: already computes the clamped channel values
    inline as arguments to `_bindings.le_engine_configure(...)`
    (`config.inputChannels > 0 ? config.inputChannels : 1` and the output
    equivalent) — reuse this exact clamping expression when assigning the new
    fields, don't recompute differently.
  - `pump()` at line ~1219:
    ```dart
    void pump({int frames = 512, double input = 0}) {
      _checkAlive();
      if (frames < 0) return;
      final inPtr = calloc<Float>(frames == 0 ? 1 : frames);
      final outPtr = calloc<Float>(frames == 0 ? 1 : frames);
      try {
        for (var i = 0; i < frames; i++) {
          inPtr[i] = input;
        }
        _bindings.le_engine_process(_engine, outPtr, inPtr, frames);
      } finally {
        calloc
          ..free(inPtr)
          ..free(outPtr);
      }
    }
    ```
- Native contract confirmed in `packages/loopy_engine/src/core/loopy_engine_api.h`
  (doc comment on `le_engine_process`: "records/mixes `frames` frames from
  `input` (interleaved f32, ...) into `output`") and
  `packages/loopy_engine/src/core/engine_process.c` (`ch_in`/`ch_out` derived
  from `e->in_channels`/`e->out_channels`, used as the interleave stride
  throughout, e.g. `in[f * ch_in + c]`, `out[f * ch_out + c]`).
- Test file: `packages/loopy_engine/test/pumped_native_engine_test.dart`
  - `@Tags(['fuzz'])`, self-skips unless `LOOPY_ENGINE_LIB` env var is set.
  - The existing 2-channel test (`'importTrackLane restores multiple lanes
    through the real FFI'`, ~line 108) is the reference config to reuse
    (`sampleRate: 48000, inputChannels: 2, outputChannels: 2, maxLoopFrames:
    48000`) but only calls `pump(frames: 0)` today — this plan adds a
    sibling test that pumps real frames.
  - Known repo gotcha (see MEMORY): `very_good` MCP test runner is broken for
    this package; use the absolute Flutter path
    (`/Users/Tomas/development/flutter/bin/flutter`) directly, not `flutter`
    off PATH or the very_good_cli MCP tool.

## MVP

**1. `native_audio_engine.dart` — new fields** (near `int _sampleRate = 48000;`):

```dart
int _sampleRate = 48000;
int _inputChannels = 1;
int _outputChannels = 1;
```

**2. `start()` — populate the fields using the same clamp already used for the FFI call:**

```dart
@override
EngineResult start(EngineConfig config) {
  _checkAlive();
  _sampleRate = config.sampleRate > 0 ? config.sampleRate : 48000;
  _inputChannels = config.inputChannels > 0 ? config.inputChannels : 1;
  _outputChannels = config.outputChannels > 0 ? config.outputChannels : 1;
  return EngineResult.fromCode(
    _bindings.le_engine_configure(
      _engine,
      _sampleRate,
      _inputChannels,
      _outputChannels,
      config.maxLoopFrames,
    ),
  );
}
```

**3. `pump()` — size buffers by frames * channels:**

```dart
/// Processes [frames] frames of constant [input] through the engine's block
/// processor — the audio callback, minus the device. `frames == 0` still
/// drains the command/event rings and advances per-block maintenance (the
/// native suites' `drain` idiom). Buffers are sized `frames * channels`
/// because the native side treats input/output as interleaved across the
/// engine's configured channel counts (set in [start]); `input` is broadcast
/// as a constant across every input channel.
void pump({int frames = 512, double input = 0}) {
  _checkAlive();
  if (frames < 0) return;
  final inCount = frames == 0 ? _inputChannels : frames * _inputChannels;
  final outCount = frames == 0 ? _outputChannels : frames * _outputChannels;
  final inPtr = calloc<Float>(inCount);
  final outPtr = calloc<Float>(outCount);
  try {
    for (var i = 0; i < frames * _inputChannels; i++) {
      inPtr[i] = input;
    }
    _bindings.le_engine_process(_engine, outPtr, inPtr, frames);
  } finally {
    calloc
      ..free(inPtr)
      ..free(outPtr);
  }
}
```

(The success-criteria grep patterns above are illustrative of intent —
implement with equivalent, readable Dart; exact token spacing doesn't need to
match the grep literally as long as the allocation math is `frames *
channels`. Prefer whichever phrasing is clearest in context; the grep in the
success block may need adjusting to match final formatting during /build's
verification pass — that's expected and fine as long as the underlying
allocation is verifiably channel-aware.)

**4. New test in `pumped_native_engine_test.dart`** — add a test alongside
the existing ones (same style, e.g. after `'importTrackLane restores
multiple lanes...'`):

```dart
test(
  'pump processes real frames on a 2-channel engine without corruption',
  () {
    final engine = PumpedNativeEngine();
    addTearDown(engine.dispose);

    expect(
      engine.start(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 2,
          outputChannels: 2,
          maxLoopFrames: 48000,
        ),
      ),
      EngineResult.ok,
    );

    // Record a real block of nonzero frames (not just frames: 0) on a
    // 2-channel engine — this is the exact path that overflowed the old
    // frames-sized (not frames*channels-sized) native buffers.
    expect(engine.record(), EngineResult.ok);
    engine.pump(frames: 256, input: 0.5);
    expect(engine.record(), EngineResult.ok); // finalize -> PLAYING
    engine.pump(frames: 0);

    final s = engine.snapshot();
    expect(s.tracks.first.state, TrackState.playing);
    expect(s.tracks.first.lengthFrames, 256);

    // Round-trip through export to confirm the recorded samples are the
    // expected constant, not corrupted/garbage from an undersized buffer.
    final lane0 = engine.exportTrackLane(0, 0);
    expect(lane0.length, 256);
    expect(lane0, everyElement(closeTo(0.5, 1e-6)));
  },
  skip: skip,
);
```

Rationale for why this proves the fix: before the fix, `pump(frames: 256)`
on a 2-channel engine makes native code write `256 * 2 = 512` floats into a
`256`-float Dart buffer (`outPtr`) and read `512` floats from a `256`-float
buffer (`inPtr`) — i.e., the native call reads/writes exactly double the
allocated region. This is deterministic (not a maybe-corrupts race): the
buffer is always undersized by exactly `frames * (channels - 1)` elements
whenever `channels > 1` and `frames > 0`. Because `calloc` heap-allocates
back-to-back with other live allocations (`_snapshotPtr`, `_trackPtr`,
`_lanePtr`, `_vizPtr`, or heap metadata), the write past `outPtr`'s bound
corrupts adjacent heap memory; the read past `inPtr`'s bound reads
uninitialized/adjacent heap content as audio input for channel 1, which
generally will not equal the intended constant `0.5` fill from channel 0 —
so a channel-0 export of `0.5` after the fix, contrasted with the
undefined/potentially-crashing behavior before it, functionally demonstrates
the fix. (No ASAN is wired up per the brainstorm's decision, so this is a
functional-correctness proof, not an instrumented memory-safety proof — this
limitation is accepted and documented, not silently assumed.)

Verify locally during /build that this test fails pre-fix: temporarily stash
the `pump()`/`start()` changes (keep only the new test), run the test, and
confirm it fails or crashes; then reapply the fix and confirm it passes. If
the pre-fix run doesn't visibly fail (e.g. because the extra heap headroom
happens to absorb the overflow silently on this platform/allocator), note
that in the PR description honestly rather than claiming a stronger
guarantee than what was actually observed — the test still adds real
regression coverage (the buffer math is provably correct per the source
inspection above) even if it can't be empirically proven to fail on every
allocator.

## References

- Brainstorm: `docs/brainstorm/2026-07-13-pumped-native-engine-multichannel-pump-brainstorm-doc.md`
- `packages/loopy_engine/lib/src/native_audio_engine.dart` (pump, start, PumpedNativeEngine)
- `packages/loopy_engine/src/core/engine_process.c` (le_engine_process interleave contract)
- `packages/loopy_engine/src/core/loopy_engine_api.h` (le_engine_process doc comment)
- `packages/loopy_engine/test/pumped_native_engine_test.dart` (existing test suite, styles to mirror)
- `packages/loopy_engine/tool/build_test_lib.sh` (native test-lib build script, no sanitizers)
