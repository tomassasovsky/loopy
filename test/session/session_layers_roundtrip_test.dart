@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
import 'package:loopy_engine/loopy_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';

/// End-to-end overdub-layer round-trip against the REAL native engine
/// (device-free pump): record a take, stack overdub passes (and undo some),
/// SAVE, wipe the rig, LOAD, and assert the full history is restored — the same
/// undo/redo depths, byte-identical per-layer audio, and working undo/redo.
/// Acceptance criterion of the session overdub-fidelity plan (part 4).
///
/// Save-capture and load-apply go through the SAME bloc-layer mapping the
/// SessionCubit uses (session_mapping.dart).
///
/// Self-skips when `LOOPY_ENGINE_LIB` is unset:
///   export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['LOOPY_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'LOOPY_ENGINE_LIB not set — run packages/loopy_engine/tool/build_test_lib.sh'
      : null;

  late PumpedNativeEngine engine;
  late LooperRepository looper;
  late SessionRepository session;
  late Directory tempDir;
  Timer? pumpDriver;

  const loopFrames = 256;
  const poll = Duration(milliseconds: 1);

  setUp(() {
    engine = PumpedNativeEngine();
    looper = LooperRepository(engine: engine)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );
    session = SessionRepository(engine: engine);
    tempDir = Directory.systemTemp.createTempSync('loopy_layers_session');
    pumpDriver = Timer.periodic(poll, (_) => engine.pump(frames: 0));
  });

  tearDown(() async {
    pumpDriver?.cancel();
    await looper.dispose();
    tempDir.deleteSync(recursive: true);
  });

  // Pumps real frames until the punch-out fade tail retires — an overdub layer
  // in flight would race a capture (save's own settle wait needs this too).
  void settle() {
    for (var k = 0; k < 128; k++) {
      if (!engine.snapshot().tracks.first.layerInFlight) return;
      engine.pump(frames: loopFrames);
    }
    // A stuck fade should fail HERE (clear cause) rather than as a downstream
    // byte mismatch after capturing a mid-fade buffer.
    expect(
      engine.snapshot().tracks.first.layerInFlight,
      isFalse,
      reason: 'punch-out fade never settled',
    );
  }

  // Records a base loop of [base], then [overdubs] passes each adding [step],
  // then [undos] undo taps — leaving a track with undo + redo history.
  void buildTake({
    required double base,
    required int overdubs,
    required int undos,
    double step = 0.1,
  }) {
    looper.record();
    engine.pump(frames: loopFrames, input: base);
    looper.record(); // finalize -> playing
    engine.pump(frames: 0);
    for (var p = 0; p < overdubs; p++) {
      looper.record(); // punch in
      engine.pump(frames: loopFrames, input: step);
      looper.record(); // punch out
      settle();
    }
    for (var u = 0; u < undos; u++) {
      looper.undo();
      engine.pump(frames: 0);
    }
  }

  // The full ordinal-ordered layer set of track 0, lane 0 as it stands now.
  List<Float32List> captureLayers() {
    final t = engine.snapshot().tracks.first;
    final total = t.undoDepth + 1 + t.redoDepth;
    return [for (var o = 0; o < total; o++) engine.exportLayer(0, 0, o)];
  }

  Future<void> saveThenLoad(String dir) async {
    await session.save(dir, chains: chainsFromLooper(looper));
    // Wipe to an empty rig so a failed load would be visible, then load back.
    await looper.applySession(const SessionRig(), clearPollInterval: poll);
    engine.pump(frames: 0);
    final bundle = await session.read(dir);
    await looper.applySession(rigFromBundle(bundle), clearPollInterval: poll);
    engine.pump(frames: 0);
  }

  test(
    'a track with overdub history round-trips its layers and undo/redo',
    () async {
      // Base 0.5, two +0.1 overdubs, then one undo → undo 1, redo 1.
      buildTake(base: 0.5, overdubs: 2, undos: 1);
      settle();

      final before = engine.snapshot().tracks.first;
      expect(before.undoDepth, 1);
      expect(before.redoDepth, 1);
      final preLayers = captureLayers();

      await saveThenLoad('${tempDir.path}/history');

      final after = engine.snapshot().tracks.first;
      expect(after.undoDepth, before.undoDepth);
      expect(after.redoDepth, before.redoDepth);

      // Every layer is byte-identical in ordinal order.
      final postLayers = captureLayers();
      expect(postLayers, hasLength(preLayers.length));
      for (var o = 0; o < preLayers.length; o++) {
        expect(postLayers[o], preLayers[o], reason: 'layer $o differs');
      }

      // Undo/redo actually work on the restored stacks.
      expect(looper.undo().isOk, isTrue);
      engine.pump(frames: 0);
      expect(engine.snapshot().tracks.first.undoDepth, 0);
      expect(engine.snapshot().tracks.first.redoDepth, 2);
      expect(looper.redo().isOk, isTrue);
      engine.pump(frames: 0);
      expect(engine.snapshot().tracks.first.undoDepth, 1);
    },
    skip: skip,
  );

  test(
    'fuzz: random overdub/undo histories all round-trip identically',
    () async {
      // Seeded for reproducibility; on failure the shape is in each reason.
      final rng = Random(0xC0FFEE);
      for (var iter = 0; iter < 24; iter++) {
        final overdubs = rng.nextInt(5); // 0..4 passes
        final undos = overdubs == 0 ? 0 : rng.nextInt(overdubs + 1);
        final base = 0.2 + rng.nextDouble() * 0.5;

        // Fresh track each iteration.
        looper.clear();
        engine.pump(frames: 0);
        await looper.applySession(const SessionRig(), clearPollInterval: poll);
        engine.pump(frames: 0);

        buildTake(base: base, overdubs: overdubs, undos: undos);
        settle();

        final before = engine.snapshot().tracks.first;
        final reason = 'seed shape overdubs=$overdubs undos=$undos iter=$iter';
        expect(before.undoDepth, overdubs - undos, reason: reason);
        expect(before.redoDepth, undos, reason: reason);
        final preLayers = captureLayers();

        await saveThenLoad('${tempDir.path}/fuzz$iter');

        final after = engine.snapshot().tracks.first;
        expect(after.undoDepth, before.undoDepth, reason: reason);
        expect(after.redoDepth, before.redoDepth, reason: reason);
        final postLayers = captureLayers();
        expect(postLayers, hasLength(preLayers.length), reason: reason);
        for (var o = 0; o < preLayers.length; o++) {
          expect(postLayers[o], preLayers[o], reason: '$reason layer $o');
        }

        // Functionally exercise the restored stacks (not just their depths): a
        // rebuild that wired pool slots to the wrong ordinal would keep bytes
        // identical yet break navigation. Undo (or redo) once and assert the
        // depth actually shifts.
        if (after.undoDepth > 0) {
          expect(looper.undo().isOk, isTrue, reason: reason);
          engine.pump(frames: 0);
          expect(
            engine.snapshot().tracks.first.undoDepth,
            after.undoDepth - 1,
            reason: '$reason undo',
          );
        } else if (after.redoDepth > 0) {
          expect(looper.redo().isOk, isTrue, reason: reason);
          engine.pump(frames: 0);
          expect(
            engine.snapshot().tracks.first.redoDepth,
            after.redoDepth - 1,
            reason: '$reason redo',
          );
        }
      }
    },
    skip: skip,
  );
}
