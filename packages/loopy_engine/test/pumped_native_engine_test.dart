@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:typed_data';

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

  test('exportTrackLane reads lane 0 through the real FFI', () {
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

    expect(engine.record(), EngineResult.ok);
    engine.pump(frames: 64, input: 0.75);
    expect(engine.record(), EngineResult.ok); // finalize -> PLAYING
    engine.pump(frames: 0);

    final lane0 = engine.exportTrackLane(0, 0);
    expect(lane0.length, 64);
    expect(lane0, everyElement(closeTo(0.75, 1e-6)));

    // Matches the legacy lane-0-only entry point byte-for-byte.
    expect(lane0, engine.exportTrack(0));

    // An unallocated lane on this single-lane track yields an empty export,
    // not an error the Dart layer surfaces. Note this exercises
    // le_engine_get_lane's bounds check over FFI, not
    // le_engine_export_track_lane's own guards — exportTrackLane reads the
    // lane's length first and short-circuits to an empty list before ever
    // calling the native export function once that length is <= 0 (mirrors
    // exportTrack's identical pattern). The native function's own guards are
    // covered directly by test_export_track_lane_multi_lane in
    // test_engine_core.c.
    expect(engine.exportTrackLane(0, 7), isEmpty);
  }, skip: skip);

  test('importTrackLane restores multiple lanes through the real FFI', () {
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

    // Reload two lanes from Dart PCM into a fresh, empty track and commit.
    final lane0 = Float32List.fromList(List<double>.filled(64, 0.5));
    final lane1 = Float32List.fromList(List<double>.filled(64, -0.25));
    expect(engine.importTrackLane(0, 0, lane0), EngineResult.ok);
    expect(engine.importTrackLane(0, 1, lane1), EngineResult.ok);
    expect(engine.commitSession(64), EngineResult.ok);
    engine.pump(frames: 0);

    final s = engine.snapshot();
    expect(s.tracks.first.state, TrackState.playing);
    expect(s.tracks.first.laneCount, 2);
    expect(engine.exportTrackLane(0, 0), everyElement(closeTo(0.5, 1e-6)));
    expect(engine.exportTrackLane(0, 1), everyElement(closeTo(-0.25, 1e-6)));

    // Importing into the now-committed (non-empty) track is rejected.
    expect(engine.importTrackLane(0, 0, lane0), EngineResult.invalid);
  }, skip: skip);

  test(
    'performance-recording capture arms via the real FFI and advances frames',
    () {
      final engine = PumpedNativeEngine();
      addTearDown(engine.dispose);
      engine.start(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );

      expect(engine.snapshot().isPerfArmed, isFalse);

      // A real capture dir: arm now spawns a real drain thread that writes
      // real files there (part 2), so this must be a scratch temp dir, never
      // a relative path that would litter the working directory.
      final captureDir = Directory.systemTemp.createTempSync(
        'loopy_perf_ffi_test_',
      );
      addTearDown(() => captureDir.deleteSync(recursive: true));

      expect(engine.perfArm(captureDir.path), EngineResult.ok);
      engine.pump(frames: 0); // drain the arm command
      var s = engine.snapshot();
      expect(s.isPerfArmed, isTrue);
      expect(s.perfFrames, 0);

      engine.pump(frames: 256);
      s = engine.snapshot();
      // Struct-layout smoke test: perfFrames/perfOverruns actually read the
      // fields the C header declares them at, not a neighbor's bits.
      expect(s.perfFrames, 256);
      expect(s.perfOverruns, 0); // well within the ~2 s capture window

      // perfDisarm blocks on joining the drain thread (part 2), which runs
      // its own final drain-and-flush pass before the call returns — so the
      // files are already complete by the time this line executes, with no
      // wait needed.
      expect(engine.perfDisarm(), EngineResult.ok);
      engine.pump(frames: 0); // drain the disarm command (no device: no wait)
      expect(engine.snapshot().isPerfArmed, isFalse);

      expect(
        File('${captureDir.path}/performance.json').existsSync(),
        isTrue,
      );
      expect(File('${captureDir.path}/master.pcm').existsSync(), isTrue);
    },
    skip: skip,
  );

  group('fx chain fingerprint (native-side properties)', () {
    late PumpedNativeEngine engine;

    setUp(() {
      engine = PumpedNativeEngine()
        ..start(
          const EngineConfig(
            sampleRate: 48000,
            inputChannels: 1,
            outputChannels: 1,
            maxLoopFrames: 48000,
          ),
        );
    });
    tearDown(() => engine.dispose());

    void applyLaneChain(List<TrackEffectType> types) {
      for (var i = 0; i < types.length; i++) {
        engine.setLaneFx(channel: 0, lane: 0, index: i, type: types[i]);
      }
      engine
        ..setLaneFxCount(channel: 0, lane: 0, count: types.length)
        ..pump(frames: 0); // drain the fx ring commands
    }

    test('an empty lane fingerprints to the FNV offset basis', () {
      expect(
        engine.laneFxFingerprint(channel: 0, lane: 0),
        FxFingerprint.offset,
      );
    });

    test('reordering the chain changes the fingerprint (order-sensitive)', () {
      applyLaneChain([TrackEffectType.drive, TrackEffectType.reverb]);
      final fpAb = engine.laneFxFingerprint(channel: 0, lane: 0);
      applyLaneChain([TrackEffectType.reverb, TrackEffectType.drive]);
      final fpBa = engine.laneFxFingerprint(channel: 0, lane: 0);
      expect(fpAb, isNot(fpBa));
    });
  }, skip: skip);
}
