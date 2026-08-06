import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/view/audio_tray_panel.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const EngineConfig()));

  late LooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> states;
  late AudioSetupCubit cubit;

  setUp(() {
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lastEngineConfig).thenReturn(null);
    when(() => repository.startEngine(any())).thenReturn(EngineResult.ok);
    when(repository.stopEngine).thenReturn(EngineResult.ok);
    when(repository.measureLatency).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(() => repository.setRecordOffset(any())).thenReturn(EngineResult.ok);
    when(repository.devices).thenReturn(const []);
    when(repository.asioDrivers).thenReturn(const []);
    cubit = AudioSetupCubit(
      repository: repository,
      settings: settings,
      deviceRefreshInterval: const Duration(days: 1),
    );
  });

  tearDown(() async {
    await cubit.close();
    await states.close();
  });

  /// Pushes an engine status through the repository stream the cubit watches.
  void engineReports(EngineStatus status) {
    when(() => repository.state).thenReturn(LooperState(status: status));
    states.add(LooperState(status: status));
  }

  Future<void> pump(WidgetTester tester, AudioTab tab) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<AudioSetupCubit>.value(
          value: cubit,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(19),
              child: AudioTrayPanel(tab: tab, onTabChanged: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Status tab', () {
    testWidgets('reports what the engine is running', (tester) async {
      engineReports(
        const EngineStatus(
          deviceName: 'Scarlett 18i20',
          sampleRate: 48000,
          bufferFrames: 128,
          recordOffsetFrames: 64,
          latencyState: LatencyState.done,
          measuredLatencyMs: 6.8,
        ),
      );
      await pump(tester, AudioTab.status);
      await tester.pump();

      expect(find.text('Scarlett 18i20'), findsOneWidget);
      expect(find.text('48000 Hz'), findsOneWidget);
      expect(find.text('128 frames'), findsOneWidget);
      expect(find.text('64 frames'), findsOneWidget);
      expect(find.text('6.80 ms'), findsOneWidget);
    });

    testWidgets('a timed-out measurement says so, and warns', (tester) async {
      engineReports(
        const EngineStatus(latencyState: LatencyState.timeout),
      );
      await pump(tester, AudioTab.status);
      await tester.pump();

      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('audio_status_latency')),
      );
      expect(row.value, 'No signal detected');
      // Not a figure in the muted tone: it is why the offset may be wrong.
      expect(row.valueColor, SurfaceTheme.dark.warning);
    });

    testWidgets('measuring is announced and cannot be restarted', (
      tester,
    ) async {
      engineReports(const EngineStatus(latencyState: LatencyState.measuring));
      await pump(tester, AudioTab.status);
      await tester.pump();

      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('audio_status_measure')),
      );
      expect(row.title, 'Measuring…');
      expect(row.onTap, isNull);
    });

    testWidgets('the measure row re-runs the measurement', (tester) async {
      // Never measured: the row offers to.
      engineReports(const EngineStatus());
      await pump(tester, AudioTab.status);
      await tester.pump();

      await tester.tap(find.byKey(const Key('audio_status_measure')));
      await tester.pump();

      verify(repository.measureLatency).called(greaterThanOrEqualTo(1));
    });
  });
}
