import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/view/audio_tray_panel.dart';
import 'package:segno/audio_setup/view/device_audio_tab.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
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
  late InputsCubit inputs;
  late LooperBloc looper;
  late QuantizeCubit quantize;
  late RecordOptionsCubit record;

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
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.allLaneChains()).thenReturn(const {});
    when(() => repository.allTrackChains()).thenReturn(const {});
    cubit = AudioSetupCubit(
      repository: repository,
      settings: settings,
      deviceRefreshInterval: const Duration(days: 1),
    );
    inputs = InputsCubit(settings: settings);
    looper = LooperBloc(repository: repository);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    record = RecordOptionsCubit(repository: repository, settings: settings);
  });

  tearDown(() async {
    await cubit.close();
    await inputs.close();
    await looper.close();
    await quantize.close();
    await record.close();
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
        home: MultiBlocProvider(
          providers: [
            BlocProvider<AudioSetupCubit>.value(value: cubit),
            BlocProvider<InputsCubit>.value(value: inputs),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<RecordOptionsCubit>.value(value: record),
          ],
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

  group('Device tab', () {
    testWidgets('opens the device list, one row at a time', (tester) async {
      // The host lists the two directions separately; one interface is both.
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'scarlett-out',
          name: 'Scarlett 18i20',
          isDefault: true,
          isInput: false,
          outputChannels: 20,
        ),
        AudioDevice(
          id: 'scarlett-in',
          name: 'Scarlett 18i20',
          isDefault: true,
          isInput: true,
          inputChannels: 18,
        ),
        AudioDevice(
          id: 'builtin-out',
          name: 'Built-in audio',
          isDefault: false,
          isInput: false,
          outputChannels: 2,
        ),
        AudioDevice(
          id: 'builtin-in',
          name: 'Built-in audio',
          isDefault: false,
          isInput: true,
          inputChannels: 2,
        ),
      ]);
      cubit.refreshDevices();
      engineReports(const EngineStatus(deviceName: 'Scarlett 18i20'));
      await pump(tester, AudioTab.device);
      await tester.pump();

      // Closed: the list is not in the tree yet.
      expect(find.text('18 in · 20 out'), findsNothing);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();
      // Paired by name across the two lists: one row, both directions.
      expect(find.text('18 in · 20 out'), findsOneWidget);
      expect(find.text('2 in · 2 out'), findsOneWidget);

      // Opening the rate row closes the device list.
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();
      expect(find.text('18 in · 20 out'), findsNothing);
      expect(find.byKey(const Key('audio_buffer_128')), findsOneWidget);
    });

    testWidgets('a device with unknown counts says nothing, not zero', (
      tester,
    ) async {
      // What every miniaudio host used to report, and what a host that cannot
      // answer still reports: unknown, which is not a count of zero.
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'mystery',
          name: 'Mystery box',
          isDefault: true,
          isInput: false,
        ),
      ]);
      cubit.refreshDevices();
      await pump(tester, AudioTab.device);
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();

      // Named on the closed row and in the open list; no invented counts.
      expect(find.text('Mystery box'), findsNWidgets(2));
      expect(find.text('0 in · 0 out'), findsNothing);
    });

    testWidgets('every buffer carries what it costs, not just the chosen one', (
      tester,
    ) async {
      engineReports(const EngineStatus(sampleRate: 48000, bufferFrames: 128));
      await pump(tester, AudioTab.device);
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();

      // Two buffer periods at 48k: 64 -> 2.7 ms, 128 -> 5.3 ms.
      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('audio_buffer_64')),
      );
      expect(row.value, '2.7 ms');
      expect(estimatedRoundTripMs(128, 48000), closeTo(5.33, 0.01));
    });

    testWidgets('picking a rate and a buffer reaches the engine', (
      tester,
    ) async {
      engineReports(const EngineStatus(sampleRate: 48000, bufferFrames: 128));
      await pump(tester, AudioTab.device);
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_buffer_256')));
      await tester.pump();

      expect(cubit.state.bufferFrames, 256);
    });

    testWidgets('inputs are listed by the name they were given', (
      tester,
    ) async {
      await inputs.rename(1, 'mic');
      engineReports(const EngineStatus(inputChannels: 2));
      await pump(tester, AudioTab.device);
      await tester.pump();

      // The row summarises how many are named.
      expect(find.text('1 named'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();

      expect(find.text('mic'), findsOneWidget);
      expect(find.text('input 2'), findsOneWidget);
      // The unnamed one keeps its ordinal as its name.
      expect(find.text('In 1'), findsOneWidget);
    });

    testWidgets('renaming an input through the sheet persists it', (
      tester,
    ) async {
      engineReports(const EngineStatus(inputChannels: 2));
      await pump(tester, AudioTab.device);
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(InkWell, 'd').first);
      await tester.tap(find.widgetWithText(InkWell, 'i').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(inputs.state.nameOf(0), 'di');
    });

    testWidgets('clearing the name hands the socket back its ordinal', (
      tester,
    ) async {
      await inputs.rename(0, 'guitar');
      engineReports(const EngineStatus(inputChannels: 2));
      await pump(tester, AudioTab.device);
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_input_0')));
      await tester.pumpAndSettle();
      // The sheet has no Clear button — it has a backspace, and Save takes an
      // empty field for an input.
      for (var i = 0; i < 'guitar'.length; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined).first);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(inputs.state.nameOf(0), isEmpty);
      expect(find.text('In 1'), findsOneWidget);
    });

    testWidgets('silence with every output off is called out', (tester) async {
      const silent = LooperState(
        outputEnabledMask: 0,
        status: EngineStatus(outputChannels: 2),
      );
      when(() => repository.state).thenReturn(silent);
      states.add(silent);
      // Let the bloc's own subscription turn the stream event into state
      // before anything is pumped.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pump(tester, AudioTab.device);
      // The bloc turns the stream event into an event of its own, so the
      // widget sees it a frame later.
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audio_no_outputs')), findsOneWidget);
    });
  });

  group('Recording tab', () {
    testWidgets('the max-loop cap opens in place and applies', (tester) async {
      await pump(tester, AudioTab.recording);
      await tester.pump();

      expect(find.byKey(const Key('audio_maxloop_2')), findsNothing);
      await tester.tap(find.byKey(const Key('audio_maxloop_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_maxloop_2')));
      await tester.pump();

      expect(cubit.state.maxLoopMinutes, 2);
    });

    testWidgets('the three switches drive their own settings', (tester) async {
      await pump(tester, AudioTab.recording);
      await tester.pump();

      await tester.tap(find.byKey(const Key('audio_quantize_switch')));
      await tester.tap(find.byKey(const Key('audio_recdub_switch')));
      await tester.tap(find.byKey(const Key('audio_autorecord_switch')));
      await tester.pumpAndSettle();

      expect(quantize.state, isTrue);
      expect(record.state.recDub, isTrue);
      expect(record.state.autoRecord, isTrue);
    });

    testWidgets('the default length picks through the chip dialog', (
      tester,
    ) async {
      await pump(tester, AudioTab.recording);
      await tester.pump();

      await tester.tap(find.byKey(const Key('audio_defaultlength_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_chip_×2')));
      await tester.pumpAndSettle();

      expect(record.state.defaultMultiple, 2);
    });
  });
}
