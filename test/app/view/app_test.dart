import 'dart:async';
import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy_engine/loopy_engine.dart' show EngineSnapshot;
import 'package:loopy_engine/loopy_engine.dart'
    as le
    show AudioDevice, LatencyState;
import 'package:midi_client/midi_client.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockMidiSource extends Mock implements MidiControllerSource {}

class _RecordingWindowService implements WaveformWindowService {
  _RecordingWindowService({this.openResult = true});

  /// What [open] reports — `false` simulates a window that never readies.
  final bool openResult;

  int openCalls = 0;
  int closeCalls = 0;
  int pushCalls = 0;
  bool _open = false;

  @override
  bool get isOpen => _open;

  @override
  Future<bool> open({String title = 'Loopy — Output'}) async {
    openCalls++;
    _open = openResult;
    return openResult;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _open = false;
  }

  @override
  void pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) => pushCalls++;
}

void main() {
  group('App', () {
    late LooperRepository repository;
    late ControllerRepository controllerRepository;
    late MidiDeviceRepository midiDeviceRepository;
    late SettingsRepository settings;
    late SessionRepository sessionRepository;

    setUp(() {
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      controllerRepository = ControllerRepository(sources: const []);
      settings = SettingsRepository(store: FakeKeyValueStore());
      sessionRepository = SessionRepository(engine: FakeAudioEngine());
      // No MIDI backend by default; the MIDI-specific test below wires its own.
      midiDeviceRepository = MidiDeviceRepository(
        source: null,
        settings: settings,
      );
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);
      addTearDown(midiDeviceRepository.dispose);
    });

    Future<void> pumpApp(
      WidgetTester tester,
      WaveformWindowService windowService,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: windowService,
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders the looper as the home page in tracks', (
      tester,
    ) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byType(LooperPage), findsOneWidget);
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('always lands on the looper — no first-run gate', (
      tester,
    ) async {
      // The wizard and the needsSetup gate are gone; the app renders the looper
      // directly even with no saved audio config.
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LooperPage), findsOneWidget);
    });

    testWidgets('opens the waveform window on launch in tracks', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, greaterThanOrEqualTo(1));
      expect(windowService.isOpen, isTrue);
      // A successful open shows no failure banner.
      expect(
        find.byKey(const Key('app_waveformWindowFailed_banner')),
        findsNothing,
      );
    });

    testWidgets('does not open the waveform window when it is disabled', (
      tester,
    ) async {
      await settings.saveShowWaveformWindow(value: false);
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, 0);
      expect(windowService.isOpen, isFalse);
    });

    testWidgets('right-click opens settings; disabling the waveform window '
        'closes it', (tester) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);
      expect(windowService.isOpen, isTrue);

      await tester.tap(
        find.byKey(const Key('tracks_settings_secondaryTap')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Disable the secondary waveform window; it closes (Tracks is the
      // only mode now, so the window follows this enable toggle alone).
      await tester.tap(
        find.byKey(const Key('settings_waveformWindow_switch')),
      );
      await tester.pumpAndSettle();

      expect(windowService.isOpen, isFalse);

      // Close the settings page so the global open-guard resets for the next
      // test (the toggle no longer navigates away on its own).
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();

      // The layout never swaps — Tracks is the only mode.
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('the S key opens the settings page', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Close it so the global open-guard resets for the next test.
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
    });

    testWidgets('shows a disconnect banner for a lost pinned device, then '
        'clears it on reconnect', (tester) async {
      EngineSnapshot snap({required bool devicePresent}) => EngineSnapshot(
        isRunning: true,
        devicePresent: devicePresent,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
      );

      final engine = FakeAudioEngine();
      final ticker = StreamController<void>.broadcast();
      final reconnectTicker = StreamController<void>.broadcast();
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        reconnectTicker: reconnectTicker.stream,
      );
      addTearDown(repo.dispose);
      addTearDown(ticker.close);
      addTearDown(reconnectTicker.close);

      // Pin a device so the supervisor + banner treat it as recoverable.
      engine
        ..devices = const [
          le.AudioDevice(
            id: 'out-1',
            name: 'Scarlett 2i2',
            isDefault: false,
            isInput: false,
          ),
        ]
        ..nextSnapshot = snap(devicePresent: true);
      repo.startEngine(const EngineConfig(playbackDeviceId: 'out-1'));

      await tester.pumpWidget(
        App(
          repository: repo,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();

      // Establish the present baseline, then lose the device.
      ticker.add(null);
      await tester.pumpAndSettle();
      engine.nextSnapshot = snap(devicePresent: false);
      ticker.add(null);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_deviceLost_banner')), findsOneWidget);

      // The device returns: the banner clears.
      engine.nextSnapshot = snap(devicePresent: true);
      ticker.add(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_deviceLost_banner')), findsNothing);

      // Flush the transient "reconnected" snackbar timer.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('shows a MIDI disconnect banner when the pinned controller is '
        'unplugged, then clears it on replug', (tester) async {
      const pedal = MidiDevice(id: 'm1', name: 'FCB1010');
      var enumerated = const <MidiDevice>[pedal];
      final source = _MockMidiSource();
      when(source.enumerate).thenAnswer((_) => enumerated);
      when(() => source.open(any())).thenReturn(0);
      when(source.close).thenReturn(0);
      when(() => source.activity).thenAnswer((_) => const Stream.empty());

      // Pin the pedal so the launch hydrate connects it.
      await settings.saveMidiDevice(id: 'm1', name: 'FCB1010');

      // Wire a repository over the real mock source. The hotplug timer is
      // disabled so the poll is driven deterministically via [refresh].
      final midiRepo = MidiDeviceRepository(
        source: source,
        settings: settings,
        pollInterval: Duration.zero,
      );
      addTearDown(midiRepo.dispose);

      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiRepo,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();

      // Unplug: the hotplug poll marks it gone and banners it.
      enumerated = const [];
      midiRepo.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_midiLost_banner')), findsOneWidget);

      // Replug: the banner clears and a transient snackbar shows.
      enumerated = const [pedal];
      midiRepo.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_midiLost_banner')), findsNothing);
      expect(
        find.byKey(const Key('app_midiRestored_snackbar')),
        findsOneWidget,
      );

      // Flush the transient "reconnected" snackbar timer.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('shows a banner when the waveform window fails to open', (
      tester,
    ) async {
      final windowService = _RecordingWindowService(openResult: false);
      await pumpApp(tester, windowService);

      expect(
        find.byKey(const Key('app_waveformWindowFailed_banner')),
        findsOneWidget,
      );
      // No frames are streamed to a window that never readied.
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.pushCalls, 0);
    });

    testWidgets('shows a single-display notice and skips the waveform window '
        'when only one display is present', (tester) async {
      final windowService = _RecordingWindowService();
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: windowService,
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
          displayCount: () => 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_singleDisplay_banner')), findsOneWidget);
      expect(windowService.openCalls, 0);
      // The push timer never started either.
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.pushCalls, 0);
    });

    testWidgets('shows the audio-recovery banner when booted with the pinned '
        'device absent', (tester) async {
      // The fake engine reports stopped with no devices, so the pinned config
      // is absent and the recovery cubit waits (and would auto-start on
      // arrival). pump (not pumpAndSettle) — the cubit holds a periodic poll.
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          exportDirectory: () async => '.',
          audioRecoveryConfig: const EngineConfig(playbackDeviceId: 'absent'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.byKey(const Key('app_audioRecovery_banner')), findsOneWidget);
    });
  });
}
