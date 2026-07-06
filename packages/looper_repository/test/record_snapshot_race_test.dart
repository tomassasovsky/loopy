@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
// The REAL native engine (device-free pump) is what makes the command-ring
// drain timing observable; only it and the effect models come from the engine
// package — every other name is the domain type from the looper_repository
// barrel.
import 'package:loopy_engine/loopy_engine.dart'
    show FxFingerprint, PumpedNativeEngine;

/// The record-time snapshot race, pinned against the REAL native engine.
///
/// The bug: recording an input that has monitor FX yielded a DRY take because
/// the engine self-snapshotted from its own ring-deferred monitor state — if
/// record fired before the audio thread drained the FX write, it copied
/// nothing. The fix makes the repository the single record-time snapshot
/// authority: it computes the snapshot from its synchronous cache and pushes it
/// to the engine like any other lane edit, so the take's chain lands regardless
/// of drain timing. This test sets a monitor chain and records WITHOUT a drain
/// in between (the widest race window) and asserts the take's lane chain equals
/// the monitored one after a single drain.
///
/// Self-skips when `LOOPY_ENGINE_LIB` is unset; build it first:
///   export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['LOOPY_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'LOOPY_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late PumpedNativeEngine engine;
  late LooperRepository repo;

  setUp(() {
    engine = PumpedNativeEngine();
    repo = LooperRepository(engine: engine)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );
  });

  tearDown(() async {
    await repo.dispose();
  });

  group('record-time snapshot race (real engine)', () {
    test('monitor FX set then record-from-EMPTY with NO drain between still '
        'lands on the take lane, cache == engine', () {
      // Push a monitor chain on input 0 but DO NOT pump — the FX write is still
      // in flight on the command ring (the monitor count is unpublished). Then
      // record from EMPTY in the SAME turn (no drain) — the ordering the old
      // engine self-snapshot lost the race on. The repo computes the snapshot
      // from its synchronous cache and pushes it; nothing reads ring-deferred
      // engine state.
      repo
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5, 0],
            ),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();

      // A single drain lands both the monitor push and the lane push.
      engine.pump(frames: 0);

      // The take's lane chain equals what was monitored — not dry.
      expect(
        engine.laneFxFingerprint(channel: 0, lane: 0),
        engine.monitorFxFingerprint(input: 0),
      );
      // ...and the repo cache agrees with the engine — the single enforced
      // contract (the pure-sink guarantee).
      expect(
        repo.laneChainFingerprint(0, 0),
        engine.laneFxFingerprint(channel: 0, lane: 0),
      );
      expect(repo.laneEffects(0, 0), hasLength(2));
    });

    test('a dry input leaves a staged lane chain untouched after record '
        '(non-clobber, cache == engine)', () {
      // Stage a lane chain and drain it in; input 0's monitor stays clean.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.filter)],
      );
      engine.pump(frames: 0);
      final staged = engine.laneFxFingerprint(channel: 0, lane: 0);
      expect(staged, isNot(FxFingerprint.offset)); // the stage actually landed

      // Record over a dry monitor: the snapshot copies nothing, so the staged
      // lane chain must survive (never a count=0 clobber).
      repo.record();
      engine.pump(frames: 0);

      expect(engine.laneFxFingerprint(channel: 0, lane: 0), staged);
      expect(repo.laneChainFingerprint(0, 0), staged);
      expect(repo.laneEffects(0, 0), hasLength(1));
    });
  }, skip: skip);
}
