import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A track, by number. Positional because `Track`'s own `channel` defaults to
/// `0` — writing `channel: 0` out reads as deliberate but lints as redundant,
/// and leaving it off reads as an oversight.
Track _track(
  int channel, {
  int inputMask = 0x1,
  int outputMask = 0x3,
  int lengthPresetBars = 0,
  List<int>? inputs,
}) => Track(
  channel: channel,
  inputMask: inputMask,
  outputMask: outputMask,
  lengthPresetBars: lengthPresetBars,
  // A track records one lane per input; `inputs` spells those lanes out, and
  // the masks are the lane-0 mirror a stopped engine reports instead.
  lanes: [
    for (final input in inputs ?? [maskToInputChannel(inputMask)])
      Lane(inputChannel: input, outputMask: outputMask),
  ],
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late TracksCubit names;
  late QuantizeCubit quantize;
  late InputsCubit inputs;
  late SettingsRepository settings;

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.trackQuantize(any())).thenReturn(null);
    settings = SettingsRepository(store: FakeKeyValueStore());
    names = TracksCubit(settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    inputs = InputsCubit(settings: settings);
  });

  tearDown(() async {
    await names.close();
    await quantize.close();
    await inputs.close();
  });

  /// Four tracks, named, with [tracks] overriding whichever fields a test
  /// cares about.
  void seed({List<Track>? tracks, int inputs = 4, int outputs = 2}) {
    final state = LooperState(
      tracks: tracks ?? [for (var i = 0; i < 4; i++) _track(i)],
      status: EngineStatus(inputChannels: inputs, outputChannels: outputs),
    );
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester, TracksTab tab) async {
    // The console face is drawn for 1920x1080; the default 800x600 surface
    // pushes rows below the fold where a tap lands on nothing.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<TracksCubit>.value(value: names),
              BlocProvider<QuantizeCubit>.value(value: quantize),
              BlocProvider<InputsCubit>.value(value: inputs),
            ],
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(19),
                child: TracksTrayPanel(tab: tab, onTabChanged: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Names tab', () {
    testWidgets('lists the tracks the rig has, named and numbered', (
      tester,
    ) async {
      seed(tracks: [for (var i = 0; i < 3; i++) _track(i)]);
      await names.rename(0, 'drums');
      await pump(tester, TracksTab.names);

      expect(find.text('drums'), findsOneWidget);
      // The unnamed ones keep their fallback rather than going blank.
      expect(find.text('TRACK 2'), findsOneWidget);
      expect(find.text('track 3'), findsOneWidget);
      expect(find.byKey(const Key('track_name_row_3')), findsNothing);
    });

    testWidgets('renaming through the sheet reaches the cubit', (tester) async {
      seed();
      await pump(tester, TracksTab.names);

      await tester.tap(find.byKey(const Key('track_name_row_1')));
      await tester.pumpAndSettle();
      // The sheet opens on the current name, and the first key REPLACES it.
      expect(find.byKey(const Key('console_rename_field')), findsOneWidget);
      await tester.tap(find.widgetWithText(InkWell, 'b').first);
      await tester.tap(find.widgetWithText(InkWell, 'a').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done').last);
      await tester.pumpAndSettle();

      expect(names.state.nameOf(1), 'ba');
    });
  });

  group('Lengths tab', () {
    testWidgets('shows Auto or the preset, and picks a new one', (
      tester,
    ) async {
      seed(
        tracks: [
          _track(0, lengthPresetBars: 8),
          // No preset: the default, which is what Auto means.
          _track(1),
        ],
      );
      await pump(tester, TracksTab.lengths);

      expect(find.text('8 bars'), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);

      await tester.tap(find.byKey(const Key('track_length_row_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_chip_16 bars')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperTrackLengthPresetChanged(1, 16)),
      ).called(1);
    });
  });

  group('Empty rig', () {
    testWidgets('says why there is nothing to show', (tester) async {
      // A stopped engine reports no tracks at all.
      seed(tracks: const []);
      await pump(tester, TracksTab.names);

      expect(
        find.text('No tracks — the engine is not running.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('track_name_row_0')), findsNothing);
    });
  });

  group('Routing tab', () {
    testWidgets('summarises input, outputs and the quantize override', (
      tester,
    ) async {
      when(() => repository.trackQuantize(0)).thenReturn(true);
      seed(
        tracks: [
          // In 2 to the default stereo pair.
          _track(0, inputMask: 0x2),
          // Recording nothing, sent nowhere.
          _track(1, inputMask: 0, inputs: const [], outputMask: 0),
          // Two inputs — two lanes, one track — out its own way.
          _track(2, inputs: const [0, 2], outputMask: 0x4),
        ],
      );
      await pump(tester, TracksTab.routing);

      expect(find.text('In 2 · quantize on'), findsOneWidget);
      // Every input the track records, not just the first lane's.
      expect(find.text('In 1 · In 3'), findsOneWidget);
      expect(find.text('Out 1 · Out 2'), findsOneWidget);
      // A track that follows the global setting says nothing about quantize.
      expect(find.text('None (clean)'), findsOneWidget);
      expect(find.text('not routed'), findsOneWidget);
    });

    testWidgets('an input is called what the player calls it', (tester) async {
      await inputs.rename(1, 'mic');
      seed(tracks: [_track(0, inputMask: 0x2)]);
      await pump(tester, TracksTab.routing);

      // The summary line and the lane list both use the given name; the
      // unnamed sockets keep their ordinal.
      expect(find.text('mic'), findsOneWidget);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();
      expect(find.text('mic'), findsWidgets);
      expect(find.text('In 1'), findsOneWidget);
    });

    testWidgets('the sheet applies input, output and quantize as tapped', (
      tester,
    ) async {
      // In 1 to the default stereo pair.
      seed(tracks: [_track(0)]);
      await pump(tester, TracksTab.routing);

      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('track_input_2')));
      await tester.tap(find.byKey(const Key('track_quantize_never')));
      await tester.pumpAndSettle();
      // Lane 0's outputs live inside lane 0's own row.
      await tester.tap(find.byKey(const Key('track_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track_output_0_1')));
      await tester.pumpAndSettle();

      // Checking a second input grows the track by a lane and routes the new
      // one — it does not replace what lane 0 records.
      verify(() => bloc.add(const LooperLaneCountChanged(0, 2))).called(1);
      verify(() => bloc.add(const LooperLaneInputChanged(0, 1, 2))).called(1);
      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 0, 0x1)),
      ).called(1);
      verify(
        () => bloc.add(const LooperTrackQuantizeChanged(0, enabled: false)),
      ).called(1);

      await tester.tap(find.byKey(const Key('track_routing_done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_routing_done')), findsNothing);
    });

    testWidgets('warns in the sheet when the track goes nowhere', (
      tester,
    ) async {
      seed(tracks: [_track(0, outputMask: 0)]);
      await pump(tester, TracksTab.routing);

      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      // The warning belongs to the LANE, so it shows when the lane is open.
      await tester.tap(find.byKey(const Key('track_input_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_unrouted_banner')), findsOneWidget);
      expect(
        find.text('Nothing routed here — this lane will not be heard.'),
        findsOneWidget,
      );
    });

    testWidgets('the quantize list marks which of the three is current', (
      tester,
    ) async {
      when(() => repository.trackQuantize(0)).thenReturn(false);
      seed(tracks: [_track(0, outputMask: 0x1)]);
      await pump(tester, TracksTab.routing);

      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      Finder check(String key) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byIcon(Icons.check),
      );
      expect(check('track_quantize_never'), findsOneWidget);
      expect(check('track_quantize_follow'), findsNothing);
      expect(check('track_quantize_always'), findsNothing);
    });

    testWidgets('unchecking an input frees its own lane, in place', (
      tester,
    ) async {
      // In 1 on lane 0, In 3 on lane 1.
      seed(
        tracks: [
          _track(0, inputs: const [0, 2]),
        ],
      );
      await pump(tester, TracksTab.routing);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      // The check itself un-checks a lane; the row body opens it.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('track_input_0')),
          matching: find.byIcon(Icons.check),
        ),
      );
      await tester.pumpAndSettle();

      // Lane 0 stops recording; lane 1 keeps ITS input, because a lane index
      // is the identity of the audio recorded into it.
      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
      verifyNever(() => bloc.add(const LooperLaneInputChanged(0, 0, 2)));
      verifyNever(() => bloc.add(const LooperLaneCountChanged(0, 1)));
    });

    testWidgets('a freed lane is reused before the track grows again', (
      tester,
    ) async {
      seed(
        tracks: [
          _track(0, inputs: const [-1, 2]),
        ],
      );
      await pump(tester, TracksTab.routing);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('track_input_1')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, 1))).called(1);
      verifyNever(() => bloc.add(const LooperLaneCountChanged(0, 3)));
    });

    testWidgets('None (clean) stops every lane recording', (tester) async {
      seed(
        tracks: [
          _track(0, inputs: const [0, 2]),
        ],
      );
      await pump(tester, TracksTab.routing);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('track_input_none')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
      verify(() => bloc.add(const LooperLaneInputChanged(0, 1, -1))).called(1);
    });

    testWidgets('an output chip moves ONLY its own lane', (tester) async {
      seed(
        tracks: [
          _track(0, inputs: const [0, 2]),
        ],
      );
      await pump(tester, TracksTab.routing);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      // Open lane 1 (In 3) and take it off Out 2. A guitar lane to the mains
      // and its DI lane to the desk is one track, two destinations.
      await tester.tap(find.byKey(const Key('track_input_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('track_output_1_1')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 1, 0x1)),
      ).called(1);
      verifyNever(() => bloc.add(const LooperLaneOutputChanged(0, 0, 0x1)));
    });

    testWidgets('only one lane is open at a time', (tester) async {
      seed(
        tracks: [
          _track(0, inputs: const [0, 2]),
        ],
      );
      await pump(tester, TracksTab.routing);
      await tester.tap(find.byKey(const Key('track_routing_row_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('track_input_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_output_0_0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('track_input_2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_output_1_0')), findsOneWidget);
      expect(find.byKey(const Key('track_output_0_0')), findsNothing);
    });
  });
}
