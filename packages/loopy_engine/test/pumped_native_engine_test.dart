@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// Drives the REAL native engine through the device-free pump: configure (no
/// device), record a loop by pumping blocks, and read the snapshot back —
/// the foundation the app-level sequence fuzzer builds on.
///
/// Self-skips when `LOOPY_ENGINE_LIB` is unset; build it first:
///   export LOOPY_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['LOOPY_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'LOOPY_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  test('records, plays, undoes, and redoes a loop with no audio device', () {
    final engine = PumpedNativeEngine();
    addTearDown(engine.dispose);

    expect(
      engine.start(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      ),
      EngineResult.ok,
    );

    // Define a 256-frame loop of 0.5, then punch one +0.25 dub pass.
    expect(engine.record(), EngineResult.ok);
    engine.pump(frames: 256, input: 0.5);
    expect(engine.record(), EngineResult.ok); // finalize -> PLAYING
    engine.pump(frames: 0);
    var s = engine.snapshot();
    expect(s.isRunning, isTrue); // the pump reports a live "device"
    expect(s.tracks.first.state, TrackState.playing);
    expect(s.tracks.first.lengthFrames, 256);
    expect(s.masterLengthFrames, 256);

    expect(engine.record(), EngineResult.ok); // punch in
    engine.pump(frames: 256, input: 0.25); // one full pass
    expect(engine.record(), EngineResult.ok); // punch out
    engine
      ..pump(frames: 0)
      ..pump(frames: 8) // settle the punch envelope
      ..pump(frames: 0); // block update winds the capture session down
    s = engine.snapshot();
    expect(s.tracks.first.undoDepth, 1);

    expect(engine.undo(), EngineResult.ok);
    s = engine.snapshot();
    expect(s.tracks.first.undoDepth, 0);
    expect(s.tracks.first.redoDepth, 1);
    expect(engine.redo(), EngineResult.ok);
    s = engine.snapshot();
    expect(s.tracks.first.redoDepth, 0);
  }, skip: skip);
}
