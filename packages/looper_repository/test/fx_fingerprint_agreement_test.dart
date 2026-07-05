@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
// Only the native pump engine + the fingerprint constant come from the engine
// package; every other name (EngineConfig, the effect models) is the domain
// type from the looper_repository barrel.
import 'package:loopy_engine/loopy_engine.dart'
    show FxFingerprint, PumpedNativeEngine;

/// Proves the Dart [trackChainFingerprint] and the native
/// `le_engine_*_fx_fingerprint` compute the IDENTICAL hash for the same chain —
/// the guarantee the sequence fuzzer's `cache == engine` invariant relies on.
/// Drives the REAL native engine through the device-free pump.
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

  /// Pushes [chain] to lane 0 through the repository (so both cache and engine
  /// update), then drains the fx ring so the engine has published it.
  void applyLane(List<TrackEffect> chain) {
    repo.setLaneEffects(channel: 0, lane: 0, effects: chain);
    engine.pump(frames: 0);
  }

  group('lane fingerprint agreement', () {
    test('empty chain: both sides yield the offset basis', () {
      expect(repo.laneChainFingerprint(0, 0), FxFingerprint.offset);
      expect(
        engine.laneFxFingerprint(channel: 0, lane: 0),
        FxFingerprint.offset,
      );
    });

    test('a built-in chain with custom params agrees exactly', () {
      final chain = [
        BuiltInEffect(
          type: TrackEffectType.delay,
          params: const [0.3, 0.4, 0.5, 0],
        ),
        BuiltInEffect(type: TrackEffectType.reverb),
      ];
      applyLane(chain);

      expect(
        repo.laneChainFingerprint(0, 0),
        engine.laneFxFingerprint(channel: 0, lane: 0),
      );
      // And equals the pure-Dart hash of the same chain.
      expect(repo.laneChainFingerprint(0, 0), trackChainFingerprint(chain));
    });

    test('clearing a lane returns both sides to the empty basis', () {
      applyLane([BuiltInEffect(type: TrackEffectType.drive)]);
      applyLane(const []);
      expect(repo.laneChainFingerprint(0, 0), FxFingerprint.offset);
      expect(
        engine.laneFxFingerprint(channel: 0, lane: 0),
        FxFingerprint.offset,
      );
    });
  }, skip: skip);

  group('monitor fingerprint agreement', () {
    test('a monitor chain agrees between cache and engine', () {
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.echo)],
      );
      engine.pump(frames: 0);

      expect(
        repo.monitorChainFingerprint(0),
        engine.monitorFxFingerprint(input: 0),
      );
    });
  }, skip: skip);
}
