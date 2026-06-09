import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const EngineConfig()));

  late LooperRepository repository;
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late StreamController<LooperState> stateController;

  setUp(() {
    repository = _MockLooperRepository();
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lastEngineConfig).thenReturn(null);
    when(() => repository.startEngine(any())).thenReturn(EngineResult.ok);
    when(repository.stopEngine).thenReturn(EngineResult.ok);
    when(repository.measureLatency).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(() => repository.setRecordOffset(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => stateController.close());

  AudioSetupCubit buildCubit() =>
      AudioSetupCubit(repository: repository, settings: settings);

  test('initial state has sensible defaults', () {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    expect(cubit.state.sampleRate, 48000);
    expect(cubit.state.bufferFrames, 128);
    expect(cubit.state.monitorInput, isTrue);
    expect(cubit.state.mergeToMono, isTrue);
    expect(cubit.state.status, AudioSetupStatus.stopped);
  });

  test('hydrates from the repository when the engine is already running', () {
    when(() => repository.state).thenReturn(
      const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 96000,
          bufferFrames: 256,
          isConnected: true,
        ),
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 96000,
        bufferFrames: 256,
      ),
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);

    expect(cubit.state.status, AudioSetupStatus.running);
    expect(cubit.state.sampleRate, 96000);
    expect(cubit.state.bufferFrames, 256);
    expect(cubit.state.monitorInput, isFalse);
    expect(cubit.state.mergeToMono, isFalse);
    expect(cubit.state.engineStatus.deviceName, 'Scarlett');
  });

  blocTest<AudioSetupCubit, AudioSetupState>(
    'option setters update the requested config',
    build: buildCubit,
    act: (cubit) => cubit
      ..setSampleRate(96000)
      ..setBufferFrames(64)
      ..setMonitorInput(monitorInput: false)
      ..setMergeToMono(mergeToMono: false),
    expect: () => [
      isA<AudioSetupState>().having((s) => s.sampleRate, 'sampleRate', 96000),
      isA<AudioSetupState>().having((s) => s.bufferFrames, 'bufferFrames', 64),
      isA<AudioSetupState>().having(
        (s) => s.monitorInput,
        'monitorInput',
        false,
      ),
      isA<AudioSetupState>().having((s) => s.mergeToMono, 'mergeToMono', false),
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
          passthrough: true,
          mergeToMono: true,
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

  group('loopback auto-measure', () {
    const routable = LoopbackInfo(
      available: true,
      kind: LoopbackKind.virtualDevice,
      deviceName: 'BlackHole 2ch',
    );

    test('detects a loopback on construction and exposes it', () {
      when(repository.detectLoopback).thenReturn(routable);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.loopback, routable);
    });

    blocTest<AudioSetupCubit, AudioSetupState>(
      'start enables loopback capture and auto-measures latency',
      build: () {
        when(repository.detectLoopback).thenReturn(routable);
        return buildCubit();
      },
      act: (cubit) => cubit.start(),
      verify: (_) {
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 128,
              passthrough: true,
              mergeToMono: true,
              useLoopbackCapture: true,
            ),
          ),
        ).called(1);
        verify(repository.measureLatency).called(1);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'start does not auto-measure when no loopback is detected',
      build: buildCubit,
      act: (cubit) => cubit.start(),
      verify: (_) => verifyNever(repository.measureLatency),
    );
  });

  group('latency persistence', () {
    const connected = LooperState(
      status: EngineStatus(
        deviceName: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        isConnected: true,
      ),
    );

    test('applies a saved offset when a device connects', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        frames: 512,
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(() => repository.setRecordOffset(512)).called(1);
    });

    test('persists a freshly measured offset', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 128,
            isConnected: true,
            recordOffsetFrames: 640,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        await settings.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
        ),
        640,
      );
    });
  });
}
