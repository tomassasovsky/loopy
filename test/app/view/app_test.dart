import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
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
  void pushWaveform(Float32List samples) => pushCalls++;
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
      await tester.pump();
    }

    testWidgets('renders the looper as the home page', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byType(LooperPage), findsOneWidget);
    });

    testWidgets('opens the waveform window when entering big picture, and '
        'closes it on exit', (tester) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      await tester.tap(find.byKey(const Key('looper_bigPicture_button')));
      await tester.pump();
      expect(windowService.openCalls, 1);
      expect(windowService.isOpen, isTrue);
      expect(find.byType(BigPictureView), findsOneWidget);

      await tester.tap(find.byKey(const Key('bigpicture_exit_button')));
      await tester.pump();
      expect(windowService.closeCalls, greaterThanOrEqualTo(1));
      expect(windowService.isOpen, isFalse);
    });
  });
}
