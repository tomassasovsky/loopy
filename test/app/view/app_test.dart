import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _RecordingWindowService implements WaveformWindowService {
  int openCalls = 0;
  int closeCalls = 0;
  int pushCalls = 0;
  bool _open = false;

  @override
  bool get isOpen => _open;

  @override
  Future<void> open() async {
    openCalls++;
    _open = true;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _open = false;
  }

  @override
  void pushWaveform(Float32List samples, double progress) => pushCalls++;
}

void main() {
  group('App', () {
    late LooperRepository repository;
    late ControllerRepository controllerRepository;
    late SettingsRepository settings;

    setUp(() {
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      controllerRepository = ControllerRepository(sources: const []);
      settings = SettingsRepository(store: FakeKeyValueStore());
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);
    });

    Future<void> pumpApp(
      WidgetTester tester,
      WaveformWindowService windowService,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          settings: settings,
          waveformWindow: windowService,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders the looper as the home page in big picture', (
      tester,
    ) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byType(LooperPage), findsOneWidget);
      expect(find.byType(BigPictureView), findsOneWidget);
    });

    testWidgets('first run shows the audio setup start screen', (tester) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          needsSetup: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AudioSetupView), findsOneWidget);
      expect(find.byType(LooperPage), findsNothing);
    });

    testWidgets('opens the waveform window on launch in big picture', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, greaterThanOrEqualTo(1));
      expect(windowService.isOpen, isTrue);
    });

    testWidgets('right-click opens settings; switching to desktop closes the '
        'window', (tester) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);
      expect(windowService.isOpen, isTrue);

      await tester.tap(
        find.byKey(const Key('bigpicture_settings_secondaryTap')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BigPictureSettingsPage), findsOneWidget);

      // Turn Big Picture off -> desktop layout; the waveform window closes.
      await tester.tap(find.byKey(const Key('bpSettings_bigPicture_switch')));
      await tester.pumpAndSettle();

      expect(find.byType(LooperView), findsOneWidget);
      expect(windowService.isOpen, isFalse);
    });

    testWidgets('the S key opens the settings page', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.byType(BigPictureSettingsPage), findsOneWidget);

      // Close it so the global open-guard resets for the next test.
      await tester.tap(find.byKey(const Key('bpSettings_close_button')));
      await tester.pumpAndSettle();
      expect(find.byType(BigPictureSettingsPage), findsNothing);
    });
  });
}
