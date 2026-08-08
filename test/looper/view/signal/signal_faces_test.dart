import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/signal/signal_card.dart';
import 'package:segno/looper/view/signal/signal_cards.dart';
import 'package:segno/looper/view/signal/signal_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The rig the `SIGNAL / *` frames draw: three tracks with one take each, four
/// sockets, four outputs.
///
/// The fourth output is off, so the master face's gate list holds both states
/// rather than a column of identical switches.
const _rig = LooperState(
  tracks: [
    Track(lanes: [Lane(inputChannel: 0)]),
    Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
    Track(channel: 2, lanes: [Lane(inputChannel: 0)]),
  ],
  outputEnabledMask: 0x7,
  // The device name is load-bearing: `InputsCubit` keys a socket's name to
  // the OPEN INTERFACE, and refuses to store one against an empty device.
  status: EngineStatus(
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
);

/// A stopped engine: no tracks, no channels either way.
const _stopped = LooperState();

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late TracksCubit tracks;
  late InputsCubit inputs;
  late MonitorCubit monitor;
  late SettingsTrayCubit tray;

  setUpAll(() => registerFallbackValue(MonitorMode.off));

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(_rig);
    when(repository.allMonitors).thenReturn(const {});
    when(
      () => repository.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  /// Mounts the Signal face at [stage] with the providers the real tray
  /// inherits.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view folds a four-card run onto two lines.
  Future<void> pump(
    WidgetTester tester, {
    FxStage stage = FxStage.input,
    LooperState state = _rig,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: state,
    );

    settings = SettingsRepository(store: FakeKeyValueStore());
    tracks = TracksCubit(settings: settings);
    inputs = InputsCubit(settings: settings, repository: repository);
    monitor = MonitorCubit(repository: repository, settings: settings);
    tray = SettingsTrayCubit(settings: settings)..showSignalTab(stage);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(monitor.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: monitor),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: SignalTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(SignalTrayPanel)));

  // ------------------------------------------------------------ the seam

  group('the rail seam', () {
    test('Signal is a rail destination, first of the domains', () {
      // The mockups draw the signal path before the things that drive it, and
      // `home` stays ahead of all of them until the parent plan answers what
      // the home face is for.
      expect(
        SettingsTrayDestination.values.take(2),
        [SettingsTrayDestination.home, SettingsTrayDestination.signal],
      );
    });

    test('the stage tab IS FxStage — no parallel enum to drift', () {
      expect(
        FxStage.values,
        [FxStage.input, FxStage.loop, FxStage.track, FxStage.master],
      );
    });

    testWidgets('the domain names itself once, above the strip', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(find.byType(ConsoleDomainPanel<FxStage>), findsOneWidget);
      expect(find.text(l10n.traySignalLabel), findsOneWidget);
      expect(find.text(l10n.signalStageInput), findsOneWidget);
      expect(find.text(l10n.signalStageLoop), findsOneWidget);
      expect(find.text(l10n.signalStageTrack), findsOneWidget);
      expect(find.text(l10n.signalStageMaster), findsOneWidget);
    });

    testWidgets('picking a tab moves the stage and keeps the domain', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.signalStageMaster));
      await tester.pumpAndSettle();

      expect(tray.state.signalTab, FxStage.master);
      expect(tray.state.destination, SettingsTrayDestination.home);
    });
  });

  // --------------------------------------------- SIGNAL / signal-input

  group('SIGNAL / signal-input', () {
    testWidgets('one card per socket, named as the player named it', (
      tester,
    ) async {
      await pump(tester);
      await tester.pumpAndSettle();
      await inputs.rename(0, 'guitar');
      await tester.pump();
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_card_input_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_card_input_3')), findsOneWidget);
      // Four sockets reported, four cards — not the naming cubit's ceiling.
      expect(find.byKey(const Key('signal_card_input_4')), findsNothing);
      expect(find.text('guitar'), findsOneWidget);
      expect(find.text(l10n.signalCoordInput(1)), findsOneWidget);
    });

    testWidgets('the chip says the edit is PRINTED INTO THE TAKE', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalScopePrinted), findsOneWidget);
      expect(find.text(l10n.signalScopeMonitorOnly), findsNothing);
      expect(
        tester.widget<SignalScopeChip>(find.byType(SignalScopeChip)).printed,
        isTrue,
      );
    });

    testWidgets('an input card carries its monitor line, rack or no rack', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      // Every card here is rackless — racks are #535 — and the line is drawn
      // anyway, because whether you hear yourself is a fact about the jack.
      await monitor.setMode(0, MonitorMode.on);
      await monitor.setMode(1, MonitorMode.auto);
      await tester.pump();

      expect(find.text(l10n.signalNoRack), findsNWidgets(4));
      expect(find.text(l10n.signalMonitorOn), findsOneWidget);
      expect(find.text(l10n.signalMonitorAuto), findsOneWidget);
      // The two sockets never set read the model's default.
      expect(find.text(l10n.signalMonitorOff), findsNWidgets(2));
    });

    testWidgets('OFF recedes while ON and AUTO both take the accent', (
      tester,
    ) async {
      await pump(tester);
      await monitor.setMode(0, MonitorMode.on);
      await monitor.setMode(1, MonitorMode.auto);
      await monitor.setMode(2, MonitorMode.off);
      await tester.pump();

      bool audibleOf(String key) =>
          tester.widget<SignalCard>(find.byKey(Key(key))).monitor!.audible;

      expect(audibleOf('signal_card_input_0'), isTrue);
      // AUTO stays accented: its answer depends on the arm rather than on the
      // setting, and greying it out would contradict itself the moment a
      // track fed by this socket is armed.
      expect(audibleOf('signal_card_input_1'), isTrue);
      expect(audibleOf('signal_card_input_2'), isFalse);
    });

    testWidgets('a loopback socket gets no card at all', (tester) async {
      await pump(
        tester,
        state: const LooperState(
          status: EngineStatus(
            inputChannels: 4,
            outputChannels: 2,
            // Socket 2 is loopback: never monitorable, never capturable.
            excludedInputMask: 0x4,
          ),
        ),
      );

      expect(find.byKey(const Key('signal_card_input_1')), findsOneWidget);
      expect(find.byKey(const Key('signal_card_input_2')), findsNothing);
      expect(find.byKey(const Key('signal_card_input_3')), findsOneWidget);
    });

    testWidgets('a stopped engine reports no sockets', (tester) async {
      await pump(tester, state: _stopped);
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_empty_card')), findsOneWidget);
      expect(find.text(l10n.signalNoInputs), findsOneWidget);
    });
  });

  // ---------------------------------------------- SIGNAL / signal-loop

  group('SIGNAL / signal-loop', () {
    testWidgets('one card per LANE, named for its track', (tester) async {
      await pump(tester, stage: FxStage.loop);
      await tracks.rename(2, 'rhythm');
      await tester.pump();
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_card_loop_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_card_loop_2_0')), findsOneWidget);
      expect(find.text('rhythm'), findsOneWidget);
      expect(find.text(l10n.signalCoordTrackLane(3, 'A')), findsOneWidget);
    });

    testWidgets('a two-lane track draws two cards, lettered', (tester) async {
      await pump(
        tester,
        stage: FxStage.loop,
        state: const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)]),
          ],
          status: EngineStatus(inputChannels: 2, outputChannels: 2),
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_card_loop_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_card_loop_0_1')), findsOneWidget);
      expect(find.text(l10n.signalCoordTrackLane(1, 'A')), findsOneWidget);
      expect(find.text(l10n.signalCoordTrackLane(1, 'B')), findsOneWidget);
    });

    testWidgets('the chip says MONITOR ONLY and the cards route to the mix', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalScopeMonitorOnly), findsOneWidget);
      expect(find.text(l10n.signalRouteMix), findsNWidgets(3));
    });

    testWidgets('a rackless card omits the monitor line entirely', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      final l10n = l10nOf(tester);

      // The absence is the design's, not an oversight: the vacant card in the
      // mockups has five facts where a loaded one has six. Every card in this
      // slice is rackless, so the loop face says nothing about monitoring.
      for (final card in tester.widgetList<SignalCard>(
        find.byType(SignalCard),
      )) {
        expect(card.monitor, isNull);
      }
      expect(find.text(l10n.signalMonitorOff), findsNothing);
      expect(find.text(l10n.signalMonitorAuto), findsNothing);
      expect(find.text(l10n.signalMonitorOn), findsNothing);
    });

    testWidgets('a fresh session has no takes and says what fills it', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop, state: _stopped);
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_empty_card')), findsOneWidget);
      expect(find.text(l10n.signalNoLanes), findsOneWidget);
    });

    testWidgets('a laneless track contributes no card', (tester) async {
      await pump(
        tester,
        stage: FxStage.loop,
        state: const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 0)]),
            Track(channel: 1),
          ],
          status: EngineStatus(inputChannels: 2, outputChannels: 2),
        ),
      );

      expect(find.byType(SignalCard), findsOneWidget);
      expect(find.byKey(const Key('signal_card_loop_1_0')), findsNothing);
    });
  });

  // --------------------------------------------- SIGNAL / signal-track

  group('SIGNAL / signal-track', () {
    testWidgets('one card per TRACK, and the coordinate loses its lane', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      final l10n = l10nOf(tester);

      expect(find.byType(SignalCard), findsNWidgets(3));
      expect(find.byKey(const Key('signal_card_track_2')), findsOneWidget);
      // `track 3`, not `track 3 · lane A` — a track bus sits downstream of
      // every lane, so there is no lane to name.
      expect(find.text(l10n.signalCoordTrack(3)), findsOneWidget);
      expect(find.text(l10n.signalCoordTrackLane(3, 'A')), findsNothing);
    });

    testWidgets('the chain feeds the master sum, not the track mix', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      final l10n = l10nOf(tester);

      // Scoped to the cards: `master` is also the fourth TAB's label, so an
      // unscoped finder counts the strip too.
      expect(
        find.descendant(
          of: find.byType(SignalCard),
          matching: find.text(l10n.signalRouteMaster),
        ),
        findsNWidgets(3),
      );
      expect(find.text(l10n.signalRouteMix), findsNothing);
      expect(find.text(l10n.signalScopeMonitorOnly), findsOneWidget);
    });

    testWidgets('a stopped engine reports no tracks', (tester) async {
      await pump(tester, stage: FxStage.track, state: _stopped);
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_empty_card')), findsOneWidget);
      expect(find.text(l10n.signalNoTracks), findsOneWidget);
    });
  });

  // -------------------------------------------- SIGNAL / signal-master

  group('SIGNAL / signal-master', () {
    testWidgets('one full-width card over the outputs it sums into', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);
      final l10n = l10nOf(tester);

      expect(find.byType(SignalCard), findsNWidgets(1));
      expect(find.text(l10n.signalMasterCardName), findsOneWidget);
      expect(find.text(l10n.signalCoordMain), findsOneWidget);
      expect(find.text(l10n.signalRouteOutputs), findsOneWidget);
      // Full width: there is one card, so nothing to sit beside it.
      expect(
        tester.widget<SignalCard>(find.byType(SignalCard)).width,
        isNull,
      );
    });

    testWidgets('one row per hardware output, with what it is wired to', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalOutputsGroup), findsOneWidget);
      expect(find.byKey(const Key('signal_output_row_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_output_row_3')), findsOneWidget);
      expect(find.byKey(const Key('signal_output_row_4')), findsNothing);
      expect(find.text(l10n.signalOutputMainLeft), findsOneWidget);
      expect(find.text(l10n.signalOutputPhonesRight), findsOneWidget);
    });

    testWidgets('past the fourth socket a row carries its ordinal alone', (
      tester,
    ) async {
      await pump(
        tester,
        stage: FxStage.master,
        state: const LooperState(
          status: EngineStatus(inputChannels: 2, outputChannels: 6),
        ),
      );
      final l10n = l10nOf(tester);

      expect(find.text(l10n.outputChannelLabel(6)), findsOneWidget);
      expect(
        tester
            .widget<ConsoleRow>(
              find.descendant(
                of: find.byKey(const Key('signal_output_row_5')),
                matching: find.byType(ConsoleRow),
              ),
            )
            .subtitle,
        isNull,
      );
    });

    testWidgets('the switch reflects the rig gate, off included', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);

      bool onOf(int output) => tester
          .widget<ConsoleSwitch>(
            find.byKey(Key('signal_output_switch_$output')),
          )
          .value;

      expect(onOf(0), isTrue);
      expect(onOf(2), isTrue);
      expect(onOf(3), isFalse);
    });

    testWidgets('flipping a switch writes the gate through the bloc', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);

      await tester.tap(find.byKey(const Key('signal_output_switch_3')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperOutputEnabledToggled(3, enabled: true)),
      ).called(1);
    });

    testWidgets('every output off says so, once, over the group', (
      tester,
    ) async {
      await pump(
        tester,
        stage: FxStage.master,
        state: const LooperState(
          outputEnabledMask: 0,
          status: EngineStatus(inputChannels: 2, outputChannels: 4),
        ),
      );
      final l10n = l10nOf(tester);

      expect(
        find.byKey(const Key('signal_no_outputs_banner')),
        findsOneWidget,
      );
      expect(find.text(l10n.noActiveOutputsNotice), findsOneWidget);
    });

    testWidgets('one live output is enough to drop the warning', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);

      expect(find.byKey(const Key('signal_no_outputs_banner')), findsNothing);
    });

    testWidgets('a stopped engine reports no outputs', (tester) async {
      await pump(tester, stage: FxStage.master, state: _stopped);
      final l10n = l10nOf(tester);

      expect(
        find.byKey(const Key('signal_outputs_empty_card')),
        findsOneWidget,
      );
      expect(find.text(l10n.signalNoOutputs), findsOneWidget);
      // The master card is still drawn: there is exactly one Master insert
      // whether or not the rig has anywhere to play it.
      expect(find.byType(SignalCard), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ helpers

  group('helpers', () {
    test('lanes are lettered, and fall back to the ordinal past Z', () {
      expect(laneLetter(0), 'A');
      expect(laneLetter(1), 'B');
      expect(laneLetter(25), 'Z');
      expect(laneLetter(26), '27');
    });

    test('the chain shape ignores everything a card does not draw', () {
      const a = [
        Track(lanes: [Lane(inputChannel: 0)]),
      ];
      // A meter tick rewrites the whole Track; the face must not rebuild for
      // it, so a differing level has to compare equal here.
      const b = [
        Track(rms: 0.7, peak: 0.9, lanes: [Lane(inputChannel: 1)]),
      ];
      expect(sameChainShape(a, b), isTrue);

      const grown = [
        Track(lanes: [Lane(inputChannel: 0), Lane()]),
      ];
      expect(sameChainShape(a, grown), isFalse);
      expect(sameChainShape(a, const []), isFalse);
    });
  });

  testWidgets('every tap target is labeled (labeledTapTargetGuideline)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, stage: FxStage.master);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
