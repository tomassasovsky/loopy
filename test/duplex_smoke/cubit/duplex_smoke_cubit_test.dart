import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/duplex_smoke/duplex_smoke.dart';
import 'package:loopy_engine/loopy_engine.dart';

import '../../helpers/helpers.dart';

const _runningSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  channels: 2,
  framesProcessed: 256,
  xrunCount: 0,
  inputRms: 0.1,
  inputPeak: 0.2,
  outputRms: 0.1,
  latencyState: LatencyState.idle,
  measuredLatencyMs: -1,
);

void main() {
  group('DuplexSmokeCubit', () {
    late FakeAudioEngine engine;

    setUp(() {
      engine = FakeAudioEngine()..nextSnapshot = _runningSnapshot;
    });

    test('initial state is idle', () {
      final cubit = DuplexSmokeCubit(engine);
      addTearDown(cubit.close);
      expect(cubit.state.status, DuplexSmokeStatus.idle);
      expect(cubit.state.snapshot, const EngineSnapshot.initial());
    });

    test('exposes the engine version', () {
      final cubit = DuplexSmokeCubit(engine);
      addTearDown(cubit.close);
      expect(cubit.engineVersion, 'fake-engine 0.0.0');
    });

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'start opens the engine and emits running with the snapshot',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) => cubit.start(),
      expect: () => [
        isA<DuplexSmokeState>()
            .having((s) => s.status, 'status', DuplexSmokeStatus.running)
            .having((s) => s.deviceName, 'deviceName', 'Fake Device')
            .having((s) => s.snapshot, 'snapshot', _runningSnapshot),
      ],
      verify: (_) {
        expect(engine.startCalls, 1);
        expect(engine.lastConfig?.passthrough, isTrue);
      },
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'start emits error when the engine fails to start',
      build: () => DuplexSmokeCubit(engine..startResult = EngineResult.device),
      act: (cubit) => cubit.start(),
      expect: () => [
        isA<DuplexSmokeState>()
            .having((s) => s.status, 'status', DuplexSmokeStatus.error)
            .having((s) => s.errorMessage, 'errorMessage', contains('device')),
      ],
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'start is a no-op while already running',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) => cubit
        ..start()
        ..start(),
      verify: (_) => expect(engine.startCalls, 1),
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'refresh emits the latest snapshot while running',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) {
        cubit.start();
        engine.nextSnapshot = _runningSnapshot.copyForTest(
          framesProcessed: 999,
        );
        cubit.refresh();
      },
      skip: 1,
      expect: () => [
        isA<DuplexSmokeState>().having(
          (s) => s.snapshot.framesProcessed,
          'framesProcessed',
          999,
        ),
      ],
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'refresh is ignored when idle',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) => cubit.refresh(),
      expect: () => <DuplexSmokeState>[],
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'stop closes the engine and returns to idle',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) => cubit
        ..start()
        ..stop(),
      skip: 1,
      expect: () => [
        isA<DuplexSmokeState>().having(
          (s) => s.status,
          'status',
          DuplexSmokeStatus.idle,
        ),
      ],
      verify: (_) => expect(engine.stopCalls, 1),
    );

    blocTest<DuplexSmokeCubit, DuplexSmokeState>(
      'measureLatency forwards to the engine while running',
      build: () => DuplexSmokeCubit(engine),
      act: (cubit) => cubit
        ..start()
        ..measureLatency(),
      verify: (_) => expect(engine.measureLatencyCalls, 1),
    );

    test('measureLatency is ignored when idle', () {
      final cubit = DuplexSmokeCubit(engine);
      addTearDown(cubit.close);
      cubit.measureLatency();
      expect(engine.measureLatencyCalls, 0);
    });

    test('close disposes the engine', () async {
      final cubit = DuplexSmokeCubit(engine);
      await cubit.close();
      expect(engine.disposeCalls, 1);
    });
  });
}

/// Test-only helper to vary a single field of a const snapshot.
extension on EngineSnapshot {
  EngineSnapshot copyForTest({int? framesProcessed}) => EngineSnapshot(
    isRunning: isRunning,
    sampleRate: sampleRate,
    bufferFrames: bufferFrames,
    channels: channels,
    framesProcessed: framesProcessed ?? this.framesProcessed,
    xrunCount: xrunCount,
    inputRms: inputRms,
    inputPeak: inputPeak,
    outputRms: outputRms,
    latencyState: latencyState,
    measuredLatencyMs: measuredLatencyMs,
  );
}
