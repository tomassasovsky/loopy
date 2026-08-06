import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/view/loop/loop_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late TempoCubit tempo;
  late RecordOptionsCubit record;
  late StreamController<LooperState> states;

  setUpAll(() {
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(LooperMode.multi);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    states = StreamController<LooperState>.broadcast();
    repository = _MockLooperRepository();
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setSyncTempo(on: any(named: 'on')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setQuantizeDiv(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () =>
          when(() => repository.setCountIn(any())).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
      ).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
    // ControlCubit (the Mode tab's default-mode row) talks to the same
    // repository; these are its reads, not the tempo face's.
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.allLaneChains()).thenReturn(const {});
    when(() => repository.allTrackChains()).thenReturn(const {});
    when(() => repository.trackEffects(any())).thenReturn(const []);
    when(() => repository.masterEffects).thenReturn(const []);
    when(() => repository.trackChainEnabled(any())).thenReturn(true);
    when(repository.masterChainEnvelope).thenReturn(const FxChainEnvelope());

    final settings = SettingsRepository(store: FakeKeyValueStore());
    tempo = TempoCubit(repository: repository, settings: settings);
    record = RecordOptionsCubit(repository: repository, settings: settings);
  });

  tearDown(() async {
    await tempo.close();
    await record.close();
    await states.close();
  });

  /// Puts the rig in a state and keeps [states] open so a test can push the
  /// engine's own answer back — a tapped tempo arrives that way, not from the
  /// widget that asked for it.
  void seed(TransportState transport) {
    final state = LooperState(
      tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
      transport: transport,
      status: const EngineStatus(outputChannels: 2),
    );
    when(() => bloc.state).thenReturn(state);
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
  }

  void engineReports(TransportState transport) {
    final state = LooperState(
      tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
      transport: transport,
      status: const EngineStatus(outputChannels: 2),
    );
    when(() => bloc.state).thenReturn(state);
    states.add(state);
  }

  Future<void> pump(WidgetTester tester, LoopTab tab) async {
    // The console face is drawn for 1920x1080; the default 800x600 surface
    // pushes rows below the fold where a tap lands on nothing.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final control = ControlCubit(
      looper: repository,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: SettingsRepository(store: FakeKeyValueStore()),
      performance: performance,
      keepAliveInterval: Duration.zero,
      mappingsWriteDebounce: Duration.zero,
    );
    addTearDown(() => unawaited(control.close()));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<TempoCubit>.value(value: tempo),
            BlocProvider<RecordOptionsCubit>.value(value: record),
            BlocProvider<ControlCubit>.value(value: control),
          ],
          child: Scaffold(
            body: LoopTrayPanel(tab: tab, onTabChanged: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Tempo tab', () {
    testWidgets('shows the live engine tempo, not the persisted intent', (
      tester,
    ) async {
      seed(
        const TransportState(tempoBpm: 128, tempoSource: TempoSource.tapped),
      );
      await pump(tester, LoopTab.tempo);

      expect(find.text('128.0 bpm'), findsOneWidget);
    });
  });

  group('Click tab', () {
    testWidgets('shows the click volume as a percentage', (tester) async {
      seed(const TransportState(clickVolume: 0.7));
      await pump(tester, LoopTab.click);

      expect(find.text('70%'), findsOneWidget);
    });

    testWidgets('fills the volume bar in proportion, over its full height', (
      tester,
    ) async {
      // Unity gain (the transport's default) sits halfway along a bar that
      // runs to the engine's +6 dB ceiling.
      seed(const TransportState());
      await pump(tester, LoopTab.click);

      final bar = tester.getSize(
        find.descendant(
          of: find.byKey(const Key('click_volume_bar')),
          matching: find.byType(LayoutBuilder),
        ),
      );
      final fill = tester.getSize(
        find.byKey(const Key('console_value_bar_fill')),
      );

      expect(fill.width, closeTo(bar.width / 2, 2));
      // The fill used to come out zero-height — full width, nothing to see.
      expect(fill.height, greaterThan(bar.height - 4));
    });

    testWidgets('drags map back onto the full gain range', (tester) async {
      seed(const TransportState(clickVolume: 0.4));
      await pump(tester, LoopTab.click);

      final bar = find.descendant(
        of: find.byKey(const Key('click_volume_bar')),
        matching: find.byType(LayoutBuilder),
      );
      final box = tester.getRect(bar);
      await tester.tapAt(Offset(box.right - 1, box.center.dy));
      await tester.pump();

      final gain =
          verify(() => repository.setClickVolume(captureAny())).captured.single
              as double;
      expect(gain, closeTo(kMaxClickGain, 0.02));
    });
  });

  group('Click volume double tap', () {
    testWidgets('snaps the click back to unity', (tester) async {
      seed(const TransportState(clickVolume: 0.2));
      await pump(tester, LoopTab.click);

      final box = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('click_volume_bar')),
          matching: find.byType(LayoutBuilder),
        ),
      );
      // Far from where unity lands, so the reset can't be confused with the
      // tap that precedes it.
      await tester.tapAt(Offset(box.left + 8, box.center.dy));
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(Offset(box.left + 8, box.center.dy));
      await tester.pump();

      final gains = verify(
        () => repository.setClickVolume(captureAny()),
      ).captured.cast<double>();
      expect(gains.last, 1);
    });
  });

  group('Tempo sheet', () {
    testWidgets('a tap shows what the engine made of it', (tester) async {
      seed(
        const TransportState(tempoBpm: 120),
      );
      await pump(tester, LoopTab.tempo);

      await tester.tap(find.byKey(const Key('loop_tempo_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tempo_sheet_field')), findsOneWidget);

      await tester.tap(find.widgetWithText(GestureDetector, 'Tap').last);
      await tester.pump();
      // Two taps make a tempo; the engine reports the result on its own
      // stream, which is the only feedback the pad has.
      engineReports(
        const TransportState(tempoBpm: 96, tempoSource: TempoSource.tapped),
      );
      await tester.pump();

      final field = tester.widget<Text>(
        find.byKey(const Key('tempo_sheet_field')),
      );
      expect(field.data, '96.0');
    });

    testWidgets('typing wins back the field from the taps', (tester) async {
      seed(
        const TransportState(tempoBpm: 120),
      );
      await pump(tester, LoopTab.tempo);
      await tester.tap(find.byKey(const Key('loop_tempo_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(GestureDetector, 'Tap').last);
      await tester.pump();
      engineReports(
        const TransportState(tempoBpm: 96, tempoSource: TempoSource.tapped),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(GestureDetector, '9').last);
      await tester.tap(find.widgetWithText(GestureDetector, '0').last);
      await tester.pump();

      final field = tester.widget<Text>(
        find.byKey(const Key('tempo_sheet_field')),
      );
      expect(field.data, '90');
    });
  });

  group('Mode tab', () {
    testWidgets('the mode picker says what each mode does', (tester) async {
      seed(const TransportState());
      await pump(tester, LoopTab.mode);

      await tester.tap(find.byKey(const Key('looper_mode_row')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_picker_Multi')), findsOneWidget);
      // Not just the five names: the blurb the face shows under the current
      // value rides along, for every option.
      expect(find.text('Same length tracks'), findsWidgets);
      expect(find.text('Locked to primary'), findsOneWidget);
      expect(find.text('Independent sections'), findsOneWidget);
      expect(find.text('Primary + sections'), findsOneWidget);
      expect(find.text('Un-synced tracks'), findsOneWidget);
    });
  });
}
