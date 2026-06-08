import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const EngineConfig()));

  late LooperRepository repository;
  late StreamController<LooperState> stateController;

  setUp(() {
    repository = _MockLooperRepository();
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(() => repository.startEngine(any())).thenReturn(EngineResult.ok);
    when(repository.stopEngine).thenReturn(EngineResult.ok);
    when(repository.measureLatency).thenReturn(EngineResult.ok);
  });

  tearDown(() => stateController.close());

  AudioSetupCubit buildCubit() => AudioSetupCubit(repository: repository);

  test('initial state has sensible defaults', () {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    expect(cubit.state.sampleRate, 48000);
    expect(cubit.state.bufferFrames, 128);
    expect(cubit.state.monitorInput, isTrue);
    expect(cubit.state.status, AudioSetupStatus.stopped);
  });

  blocTest<AudioSetupCubit, AudioSetupState>(
    'option setters update the requested config',
    build: buildCubit,
    act: (cubit) => cubit
      ..setSampleRate(96000)
      ..setBufferFrames(64)
      ..setMonitorInput(monitorInput: false),
    expect: () => [
      isA<AudioSetupState>().having((s) => s.sampleRate, 'sampleRate', 96000),
      isA<AudioSetupState>().having((s) => s.bufferFrames, 'bufferFrames', 64),
      isA<AudioSetupState>().having(
        (s) => s.monitorInput,
        'monitorInput',
        false,
      ),
    ],
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'start opens the engine with the current options',
    build: buildCubit,
    act: (cubit) => cubit.start(),
    expect: () => [
      isA<AudioSetupState>().having(
        (s) => s.status,
        'status',
        AudioSetupStatus.running,
      ),
    ],
    verify: (_) => verify(
      () => repository.startEngine(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          channels: 2,
          passthrough: true,
        ),
      ),
    ).called(1),
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'start surfaces an error when the engine fails',
    build: buildCubit,
    setUp: () => when(
      () => repository.startEngine(any()),
    ).thenReturn(EngineResult.device),
    act: (cubit) => cubit.start(),
    expect: () => [
      isA<AudioSetupState>()
          .having((s) => s.status, 'status', AudioSetupStatus.error)
          .having((s) => s.errorMessage, 'errorMessage', contains('device')),
    ],
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'stop closes the engine',
    build: buildCubit,
    act: (cubit) => cubit.stop(),
    verify: (_) => verify(repository.stopEngine).called(1),
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'measureLatency forwards to the repository',
    build: buildCubit,
    act: (cubit) => cubit.measureLatency(),
    verify: (_) => verify(repository.measureLatency).called(1),
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'repository stream updates the engine status',
    build: buildCubit,
    act: (_) => stateController.add(
      const LooperState(
        status: EngineStatus(deviceName: 'Scarlett', isConnected: true),
      ),
    ),
    expect: () => [
      isA<AudioSetupState>()
          .having((s) => s.engineStatus.deviceName, 'deviceName', 'Scarlett')
          .having((s) => s.status, 'status', AudioSetupStatus.running),
    ],
  );
}
