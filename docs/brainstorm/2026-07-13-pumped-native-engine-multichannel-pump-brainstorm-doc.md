---
date: 2026-07-13
topic: pumped-native-engine-multichannel-pump
---

# PumpedNativeEngine.pump() multi-channel buffer sizing fix

**Autonomous run note:** this document was produced without an interactive
user session (one of 21 parallelized single-issue fixes across isolated
worktrees). Decisions below were made directly rather than via dialogue, per
the parent task's instruction to proceed autonomously and document
assumptions instead of blocking on questions.

## What We're Building

`PumpedNativeEngine.pump()` in
`packages/loopy_engine/lib/src/native_audio_engine.dart` currently allocates
its native input/output scratch buffers sized by `frames` alone:

```dart
final inPtr = calloc<Float>(frames == 0 ? 1 : frames);
final outPtr = calloc<Float>(frames == 0 ? 1 : frames);
...
_bindings.le_engine_process(_engine, outPtr, inPtr, frames);
```

But the native block processor (`engine_process.c`, `le_engine_process`)
treats both buffers as **interleaved** across the engine's *configured*
channel counts (`ch_in`/`ch_out`, sourced from `e->in_channels` /
`e->out_channels`, which `PumpedNativeEngine.start()` sets verbatim from
`EngineConfig.inputChannels`/`outputChannels` via `le_engine_configure`). A
caller that configures `inputChannels: 2` / `outputChannels: 2` and then
pumps `frames > 0` causes the native side to read/write `frames * 2` floats
against buffers Dart only allocated as `frames` floats each — a native heap
overflow with no Dart-side error.

This is currently **latent, not exercised**: every in-repo caller either uses
1-channel configs, or (the one 2-channel test,
`'importTrackLane restores multiple lanes...'` in
`packages/loopy_engine/test/pumped_native_engine_test.dart`) only ever calls
`pump(frames: 0)`, which touches zero elements regardless of channel count.

The fix: make `pump()`'s buffer allocation channel-aware, by tracking the
configured input/output channel counts in `PumpedNativeEngine` (set in
`start()`, mirroring the existing `_sampleRate` field) and using them to size
`inPtr`/`outPtr` as `frames * channels` in `pump()`. Add a regression test
that actually pumps `frames > 0` against a 2-channel configuration, which is
the exact gap the review finding calls out.

## Why This Approach

Two directions were on the table per the finding:

**(a) Make `pump()` channel-aware (chosen).** Track `_inputChannels` /
`_outputChannels` from `start()`, allocate `frames * channels` per buffer in
`pump()`.

- Pros: mechanical, low-risk, one file touched; preserves the class's
  existing capability (2-channel engines are already configured and tested
  today, just not pumped with real frames); doesn't reduce what test authors
  can do with the harness.
- Cons: `pump()`'s Dart-facing API still only exposes a single scalar
  `input` value broadcast across every channel — it doesn't let a caller
  inject distinct per-channel signal or read back per-channel output. That's
  an existing limitation of `pump()`, not something this fix introduces or
  needs to solve (see below).

**(b) Guard `start()` to reject non-mono channel counts.**

- Pros: simplest possible code change (one assertion).
- Cons: **breaks an existing, currently-passing test** —
  `'importTrackLane restores multiple lanes through the real FFI'` starts a
  `PumpedNativeEngine` with `inputChannels: 2, outputChannels: 2` today
  (exercising the import/export/lane-count path, not `pump(frames > 0)`).
  Rejecting that in `start()` would be a regression, not a fix. This
  direction was ruled out.

(a) is the only option that doesn't regress existing coverage, and it directly
addresses the described defect (buffer sizing, not a design/API restriction).

### On `pump()`'s existing scalar/void API

`pump()` is `void` and never reads `outPtr` back — the output buffer is
allocated, handed to native, and freed unread. `input` is a single `double`
broadcast to fill every sample of the input buffer (same value repeated), not
a per-channel array. This was true before this fix and stays true after it:
the fix corrects buffer *sizing* to match the already-interleaved native
contract; it does not add per-channel input/output plumbing to `pump()`'s
public signature, because:

1. No caller today needs per-channel signal injection or per-channel output
   readback through `pump()` — every existing test drives channel-specific
   behavior (import/export, lane routing) through the other FFI calls on
   `PumpedNativeEngine`, using `pump()` purely to advance the transport/drain
   command rings.
2. Expanding `pump()`'s API (e.g., `List<double> input` per channel, or
   returning captured output) would be scope creep beyond the reported
   defect — a real feature addition, not a bug fix. If a future test needs
   distinguishable multi-channel signal or output readback, that's a
   separate, deliberate API extension.

Broadcasting the same scalar `input` value across every configured input
channel (rather than, say, only filling channel 0 and leaving the rest zero)
was chosen because it's the natural generalization of current mono behavior
("every input frame carries this constant") and keeps `pump()`'s contract
simple and uniform across channels.

## Key Decisions

- **Store `_inputChannels`/`_outputChannels` in `PumpedNativeEngine`**, set in
  `start()` from the clamped values already computed for
  `le_engine_configure` (`config.inputChannels > 0 ? config.inputChannels :
  1`, same for output) — mirrors the existing `_sampleRate` field exactly, so
  no new clamping logic is introduced.
- **`pump()` allocates `frames * _inputChannels` for `inPtr` and
  `frames * _outputChannels` for `outPtr`** (still guarding the frames==0 case
  with a minimum size of at least the channel count, so `calloc` is never
  called with 0 — mirrors today's `frames == 0 ? 1 : frames` guard, now
  `frames == 0 ? channels : frames * channels`).
- **Input fill broadcasts across all channels**: the loop that fills `inPtr`
  with the constant `input` value iterates
  `frames * _inputChannels` elements, not `frames`.
- **No change to `pump()`'s public signature** (still
  `void pump({int frames = 512, double input = 0})`) — see rationale above.
- **No guard/assertion added to `start()`** rejecting non-mono channel
  counts — direction (b) was rejected as a regression risk (see above).
- **New regression test**: extend
  `packages/loopy_engine/test/pumped_native_engine_test.dart` with a case
  that starts a 2-channel (or asymmetric, e.g. 2-in/1-out) `PumpedNativeEngine`
  and calls `pump(frames: N)` with `N > 0` (not just `frames: 0`), then
  performs a real record/play/export round trip to prove the corrected
  buffers behave sanely end-to-end (not just "didn't crash"). This is the
  exact gap the review finding calls out.
- **No sanitizer/ASAN wiring added.** Checked
  `packages/loopy_engine/tool/build_test_lib.sh`: it compiles with plain
  `gcc -O2 -fPIC`, no `-fsanitize=address`. Adding sanitizer support to the
  test-lib build script is out of scope for this narrowly-scoped Dart-side
  fix (it's shared native build infra, not part of the reported issue, and
  touching it risks colliding with other parallel fixes in sibling
  worktrees). The new test's guarantee is therefore *functional* — it proves
  a 2-channel pump with real frames records/exports correct per-lane values
  through the real native engine — rather than an instrumented
  memory-corruption proof. This is an accepted limitation, documented here
  rather than silently assumed.

## Open Questions

None blocking; the above resolves every decision point the finding raised.
If a future need arises for `pump()` to inject/read distinguishable
per-channel signal, that should be scoped as its own follow-up rather than
folded into this fix.
