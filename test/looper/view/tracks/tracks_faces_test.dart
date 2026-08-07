import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/looper/view/tray/tray.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-track rig, routed the way `TRACKS / tracks-routing` draws it: two
/// lanes on the first track, one each on the next two, and a fourth that
/// records nothing and reaches nothing.
///
/// A bare `Lane()` already records NOTHING (`inputChannel: -1`) out of the
/// first pair of outputs (`outputMask: 0x3`), so only the departures from that
/// are spelled out below.
const _rig = LooperState(
  tracks: [
    Track(
      lengthPresetBars: 8,
      lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
    ),
    Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
    Track(channel: 2, lanes: [Lane(inputChannel: 0, outputMask: 0x7)]),
    Track(channel: 3, lanes: [Lane(outputMask: 0)]),
  ],
  status: EngineStatus(inputChannels: 4, outputChannels: 4),
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late TracksCubit tracks;
  late QuantizeCubit quantize;
  late SettingsTrayCubit tray;

  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.trackQuantize(any())).thenReturn(null);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: state,
    );
  }

  /// Mounts the Tracks face with the providers the real tray inherits.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view pushes the lower rows below the fold where a
  /// tap lands on nothing.
  Future<void> pump(
    WidgetTester tester, {
    TracksTab tab = TracksTab.names,
    LooperState state = _rig,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    seed(state);
    settings = SettingsRepository(store: FakeKeyValueStore());
    tracks = TracksCubit(settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    tray = SettingsTrayCubit(settings: settings)..showTracksTab(tab);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(quantize.close()));
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
              BlocProvider.value(value: quantize),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: TracksTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(TracksTrayPanel)));

  // ------------------------------------------------------------------ names

  group('Tracks — Names', () {
    testWidgets('the domain names itself once, above the strip', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(find.byType(ConsoleDomainPanel<TracksTab>), findsOneWidget);
      expect(find.text(l10n.trayTracksLabel), findsOneWidget);
      expect(find.text(l10n.tracksNamesTab), findsOneWidget);
      expect(find.text(l10n.tracksLengthsTab), findsOneWidget);
      expect(find.text(l10n.tracksRoutingTab), findsOneWidget);
    });

    testWidgets('one row per track the ENGINE reports, not a fixed count', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byKey(const Key('tracks_names_row_3')), findsOneWidget);
      // The names list holds eight, the rig reports four.
      expect(find.byKey(const Key('tracks_names_row_4')), findsNothing);
    });

    testWidgets('a row reads the name, with the ordinal beside it', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tracks.rename(0, 'drums');
      await tester.pump();

      expect(find.text('drums'), findsOneWidget);
      expect(find.text(l10n.tracksOrdinal(1)), findsOneWidget);
    });

    testWidgets('tapping a row opens the console rename sheet, not a dialog', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_rename_sheet')), findsOneWidget);
      // The keys are IN the sheet — the console has no other keyboard.
      expect(find.text('q'), findsOneWidget);
    });

    testWidgets('typing and saving renames the track', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();
      // Clear the seeded name, then type a new one.
      for (var i = 0; i < 'TRACK 2'.length; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
      }
      await tester.pump();
      for (final key in ['b', 'a', 's', 's']) {
        await tester.tap(find.text(key));
      }
      await tester.pump();
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(tracks.state.names[1], 'bass');
    });

    testWidgets('an empty name does not close the sheet, and renames nothing', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 'TRACK 2'.length; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
      }
      await tester.pump();
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_rename_sheet')), findsOneWidget);
      expect(tracks.state.names[1], 'TRACK 2');
    });
  });

  // ---------------------------------------------------------------- lengths

  group('Tracks — Lengths', () {
    testWidgets('a row reads auto or its bar preset', (tester) async {
      await pump(tester, tab: TracksTab.lengths);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.lengthPresetBars(8)), findsOneWidget);
      expect(find.text(l10n.tracksLengthAuto), findsNWidgets(3));
    });

    testWidgets('the row opens IN PLACE onto the preset grid', (tester) async {
      await pump(tester, tab: TracksTab.lengths);

      expect(find.byKey(const Key('tracks_lengths_0_16')), findsNothing);
      await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tracks_lengths_0_16')), findsOneWidget);
      // The list it came from is still there — this is a drawer, not a route.
      expect(find.byKey(const Key('tracks_lengths_row_3')), findsOneWidget);
    });

    testWidgets('the chooser GROWS open rather than appearing', (tester) async {
      await pump(tester, tab: TracksTab.lengths);

      await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
      await tester.pump();
      await tester.pump(kConsoleMotion ~/ 2);
      final midway = tester.getSize(
        find.byKey(const Key('tracks_lengths_slot_0')),
      );
      await tester.pumpAndSettle();
      final settled = tester.getSize(
        find.byKey(const Key('tracks_lengths_slot_0')),
      );

      // Goldens only ever photograph settled states, so the growth itself has
      // to be asserted mid-flight or nothing pins it.
      expect(midway.height, lessThan(settled.height));
      expect(midway.height, greaterThan(0));
    });

    testWidgets('picking a preset writes it and closes the chooser', (
      tester,
    ) async {
      await pump(tester, tab: TracksTab.lengths);

      await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tracks_lengths_0_16')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperTrackLengthPresetChanged(0, 16)),
      ).called(1);
      expect(find.byKey(const Key('tracks_lengths_0_16')), findsNothing);
    });

    testWidgets('only one row is open at a time', (tester) async {
      await pump(tester, tab: TracksTab.lengths);

      await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tracks_lengths_row_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tracks_lengths_0_16')), findsNothing);
      expect(find.byKey(const Key('tracks_lengths_1_16')), findsOneWidget);
    });

    testWidgets('the preset set is the one Settings already offers', (
      tester,
    ) async {
      await pump(tester, tab: TracksTab.lengths);

      await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
      await tester.pumpAndSettle();

      for (final preset in SetupTrackLengthPresetRow.presets) {
        expect(
          find.byKey(Key('tracks_lengths_0_$preset')),
          findsOneWidget,
          reason: 'preset $preset is offered on Settings but not here',
        );
      }
    });
  });

  // ------------------------------------------------------------- empty rig

  group('Tracks — a stopped engine', () {
    for (final tab in TracksTab.values) {
      testWidgets('${tab.name} says so instead of drawing a sliver', (
        tester,
      ) async {
        await pump(tester, tab: tab, state: const LooperState());
        final l10n = l10nOf(tester);

        expect(find.byKey(const Key('tracks_empty_card')), findsOneWidget);
        expect(find.text(l10n.tracksEmpty), findsOneWidget);
        // The footnote still applies — it is about the setting, not the rows.
        expect(find.byType(ConsoleProse), findsWidgets);
      });
    }
  });

  // ---------------------------------------------------------------- routing

  group('Tracks — Routing', () {
    testWidgets('a row summarises the union of its lanes', (tester) async {
      await pump(tester, tab: TracksTab.routing);
      final l10n = l10nOf(tester);

      // Track 0 records In 1 AND In 2 — a track is not its lane 0.
      expect(
        find.text(
          '${l10n.inputChannelLabel(1)} · ${l10n.inputChannelLabel(2)}',
        ),
        findsOneWidget,
      );
      // Track 2's single lane reaches three outputs.
      expect(
        find.text(
          '${l10n.outputChannelLabel(1)} · ${l10n.outputChannelLabel(2)} · '
          '${l10n.outputChannelLabel(3)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a track that reaches nothing is called out', (tester) async {
      await pump(tester, tab: TracksTab.routing);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.tracksNotRouted), findsOneWidget);
      expect(find.text(l10n.tracksNoInputs), findsOneWidget);
    });

    testWidgets('a quantize override shows on the summary line', (
      tester,
    ) async {
      when(() => repository.trackQuantize(1)).thenReturn(true);
      await pump(tester, tab: TracksTab.routing);
      final l10n = l10nOf(tester);

      expect(
        find.text(
          '${l10n.inputChannelLabel(2)} · ${l10n.tracksQuantizeOn}',
        ),
        findsOneWidget,
      );
    });

    testWidgets("a row opens that track's own panel", (tester) async {
      await pump(tester, tab: TracksTab.routing);

      await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_routing_dialog_0')), findsOneWidget);
    });
  });

  // ------------------------------------------------------ the routing panel

  group('the per-track routing panel', () {
    Future<void> openPanel(WidgetTester tester, {int channel = 0}) async {
      await pump(tester, tab: TracksTab.routing);
      await tester.tap(find.byKey(Key('tracks_routing_row_$channel')));
      await tester.pumpAndSettle();
    }

    testWidgets('leads with the name and keeps the ordinal underneath', (
      tester,
    ) async {
      await pump(tester, tab: TracksTab.routing);
      await tracks.rename(0, 'drums');
      await tester.pump();
      await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.trackSettingsDialogTitle('drums')), findsOneWidget);
      expect(find.text(l10n.tracksOrdinal(1)), findsOneWidget);
    });

    testWidgets("a checked input carries its OWN lane's outputs", (
      tester,
    ) async {
      await openPanel(tester, channel: 2);
      final l10n = l10nOf(tester);

      // Lane 0 of track 2 goes to three outputs; the row says so.
      expect(
        find.text(
          '${l10n.outputChannelLabel(1)} · ${l10n.outputChannelLabel(2)} · '
          '${l10n.outputChannelLabel(3)}',
        ),
        findsWidgets,
      );
    });

    testWidgets('checking a free input reuses a freed lane before growing', (
      tester,
    ) async {
      // Lane 1 records nothing, so In 3 must land there rather than on a new
      // lane 2 — growing here would leave a permanently dead lane behind.
      await pump(
        tester,
        tab: TracksTab.routing,
        state: const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 0), Lane()]),
          ],
          status: EngineStatus(inputChannels: 4, outputChannels: 4),
        ),
      );
      await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('track_routing_input_2')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 1, 2))).called(1);
      verifyNever(() => bloc.add(any(that: isA<LooperLaneCountChanged>())));
    });

    testWidgets('with no spare lane the track GROWS before it is routed', (
      tester,
    ) async {
      await openPanel(tester, channel: 1);

      await tester.tap(find.byKey(const Key('track_routing_input_2')));
      await tester.pumpAndSettle();

      verifyInOrder([
        () => bloc.add(const LooperLaneCountChanged(1, 2)),
        () => bloc.add(const LooperLaneInputChanged(1, 1, 2)),
      ]);
    });

    testWidgets('unchecking an input frees its OWN lane, in place', (
      tester,
    ) async {
      await openPanel(tester);

      // Track 0 records In 1 on lane 0 and In 2 on lane 1. Dropping In 1 must
      // free LANE 0 — not renumber In 2 down onto it. The check gutter is what
      // undoes the choice; the row body opens the lane.
      await tester.tap(find.byKey(const Key('track_routing_check_0')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
      verifyNever(() => bloc.add(const LooperLaneInputChanged(0, 0, 1)));
    });

    testWidgets('an output chip moves ONLY its own lane', (tester) async {
      await openPanel(tester);

      await tester.tap(find.byKey(const Key('track_routing_input_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track_routing_out_1_2')));
      await tester.pumpAndSettle();

      // Lane 1 (In 2), mask 0x3, toggling out 2 => 0x7. Lane 0 untouched.
      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 1, 0x7)),
      ).called(1);
      verifyNever(
        () => bloc.add(
          any(
            that: isA<LooperLaneOutputChanged>().having(
              (event) => event.lane,
              'lane',
              0,
            ),
          ),
        ),
      );
    });

    testWidgets('the output grid stays open — no single tap answers it', (
      tester,
    ) async {
      await openPanel(tester);

      await tester.tap(find.byKey(const Key('track_routing_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track_routing_out_0_2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_routing_out_0_2')), findsOneWidget);
    });

    testWidgets('only one lane is open at a time', (tester) async {
      await openPanel(tester);

      await tester.tap(find.byKey(const Key('track_routing_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track_routing_input_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_routing_out_0_0')), findsNothing);
      expect(find.byKey(const Key('track_routing_out_1_0')), findsOneWidget);
    });

    testWidgets('the unrouted warning sits INSIDE the lane it describes', (
      tester,
    ) async {
      // One lane, recording In 1, reaching nothing: silent, and the panel has
      // to say so where the outputs are rather than over the whole track.
      await pump(
        tester,
        tab: TracksTab.routing,
        state: const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 0, outputMask: 0)]),
          ],
          status: EngineStatus(inputChannels: 4, outputChannels: 4),
        ),
      );
      await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
      await tester.pumpAndSettle();

      // Shut, the warning is nowhere — it belongs to the lane, not the panel.
      expect(find.byKey(const Key('track_routing_unrouted_0')), findsNothing);
      await tester.tap(find.byKey(const Key('track_routing_input_0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('track_routing_unrouted_0')),
        findsOneWidget,
      );
    });

    testWidgets('None (clean) stops every lane recording', (tester) async {
      await openPanel(tester);

      await tester.tap(find.byKey(const Key('track_routing_none')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
      verify(() => bloc.add(const LooperLaneInputChanged(0, 1, -1))).called(1);
    });

    testWidgets('the quantize override renders its current value', (
      tester,
    ) async {
      when(() => repository.trackQuantize(0)).thenReturn(false);
      await openPanel(tester);

      final never = tester.widget<ConsolePickRow>(
        find.byKey(const Key('track_routing_quantize_never')),
      );
      final follow = tester.widget<ConsolePickRow>(
        find.byKey(const Key('track_routing_quantize_follow')),
      );
      expect(never.selected, isTrue);
      expect(follow.selected, isFalse);
    });

    testWidgets('follow spells out what the global currently means', (
      tester,
    ) async {
      await openPanel(tester);
      final l10n = l10nOf(tester);

      final follow = tester.widget<ConsolePickRow>(
        find.byKey(const Key('track_routing_quantize_follow')),
      );
      expect(follow.selected, isTrue);
      expect(follow.state, l10n.trackQuantizeGlobalOff);
    });

    testWidgets('choosing an override writes it', (tester) async {
      await openPanel(tester);

      await tester.tap(
        find.byKey(const Key('track_routing_quantize_always')),
      );
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperTrackQuantizeChanged(0, enabled: true)),
      ).called(1);
    });

    testWidgets('Done dismisses; it does not commit', (tester) async {
      await openPanel(tester);

      await tester.tap(find.byKey(const Key('track_routing_done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_routing_dialog_0')), findsNothing);
    });
  });

  // ------------------------------------------------------------------- rail

  group('the rail', () {
    testWidgets('reaches the Tracks face', (tester) async {
      await pump(tester);
      tray.showDestination(SettingsTrayDestination.tracks);
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
                BlocProvider.value(value: quantize),
                BlocProvider.value(value: tray),
              ],
              child: const Scaffold(body: TrayPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tracks_tray_panel')), findsOneWidget);
    });

    testWidgets('the tab strip swaps the body and the choice survives', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.text(l10nOf(tester).tracksRoutingTab));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tracks_routing_tab')), findsOneWidget);
      expect(tray.state.tracksTab, TracksTab.routing);
    });
  });
}
