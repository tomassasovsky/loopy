import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;
import 'package:settings_repository/settings_repository.dart'
    as persisted
    show AudioBackend;

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
    bool asioSelectable = false,
    List<AudioDevice> initialAsioDrivers = const [],
  }) => AudioSetupCubit(
    repository: repository,
    settings: settings,
    asioSelectable: asioSelectable,
    initialAsioDrivers: initialAsioDrivers,
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
    expect(cubit.state.engineStatus.deviceName, 'Scarlett');
  });

  blocTest<AudioSetupCubit, AudioSetupState>(
    'option setters update the requested config',
    build: buildCubit,
    act: (cubit) => cubit
      ..setSampleRate(96000)
      ..setBufferFrames(64),
    // Each setter also (re)starts the engine from the stopped default (D3), so
    // a `running` status lands between the two requested-config changes.
    expect: () => [
      isA<AudioSetupState>().having((s) => s.sampleRate, 'sampleRate', 96000),
      isA<AudioSetupState>().having(
        (s) => s.status,
        'status',
        AudioSetupStatus.running,
      ),
      isA<AudioSetupState>().having((s) => s.bufferFrames, 'bufferFrames', 64),
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
      ),
    );
  }

  blocTest<AudioSetupCubit, AudioSetupState>(
    'a setting change uses the selected max loop length (minutes -> frames)',
    build: buildCubit,
    act: (cubit) => cubit.setMaxLoopMinutes(5),
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
    'a setting change from stopped (re)starts the engine',
    build: buildCubit,
    act: (cubit) => cubit.setBufferFrames(64),
    expect: () => [
      isA<AudioSetupState>().having(
        (s) => s.bufferFrames,
        'bufferFrames',
        64,
      ),
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
          bufferFrames: 64,
        ),
      ),
    ).called(1),
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'a failed open surfaces an error',
    build: buildCubit,
    setUp: () => when(
      () => repository.startEngine(any()),
    ).thenReturn(EngineResult.device),
    act: (cubit) => cubit.setBufferFrames(64),
    expect: () => [
      isA<AudioSetupState>().having((s) => s.bufferFrames, 'bufferFrames', 64),
      isA<AudioSetupState>()
          .having((s) => s.status, 'status', AudioSetupStatus.error)
          .having((s) => s.error, 'error', AudioSetupError.openDeviceFailed)
          .having((s) => s.errorDetail, 'errorDetail', isNotNull),
    ],
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'a non-startable config (ASIO, no driver) persists but does not start',
    // Windows with no ASIO driver: the backend is ASIO but the config is
    // incomplete, so a setting change persists without booting audio.
    build: () => buildCubit(asioSelectable: true),
    act: (cubit) => cubit.setBufferFrames(64),
    verify: (_) async {
      verifyNever(() => repository.startEngine(any()));
      expect(
        (await settings.loadAudioConfig())?.backend,
        persisted.AudioBackend.asio,
      );
    },
  );

  blocTest<AudioSetupCubit, AudioSetupState>(
    'a setting change recovers from a failed open and clears the error',
    // The first open fails (error state), the next succeeds: the recovery path
    // (D3) starts the engine and must clear the stale error banner.
    build: buildCubit,
    setUp: () {
      var calls = 0;
      when(() => repository.startEngine(any())).thenAnswer((_) {
        calls++;
        return calls == 1 ? EngineResult.device : EngineResult.ok;
      });
    },
    act: (cubit) => cubit
      ..setBufferFrames(64)
      ..setBufferFrames(256),
    verify: (cubit) {
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.error, isNull);
      expect(cubit.state.errorDetail, isNull);
    },
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
      'a (re)start enables loopback capture and auto-measures latency',
      build: () {
        when(repository.detectLoopback).thenReturn(routable);
        return buildCubit();
      },
      act: (cubit) => cubit.setBufferFrames(64),
      verify: (_) {
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 64,
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
      // Pinning the device both changes the config and (re)starts the engine.
      act: (cubit) => cubit.setCaptureDevice('in-1'),
      verify: (_) {
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 128,
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
      act: (cubit) => cubit.setCaptureDevice('in-1'),
      verify: (_) => verify(repository.measureLatency).called(1),
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'a (re)start does not auto-measure when no loopback is detected',
      build: buildCubit,
      act: (cubit) => cubit.setBufferFrames(64),
      verify: (_) => verifyNever(repository.measureLatency),
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'a (re)start auto-measures when the device exposes loopback channels',
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
      act: (cubit) => cubit.setBufferFrames(64),
      verify: (_) => verify(repository.measureLatency).called(1),
    );
  });

  group('ASIO driver cache (D1)', () {
    test('exposes the injected drivers even while ASIO is live', () {
      // ASIO already holds the device: re-probing would tear the stream down
      // (R1), so the picker must fall back to the cached startup enumeration.
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(
            isConnected: true,
            activeBackend: AudioBackend.asio,
          ),
        ),
      );
      final cubit = buildCubit(
        asioSelectable: true,
        initialAsioDrivers: const [mockAsioDriver],
      );
      addTearDown(cubit.close);

      expect(cubit.state.asioDrivers, const [mockAsioDriver]);
      expect(cubit.state.cachedAsioDrivers, const [mockAsioDriver]);
      verifyNever(repository.asioDrivers);
    });

    test('probes drivers when ASIO is not the active backend', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);

      expect(cubit.state.asioDrivers, const [mockAsioDriver]);
      verify(repository.asioDrivers).called(1);
    });
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
      await pumpEventQueue();

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
      await pumpEventQueue();

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

    test('Windows construction defaults to ASIO and the first driver', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);
      // No backend choice on Windows: the backend is hardwired to ASIO and the
      // first enumerated driver is selected.
      expect(cubit.state.backend, AudioBackend.asio);
      expect(cubit.state.asioDriver, 'Focusrite USB ASIO');
      expect(cubit.state.asioOnly, isTrue);
    });

    test('Windows construction snaps rate/buffer into the driver set', () {
      when(repository.asioDrivers).thenReturn(const [
        // A driver locked to a single buffer size / sample rate (e.g. a USB
        // interface whose ASIO buffer is set in its own control panel).
        AudioDevice(
          id: 'Locked ASIO',
          name: 'Locked ASIO',
          isDefault: false,
          isInput: false,
          inputChannels: 2,
          outputChannels: 2,
          bufferSizes: [256],
          sampleRates: [96000],
        ),
      ]);
      // Defaults are 48000 / 128, neither offered by the driver.
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);
      expect(cubit.state.sampleRate, 96000);
      expect(cubit.state.bufferFrames, 256);
    });

    blocTest<AudioSetupCubit, AudioSetupState>(
      'a reopen on ASIO forces backend loopback off',
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
      act: (cubit) => cubit.setBufferFrames(64),
      verify: (_) async {
        verify(repository.stopEngine).called(1);
        verify(
          () => repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              bufferFrames: 64,
              backend: AudioBackend.asio,
              asioDriver: 'Focusrite USB ASIO',
            ),
          ),
        ).called(1);
      },
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setBackend is ignored on Windows (ASIO-only)',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setBackend(AudioBackend.miniaudio),
      expect: () => const <AudioSetupState>[],
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setAsioDriver with the current value is a no-op (no emit)',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setAsioDriver('Focusrite USB ASIO'),
      expect: () => const <AudioSetupState>[],
    );

    blocTest<AudioSetupCubit, AudioSetupState>(
      'setAsioDriver persists the selection',
      setUp: () =>
          when(repository.asioDrivers).thenReturn(const [mockAsioDriver]),
      build: () => buildCubit(asioSelectable: true),
      act: (cubit) => cubit.setAsioDriver('Another ASIO'),
      verify: (_) async {
        expect((await settings.loadAudioConfig())?.asioDriver, 'Another ASIO');
      },
    );

    test('hydrates the persisted ASIO driver when still enumerated', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
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

    test('coerces a stale saved backend=miniaudio to ASIO on Windows', () {
      when(repository.asioDrivers).thenReturn(const [mockAsioDriver]);
      // A config saved before the ASIO-only switch (or on a different OS).
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(sampleRate: 48000, bufferFrames: 128),
      );
      final cubit = buildCubit(asioSelectable: true);
      addTearDown(cubit.close);
      expect(cubit.state.backend, AudioBackend.asio);
      expect(cubit.state.asioDriver, 'Focusrite USB ASIO');
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

  group('AudioBackend bridge (domain <-> settings)', () {
    test('round-trips every value in both directions', () {
      for (final backend in AudioBackend.values) {
        expect(engineBackendOf(settingsBackendOf(backend)), backend);
      }
      for (final backend in persisted.AudioBackend.values) {
        expect(settingsBackendOf(engineBackendOf(backend)), backend);
      }
    });
  });
}
