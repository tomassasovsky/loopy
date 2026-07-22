# Control-sequence fuzzer

Drives the **real native engine** (no audio device) plus the real
`LooperRepository`, `LooperBloc`, `PedalCubit` and `TracksCubit` with seeded
random event sequences across every control surface, and checks the
control-surface invariant spec ([lib/control/invariants.dart](../../lib/control/invariants.dart))
after every settled step. The same spec runs as debug-mode asserts on every
pedal frame projection — documentation and enforcement are one artifact.

Two kinds of rules run per step:

- **State invariants** — predicates over one settled state (also asserted at
  projection time), e.g. `capturing-never-muted`: a recording/overdubbing
  track is never muted (starting a capture auto-unmutes; a mute issued
  mid-capture punches out and lands at the capture end).
- **Transition rules** — predicates over the settled `(pre, post)` pair
  around one action, fuzz-only (no single frame can check them), e.g.
  `unpark-on-start`: starting to record or play anything while the transport
  is held must resume every content track (mutes preserved).

## Run it

```sh
export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
flutter test --tags fuzz
```

Without `LOOPY_ENGINE_LIB` the suite self-skips, so plain `flutter test`
stays green everywhere. CI runs it as the `fuzz` job (.github/workflows/main.yaml).

Scale the search:

```sh
flutter test --tags fuzz \
  --dart-define=LOOPY_FUZZ_SEEDS=200 \
  --dart-define=LOOPY_FUZZ_STEPS=300 \
  --dart-define=LOOPY_FUZZ_BASE=12345
```

## When it fails

The output is a seed plus a **shrunk, replayable action list**:

```
seed 6407 violated the spec: step 21 (_Bloc('record', 7)): capturing-red-in-rec: ...
shrunk repro (1/120 steps):
[
  _Bloc('record', 7)
]
```

Reproduce by pasting the list into a corpus test (below) or re-running the
seed via `--dart-define=LOOPY_FUZZ_BASE=<seed> --dart-define=LOOPY_FUZZ_SEEDS=1`.

## Add a corpus case

Every found bug becomes a permanent regression: add a test to the
`corpus` group in `control_sequence_fuzz_test.dart` replaying the shrunk
sequence with an explicit expectation, named with the date and the invariant
it tripped. The corpus replays on every run, before the random seeds.

## Determinism rules

- Everything runs under `FakeAsync`: the undo long-press timer, debounce, and
  settle timing are fuzzer actions (`_Elapse`, `_LongPressUndo`), never wall
  time.
- The repository's snapshot poll is an injected ticker — `_Tick` is an
  explicit action, separate from engine `_Pump`s, so snapshot-lag races are
  reachable.
- The PRNG is a hand-rolled xorshift: identical sequences on every platform.
- Invariants assert on **settled** states (pump + tick + microtask flush,
  twice). Deliberate-disarm APIs are excluded from the alphabet — see the
  `fuzzOnly` note in the invariant spec.
