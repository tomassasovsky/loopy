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
    when(repository.devices).thenReturn(const []);
    when(repository.asioDrivers).thenReturn(const []);
  });

  tearDown(() => stateController.close());

  AudioSetupCubit buildCubit({
    bool defaultExclusive = false,
    bool asioSelectable = false,
  }) => AudioSetupCubit(
    repository: repository,
    settings: settings,
    defaultExclusive: defaultExclusive,
    asioSelectable: asioSelectable,
  );

  const mockAsioDriver = AudioDevice(
    id: 'Focusrite USB ASIO',
    name: 'Focusrite USB ASIO',
    isDefault: false,
    isInput: false,
    inputChannels: 18,
    outputChannels: 20,
  );

  test('initial state has sensible defaults', () {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    expect(cubit.state.sampleRate, 48000);
    expect(cubit.state.bufferFrames, 128);
    expect(cubit.state.monitorInput, isTrue);
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
    expect(cubit.state.engineStatus.deviceName, 'Scarlett');
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

  void seedRunning() {
    when(() => repository.state).thenReturn(
      const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
        ),
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        passthrough: true,
      ),
    );
  }

  blocTest<AudioSetupCubit, AudioSetupState>(
    'setMonitorInput while running reopens the device and persists it',
    setUp: seedRunning,
    build: buildCubit,
    act: (cubit) => cubit.setMonitorInput(monitorInput: false),
    expect: () => [
      isA<AudioSetupState>().having(
        (s) => s.monitorInput,
        'monitorInput',
        false,
      ),
    ],
    verify: (_) async {
      verify(repository.stopEngine).called(1);
      verify(
        () => repository.startEngine(
          const EngineConfig(
            sampleRate: 48000,
            bufferFrames: 128,
          ),
        ),
      ).called(1);
      expect((await settings.loadAudioConfig())?.monitorInput, isFalse);
    },
  );

  group('exclusive mode', () {
    test('defaults to the injected platform default (on) when unset', () {
      final cubit = buildCubit(defaultExclusive: true);
      addTearDown(cubit.close);
      expect(cubit.state.exclusive, isTrue);
    });

    test('defaults to the injected platform default (off) when unset', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.exclusive, isFalse);
    });

    test('hydrates the persisted intent over the platform default', () {
      when(() => repository.lastEngineConfig).thenReturn(
        // Saved intent (exclusive off) must win over the injected on-default.
        const EngineConfig(sampleRate: 48000, bufferFrames: 128),
      );
      final cubit = buildCubit(defaultExclusive: true);
      addTearDown(cubit.close);
      expect(cubit.state.exclusive, isFalse);
    });

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setExclusive while running reopens with exclusive and persists it',
      setUp: seedRunning,
      build: buildCubit,
      act: (cubit) => cubit.setExclusive(exclusive: true),
      expect: () => [
        isA<AudioSetupState>().having((s) => s.exclusive, 'exclusive', true),
      ],
      verify: (_) async {
        verify(repository.stopEngine).called(1);
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 128,
              passthrough: true,
              exclusive: true,
            ),
          ),
        ).called(1);
        expect((await settings.loadAudioConfig())?.exclusive, isTrue);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setExclusive with the unchanged value is a no-op (no reopen)',
      // Host default is non-Windows in tests, so initial exclusive is false.
      build: buildCubit,
      act: (cubit) => cubit.setExclusive(exclusive: false),
      expect: () => const <AudioSetupState>[],
      verify: (_) => verifyNever(repository.stopEngine),
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'start carries the exclusive intent through to the engine',
      build: () => buildCubit(defaultExclusive: true),
      act: (cubit) => cubit.start(),
      verify: (_) => verify(
        () => repository.startEngine(
          const EngineConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            passthrough: true,
            exclusive: true,
          ),
        ),
      ).called(1),
    );
  });

  blocTest<AudioSetupCubit, AudioSetupState>(
    'start uses the selected max loop length (minutes -> frames)',
    build: buildCubit,
    act: (cubit) => cubit
      ..setMaxLoopMinutes(5)
      ..start(),
    expect: () => [
      isA<AudioSetupState>().having(
        (s) => s.maxLoopMinutes,
        'maxLoopMinutes',
        5,
      ),
      isA<AudioSetupState>().having(
        (s) => s.status,
        'status',
        AudioSetupStatus.running,
      ),
    ],
    verify: (_) async {
      // 5 min * 60 s * 48000 Hz = 14_400_000 frames.
      verify(
        () => repository.startEngine(
          const EngineConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            passthrough: true,
            maxLoopFrames: 14400000,
          ),
        ),
      ).called(1);
      expect((await settings.loadAudioConfig())?.maxLoopMinutes, 5);
    },
  );

  test('hydrates maxLoopMinutes from the last engine config (frames)', () {
    when(() => repository.state).thenReturn(
      const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
        ),
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        maxLoopFrames: 14400000, // 5 minutes at 48 kHz
      ),
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);

    expect(cubit.state.maxLoopMinutes, 5);
  });

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
          .having((s) => s.error, 'error', AudioSetupError.startAudioFailed)
          .having((s) => s.errorDetail, 'errorDetail', isNotNull),
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
    'setRecordOffset forwards a manual offset to the repository',
    build: buildCubit,
    act: (cubit) => cubit.setRecordOffset(257),
    verify: (_) => verify(() => repository.setRecordOffset(257)).called(1),
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'setRecordOffset clamps a negative offset to zero',
    build: buildCubit,
    act: (cubit) => cubit.setRecordOffset(-5),
    verify: (_) => verify(() => repository.setRecordOffset(0)).called(1),
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
              useLoopbackCapture: true,
            ),
          ),
        ).called(1);
        verify(repository.measureLatency).called(1);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'an explicit capture device wins over loopback auto-routing',
      build: () {
        when(repository.detectLoopback).thenReturn(routable);
        return buildCubit();
      },
      // The host advertises a routable loopback (as every PipeWire output
      // does), but the user pinned a real input device: capture must open on
      // it, not on the loopback, and the loopback auto-measure must be skipped.
      act: (cubit) => cubit
        ..setCaptureDevice('in-1')
        ..start(),
      verify: (_) {
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 128,
              passthrough: true,
              captureDeviceId: 'in-1',
            ),
          ),
        ).called(1);
        verifyNever(repository.measureLatency);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'an explicit capture device still auto-measures via loopback channels',
      build: () {
        when(repository.detectLoopback).thenReturn(routable);
        // The pinned interface itself reports dedicated loopback channels, so a
        // measurement is still meaningful even though capture is not the
        // monitor source.
        when(() => repository.state).thenReturn(
          const LooperState(
            status: EngineStatus(isConnected: true, excludedInputMask: 0x30),
          ),
        );
        return buildCubit();
      },
      act: (cubit) => cubit
        ..setCaptureDevice('in-1')
        ..start(),
      verify: (_) => verify(repository.measureLatency).called(1),
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'start does not auto-measure when no loopback is detected',
      build: buildCubit,
      act: (cubit) => cubit.start(),
      verify: (_) => verifyNever(repository.measureLatency),
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'start auto-measures when the device exposes loopback channels',
      build: () {
        // No routable loopback device, but the opened interface reports
        // dedicated loopback channels (e.g. a Scarlett's "Loop 1/2").
        when(() => repository.state).thenReturn(
          const LooperState(
            status: EngineStatus(isConnected: true, excludedInputMask: 0x30),
          ),
        );
        return buildCubit();
      },
      act: (cubit) => cubit.start(),
      verify: (_) => verify(repository.measureLatency).called(1),
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

  group('device selection', () {
    test('hydrates devices and selected ids from the repository', () {
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett',
          isDefault: true,
          isInput: false,
        ),
        AudioDevice(
          id: 'in-1',
          name: 'Built-in Mic',
          isDefault: true,
          isInput: true,
        ),
      ]);
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1', captureDeviceId: 'in-1'),
      );

      final cubit = buildCubit();
      addTearDown(cubit.close);

      expect(cubit.state.devices, hasLength(2));
      expect(cubit.state.playbackDevices, hasLength(1));
      expect(cubit.state.captureDevices, hasLength(1));
      expect(cubit.state.playbackDeviceId, 'out-1');
      expect(cubit.state.captureDeviceId, 'in-1');
    });

    test('setPlaybackDevice updates state and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setPlaybackDevice('out-1');
      expect(cubit.state.playbackDeviceId, 'out-1');
      await Future<void>.delayed(Duration.zero);
      expect((await settings.loadAudioConfig())?.playbackDeviceId, 'out-1');
    });

    test('setCaptureDevice updates state and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setCaptureDevice('in-1');
      expect(cubit.state.captureDeviceId, 'in-1');
      await Future<void>.delayed(Duration.zero);
      expect((await settings.loadAudioConfig())?.captureDeviceId, 'in-1');
    });

    test('selecting a device while running reopens the engine on it', () {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'X', isConnected: true),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.running);

      cubit.setPlaybackDevice('out-1');

      verify(repository.stopEngine).called(1);
      final captured =
          verify(() => repository.startEngine(captureAny())).captured.single
              as EngineConfig;
      expect(captured.playbackDeviceId, 'out-1');
    });

    test('a failed reopen while running surfaces an error', () {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'X', isConnected: true),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.running);

      when(() => repository.startEngine(any())).thenReturn(EngineResult.device);
      cubit.setPlaybackDevice('out-1');

      expect(cubit.state.status, AudioSetupStatus.error);
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.errorDetail, isNotNull);
    });
  });

  group('device connectivity', () {
    LooperState present({
      required bool devicePresent,
      String name = 'Scarlett',
    }) => LooperState(
      status: EngineStatus(
        deviceName: name,
        isConnected: true,
        devicePresent: devicePresent,
      ),
    );

    test('raises lost then restored for a pinned device', () async {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1'),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);

      // Device lost (name now empty, but the last-seen name is remembered).
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
      expect(cubit.state.connectivityDeviceName, 'Scarlett');

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.restored);
    });

    test('never raises an event for the system default', () async {
      final cubit = buildCubit(); // no pinned device
      addTearDown(cubit.close);

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      stateController.add(present(devicePresent: false));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });
  });

  group('asio backend', () {
    test('loads drivers only when selectable', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);

      // Not selectable (non-Windows): drivers are never enumerated.
      final hidden = buildCubit();
      addTearDown(hidden.close);
      expect(hidden.state.asioDrivers, isEmpty);
      verifyNever(repository.asioDrivers);

      // Selectable: the driver list populates so the selector can show.
      final shown = buildCubit(asioSelectable: true);
      addTearDown(shown.close);
      expect(shown.state.asioDrivers, [mockAsioDriver]);
    });

    test('does not re-probe while the active backend is ASIO (R1)', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Focusrite USB ASIO',
            isConnected: true,
            activeBackend: AudioBackend.asio,
          ),
        ),
      );

      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);

      // The ASIO host SDK loads one global driver; probing while it runs would
      // tear down the live stream, so enumeration is skipped entirely.
      verifyNever(repository.asioDrivers);
      expect(cubit.state.asioDrivers, isEmpty);
    });

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setBackend(asio) defaults the driver to the first enumerated one',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setBackend(AudioBackend.asio),
      expect: () => [
        isA<AudioSetupState>()
            .having((s) => s.backend, 'backend', AudioBackend.asio)
            .having((s) => s.asioDriver, 'asioDriver', 'Focusrite USB ASIO'),
      ],
      verify: (_) async {
        final stored = await settings.loadAudioConfig();
        expect(stored?.backend, AudioBackend.asio);
        expect(stored?.asioDriver, 'Focusrite USB ASIO');
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setBackend(asio) while running reopens on ASIO without WASAPI loopback',
      setUp: () {
        when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
        // An auto-routable loopback (so without the ASIO guard the reopen would
        // set useLoopbackCapture) proves E8 forces it off under ASIO.
        when(repository.detectLoopback).thenReturn(
          const LoopbackInfo(
            available: true,
            kind: LoopbackKind.monitor,
            deviceName: 'Monitor of Output',
          ),
        );
        seedRunning();
      },
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setBackend(AudioBackend.asio),
      verify: (_) async {
        verify(repository.stopEngine).called(1);
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 128,
              passthrough: true,
              backend: AudioBackend.asio,
              asioDriver: 'Focusrite USB ASIO',
            ),
          ),
        ).called(1);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setBackend with the unchanged value is a no-op (no emit)',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setBackend(AudioBackend.wasapi),
      expect: () => const <AudioSetupState>[],
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setAsioDriver with the unchanged value is a no-op (no emit)',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setAsioDriver(''),
      expect: () => const <AudioSetupState>[],
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setAsioDriver persists the selection',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit
        ..setBackend(AudioBackend.asio)
        ..setAsioDriver('Another ASIO'),
      verify: (_) async {
        expect((await settings.loadAudioConfig())?.asioDriver, 'Another ASIO');
      },
    );

    test('hydrates the persisted backend + driver intent', () {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
        ),
      );
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);
      expect(cubit.state.backend, AudioBackend.asio);
      expect(cubit.state.asioDriver, 'Focusrite USB ASIO');
      expect(cubit.state.isAsio, isTrue);
    });

    test('a lost ASIO driver raises the connectivity banner', () async {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          backend: AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
        ),
      );
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);

      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Focusrite USB ASIO',
            isConnected: true,
            devicePresent: true,
            activeBackend: AudioBackend.asio,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      stateController.add(
        const LooperState(
          status: EngineStatus(
            isConnected: true,
            activeBackend: AudioBackend.asio,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
    });
  });
}
