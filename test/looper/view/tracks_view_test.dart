import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    for (final stub in [
      () => repository.record(channel: any(named: 'channel')),
      () => repository.play(channel: any(named: 'channel')),
      () => repository.stopTrack(channel: any(named: 'channel')),
      () => repository.clear(channel: any(named: 'channel')),
    ]) {
      when(stub).thenReturn(EngineResult.ok);
    }
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    // The real control cubit: it owns the system mode/cursor/bank the view
    // reads, and the M key / mode chip / number keys drive it.
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
    );
    addTearDown(control.close);
    session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    when(session.save).thenAnswer((_) async {});
    when(session.refreshSessions).thenAnswer((_) async {});
    when(() => session.saveAs(any())).thenAnswer((_) async {});
    when(() => session.exportMixdown()).thenAnswer((_) async {});
    when(() => session.exportStems()).thenAnswer((_) async {});
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    // Keep the repository snapshot (what ControlIntents reads) in step with
    // the bloc state the view renders.
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<SessionCubit>.value(value: session),
          ],
          child: const TracksView(),
        ),
      ),
    ),
  );

  testWidgets('renders a tile per track', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_1')), findsOneWidget);
  });

  testWidgets('exposes a visible entry to the Signal surface', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    // The chrome carries one global affordance opening the Signal surface
    // (the per-track routing dialog is gone — wiring lives on Signal now).
    expect(find.byKey(const Key('tracks_openSignal')), findsOneWidget);
  });

  testWidgets('exposes a visible Settings button', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    // Settings was previously reachable only by the `S` key or right-click;
    // the top-bar button makes it operable by pointer/touch.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const Key('tracks_openSettings')), findsOneWidget);
    expect(find.byTooltip(l10n.settingsTooltip), findsOneWidget);
  });

  testWidgets('tapping a tile records that channel in record mode', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
  });

  testWidgets('tapping a tile mutes/unmutes that channel in play mode', (
    tester,
  ) async {
    control.toggleMode(); // record -> play
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    // Mirrors the play-mode number-key behavior; does not arm recording.
    verify(() => bloc.add(const LooperMuteToggled(1))).called(1);
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    // The tap also selects the tapped channel.
    expect(control.state.cursor, 1);
  });

  testWidgets('long-pressing a tile stops that channel', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.longPress(find.byKey(const Key('tracks_tile_0')));
    verify(() => bloc.add(const LooperStopPressed(0))).called(1);
  });

  testWidgets('shows one bank of four and switches A/B', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]));
    await pump(tester);

    // Bank A shows channels 0-3 only.
    expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_3')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_4')), findsNothing);

    // Switch to bank B -> channels 4-7.
    await tester.tap(find.byKey(const Key('tracks_bank_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tracks_tile_4')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_7')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_0')), findsNothing);
  });

  group('keyboard', () {
    testWidgets('M toggles the tracks mode', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(control.state.mode, LooperMode.record);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(control.state.mode, LooperMode.play);
    });

    testWidgets('a number key selects that track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(control.state.cursor, 1);
    });

    testWidgets('record mode: R records the selected track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
    });

    testWidgets('play mode: a number key selects and toggles mute', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM); // -> play mode
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(control.state.cursor, 0);
      verify(() => bloc.add(const LooperMuteToggled(0))).called(1);
    });

    testWidgets('Space plays all when nothing is playing', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('C clears all', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      // Clear-all is a ControlIntents action: every content track is cleared
      // and re-armed on the engine directly.
      verify(() => repository.clear()).called(1);
      verify(() => repository.setMute(muted: false)).called(1);
    });

    testWidgets('F toggles fullscreen without error', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
    });
  });

  testWidgets('renaming a track updates its label', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tracks_name_0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // open dialog

    await tester.enterText(
      find.byKey(const Key('renameTrack_field')),
      'GUITAR',
    );
    await tester.tap(find.byKey(const Key('renameTrack_save')));
    await tester.pumpAndSettle();

    expect(find.text('GUITAR'), findsOneWidget);
    expect(find.text('TRACK 1'), findsNothing);
    expect(await settings.loadTrackName(0), 'GUITAR');
  });

  group('play-mode visuals', () {
    final looper = AppTheme.neon.extension<LooperTheme>()!;

    // The meter Container inside a track tile (the _PeakBar's fill).
    Container barOf(WidgetTester tester, int channel) =>
        tester
                .widget<FractionallySizedBox>(
                  find.descendant(
                    of: find.byKey(Key('tracks_tile_$channel')),
                    matching: find.byType(FractionallySizedBox),
                  ),
                )
                .child!
            as Container;

    // The meter fill fraction (the _PeakBar's height factor) for a tile.
    double fillOf(WidgetTester tester, int channel) => tester
        .widget<FractionallySizedBox>(
          find.descendant(
            of: find.byKey(Key('tracks_tile_$channel')),
            matching: find.byType(FractionallySizedBox),
          ),
        )
        .heightFactor!;

    testWidgets('a stopped loaded track freezes its last meter level', (
      tester,
    ) async {
      const playing = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 1000, peak: 0.81),
        ],
      );
      const stopped = LooperState(
        tracks: [Track(state: TrackState.stopped, lengthFrames: 1000)],
      );
      final controller = StreamController<LooperState>();
      addTearDown(controller.close);
      var current = playing;
      when(() => bloc.state).thenAnswer((_) => current);
      whenListen(bloc, controller.stream, initialState: playing);
      await pump(tester);

      final live = fillOf(tester, 0);
      expect(live, greaterThan(0));

      // Stop: the track reports peak 0, but the bar holds its last live fill
      // instead of collapsing.
      current = stopped;
      controller.add(stopped);
      await tester.pump();
      expect(fillOf(tester, 0), live);
    });

    testWidgets('a track with nothing recorded has no bar (height 0)', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()])); // empty, no content
      await pump(tester);

      final box = tester.widget<FractionallySizedBox>(
        find.descendant(
          of: find.byKey(const Key('tracks_tile_0')),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(box.heightFactor, 0.0);
    });

    testWidgets('the meter color is the track state color', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording),
            Track(channel: 1, state: TrackState.playing),
          ],
        ),
      );
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(
          LooperMeterState.recording,
          mode: LooperMode.record,
        ),
      );
      expect(
        barOf(tester, 1).color,
        looper.meterColor(
          LooperMeterState.playing,
          mode: LooperMode.record,
        ),
      );
    });

    testWidgets('play mode uses the play-mode meter table', (tester) async {
      control.toggleMode(); // record -> play
      seed(const LooperState(tracks: [Track(state: TrackState.playing)]));
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(LooperMeterState.playing, mode: LooperMode.play),
      );
    });

    testWidgets('a muted track uses the muted override color', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, muted: true)],
        ),
      );
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(LooperMeterState.muted, mode: LooperMode.record),
      );
    });

    testWidgets('the tile border is white only when selected', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording), // selected + recording
            Track(channel: 1, state: TrackState.playing), // unselected
          ],
        ),
      );
      await pump(tester);

      Color borderColor(int channel) {
        final tile = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(Key('tracks_tile_$channel')),
                matching: find.byType(Container),
              )
              .first,
        );
        return ((tile.decoration! as BoxDecoration).border! as Border)
            .top
            .color;
      }

      expect(borderColor(0), Colors.white); // selected
      expect(borderColor(1), Colors.transparent); // unselected
    });

    testWidgets('track tiles have no glow shadow', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording),
            Track(channel: 1),
          ],
        ),
      );
      await pump(tester);

      final tile = tester.widget<Container>(
        find
            .ancestor(
              of: find.byKey(const Key('tracks_tile_0')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = tile.decoration! as BoxDecoration;
      expect(decoration.boxShadow, anyOf(isNull, isEmpty));
    });
  });

  group('track indicators', () {
    final looper = AppTheme.neon.extension<LooperTheme>()!;

    Color indicatorColorOf(WidgetTester tester, int channel) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(Key('tracks_indicator_$channel')),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    testWidgets('renders one strip per visible tile when the pref is on', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_indicator_1')), findsOneWidget);
    });

    testWidgets('is absent from the tree when the pref is off', (tester) async {
      await tracks.setShowIndicators(value: false);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);
      // The tile itself still renders — only the strip is gone.
      expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    });

    testWidgets('colour reflects the track status', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording), // -> record
            Track(channel: 1, state: TrackState.playing), // -> play
            Track(channel: 2), // empty, unselected -> idle
          ],
        ),
      );
      await pump(tester);

      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.record),
      );
      expect(
        indicatorColorOf(tester, 1),
        looper.indicatorColor(TrackIndicator.play),
      );
      expect(
        indicatorColorOf(tester, 2),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('play mode arms the selected empty tile green', (tester) async {
      control
        ..toggleMode() // record -> play
        ..selectTrack(0);
      seed(const LooperState(tracks: [Track()])); // empty + selected
      await pump(tester);

      // Proves playMode flows from the shared PedalCubit mode into
      // TrackIndicator.of: an empty selected track arms play (green) in play
      // mode, not record (red).
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.play),
      );
    });

    testWidgets('a stopped track that holds a loop is armed to play', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 1000)],
        ),
      );
      await pump(tester);

      // After a stop, a loaded loop stays lit green (armed to play) rather
      // than going dim.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.play),
      );
    });

    testWidgets('a muted track reads as idle', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, muted: true)],
        ),
      );
      await pump(tester);

      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('only the selected tile arms (empty + selected)', (
      tester,
    ) async {
      control.selectTrack(1);
      seed(
        const LooperState(
          tracks: [Track(), Track(channel: 1), Track(channel: 2)],
        ),
      );
      await pump(tester);

      // Record mode by default: the selected empty track arms red, the rest
      // stay idle.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.idle),
      );
      expect(
        indicatorColorOf(tester, 1),
        looper.indicatorColor(TrackIndicator.record),
      );
      expect(
        indicatorColorOf(tester, 2),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('selecting an off-bank channel reveals its bank', (
      tester,
    ) async {
      control.selectTrack(5); // channel in bank B -> selection reveals bank B
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // Bank B is now showing, so the selected channel is visible and armed —
      // a selection can never hide behind the other bank.
      expect(find.byKey(const Key('tracks_tile_5')), findsOneWidget);
      expect(find.byKey(const Key('tracks_tile_0')), findsNothing);
      expect(
        indicatorColorOf(tester, 5),
        looper.indicatorColor(TrackIndicator.record),
      );
    });

    testWidgets('a bank switch reassigns the armed tile', (tester) async {
      control.selectTrack(0);
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // Channel 0 is selected and visible in bank A -> armed.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.record),
      );

      // Switch to bank B and select channel 4.
      await tester.tap(find.byKey(const Key('tracks_bank_1')));
      await tester.pumpAndSettle();
      control.selectTrack(4);
      await tester.pumpAndSettle();

      // The previously-armed tile is no longer in the tree; the newly-selected
      // visible tile arms.
      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);
      expect(
        indicatorColorOf(tester, 4),
        looper.indicatorColor(TrackIndicator.record),
      );
    });

    testWidgets('toggling the pref live-updates without restart', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);

      await tracks.setShowIndicators(value: false);
      await tester.pump();
      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);

      await tracks.setShowIndicators(value: true);
      await tester.pump();
      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);
    });

    testWidgets('carries no semantics of its own (ExcludeSemantics)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track(state: TrackState.recording)]));
      await pump(tester);

      // The strip is wrapped in ExcludeSemantics, so no semantics node is
      // attached to its key — the tile's label remains the only state source.
      expect(
        find.descendant(
          of: find.byKey(const Key('tracks_indicator_0')),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('audio-not-running affordance', () {
    testWidgets('shows when the engine is not connected', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(
        find.byKey(const Key('tracks_audioNotRunning')),
        findsOneWidget,
      );
    });

    testWidgets('is hidden once the engine is connected', (tester) async {
      seed(
        const LooperState(
          tracks: [Track()],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_audioNotRunning')), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('track tile is a labelled button naming its state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final node = tester.getSemantics(
        find.byKey(const Key('tracks_tile_0')),
      );
      // Colour-only meter state (1.4.1) is named in the accessible label, and
      // the tile carries a button role (4.1.2).
      expect(node.label, contains('empty'));
      expect(node, isSemantics(isButton: true));
      handle.dispose();
    });

    testWidgets('a tile exposes a tap action for screen readers (4.1.2)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // The labelled tile must keep a tap semantics action so VoiceOver/
      // TalkBack can activate it (the actual record path is covered by the
      // pointer-tap test above).
      expect(
        tester.getSemantics(find.byKey(const Key('tracks_tile_0'))),
        isSemantics(isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('the bank tab exposes its selected state', (tester) async {
      final handle = tester.ensureSemantics();
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      expect(
        tester.getSemantics(find.byKey(const Key('tracks_bank_0'))),
        isSemantics(isButton: true, isSelected: true),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('tracks_bank_1'))),
        isSemantics(isButton: true, isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('the mode indicator is a labelled toggle button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final node = tester.getSemantics(
        find.byKey(const Key('tracks_mode_indicator')),
      );
      expect(node, isSemantics(isButton: true));
      expect(node.label, isNotEmpty);
      handle.dispose();
    });

    testWidgets('Tab is not swallowed by the tracks key handler', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // The root Focus consumes plain keys (so macOS does not beep) but must
      // let Tab through, or keyboard focus can never reach the tiles (2.1.2).
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      // No exception; the tile targets are focusable.
      expect(find.byType(FocusableTapTarget), findsWidgets);
    });
  });

  group('session menu', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('tracks_session_menu')));
      await tester.pumpAndSettle();
    }

    testWidgets('the menu button is present and carries an accessible name', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // The PopupMenuButton's tooltip is its accessible name (and is itself
      // keyboard-operable + screen-reader announced); operability is covered by
      // the activation tests below.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byKey(const Key('tracks_session_menu')), findsOneWidget);
      expect(find.byTooltip(l10n.a11ySessionMenu), findsOneWidget);
    });

    testWidgets('quick Save writes back through the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('tracks_session_save')));
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('Sessions… refreshes the catalog and opens the manager', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('tracks_session_manage')));
      await tester.pumpAndSettle();
      verify(session.refreshSessions).called(1);
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets('the top bar shows "Unsaved" with no open session', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      final label = tester.widget<Text>(
        find.byKey(const Key('tracks_session_name')),
      );
      expect(label.data, l10n.sessionUnsaved);
    });

    testWidgets('the top bar shows the current session name', (tester) async {
      when(
        () => session.state,
      ).thenReturn(const SessionState(currentSessionName: 'Verse'));
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('tracks_session_name'))).data,
        'Verse',
      );
    });

    testWidgets('Cmd/Ctrl+S writes back through the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('a save-as request opens the name dialog', (tester) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(outcome: SessionOutcome.saveAsRequested),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessionName_field')), findsOneWidget);
    });

    testWidgets('export mixdown / stems invoke the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await openMenu(tester);
      await tester.tap(
        find.byKey(const Key('tracks_session_exportMixdown')),
      );
      await tester.pumpAndSettle();
      verify(() => session.exportMixdown()).called(1);

      await openMenu(tester);
      await tester.tap(find.byKey(const Key('tracks_session_exportStems')));
      await tester.pumpAndSettle();
      verify(() => session.exportStems()).called(1);
    });

    testWidgets('a success outcome surfaces a live-region SnackBar', (
      tester,
    ) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(status: SessionStatus.working),
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.saved,
          ),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump(); // deliver the emitted states

      final handle = tester.ensureSemantics();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.sessionSaved), findsOneWidget);
      // The SnackBar content is wrapped in a live region (WCAG 4.1.3).
      expect(
        tester.getSemantics(find.text(l10n.sessionSaved)),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('a sample-rate mismatch surfaces the localized error', (
      tester,
    ) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(status: SessionStatus.working),
          SessionState(
            status: SessionStatus.failure,
            error: SessionError.sampleRateMismatch,
            errorMessage: 'session sample rate 44100 Hz does not match …',
          ),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.sessionErrorSampleRate), findsOneWidget);
    });
  });

  group('transport controls', () {
    // A connected engine holding recorded audio — the state in which the
    // global transport buttons are live.
    LooperState connected({
      List<Track> tracks = const [
        Track(state: TrackState.stopped, lengthFrames: 100),
      ],
    }) => LooperState(
      tracks: tracks,
      status: const EngineStatus(isConnected: true),
    );

    testWidgets('play/stop all and clear all render', (tester) async {
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_playStopAll')), findsOneWidget);
      expect(find.byKey(const Key('tracks_clearAll')), findsOneWidget);
      // With nothing playing, the toggle shows the play icon.
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('tracks_playStopAll')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.play_arrow);
    });

    testWidgets('play all dispatches when nothing is playing', (tester) async {
      seed(connected());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('the toggle shows stop and stops all when a track is active', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [Track(state: TrackState.playing, lengthFrames: 100)],
        ),
      );
      await pump(tester);

      // Icon flips to stop while a track is active.
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('tracks_playStopAll')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.stop);

      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperStopAllPressed())).called(1);
    });

    for (final state in const [TrackState.recording, TrackState.overdubbing]) {
      testWidgets('the toggle reads "active" while $state', (tester) async {
        seed(connected(tracks: [Track(state: state, lengthFrames: 100)]));
        await pump(tester);

        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('tracks_playStopAll')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.icon, Icons.stop);
      });
    }

    testWidgets('clear all announces to assistive tech', (tester) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        (message) async {
          final data = message! as Map<dynamic, dynamic>;
          if (data['type'] == 'announce') {
            announcements.add(
              (data['data'] as Map<dynamic, dynamic>)['message'] as String,
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler(SystemChannels.accessibility, null),
      );

      seed(connected());
      await pump(tester);
      await tester.tap(find.byKey(const Key('tracks_clearAll')));
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      // The button shares the keyboard path's announcement (anti-drift).
      expect(announcements, contains(l10n.a11yAllCleared));
    });

    testWidgets('clear all dispatches instantly (no dialog)', (tester) async {
      seed(connected());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_clearAll')));
      // Clear-all is a ControlIntents action straight to the engine.
      verify(() => repository.clear()).called(1);
    });

    testWidgets('both are disabled when the engine is disconnected', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('both are disabled when there is no content', (tester) async {
      seed(
        const LooperState(
          tracks: [Track()],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'play is blocked when every loaded track is muted (clear stays on)',
      (tester) async {
        seed(
          connected(
            tracks: const [
              Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
              Track(
                channel: 1,
                state: TrackState.stopped,
                lengthFrames: 100,
                muted: true,
              ),
            ],
          ),
        );
        await pump(tester);

        // Nothing would sound, so Play All is disabled...
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const Key('tracks_playStopAll')),
              )
              .onPressed,
          isNull,
        );
        // ...but Clear All stays available (there is still content to clear).
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('play is allowed when at least one loaded track is unmuted', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 100),
          ],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('stop stays available while a muted track is active', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.playing, lengthFrames: 100, muted: true),
          ],
        ),
      );
      await pump(tester);

      // A muted but active track can still be stopped.
      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperStopAllPressed())).called(1);
    });

    testWidgets('Space is a no-op when every loaded track is muted', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
          ],
        ),
      );
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      verifyNever(() => bloc.add(const LooperPlayAllPressed()));
    });

    testWidgets('fullscreen button renders on desktop and is tappable', (
      tester,
    ) async {
      // Reset inline (not via addTearDown): the foundation-var invariant check
      // runs at the end of the test body, before tearDown callbacks.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_fullscreen')), findsOneWidget);
      // The helper swallows the missing platform channel in tests.
      await tester.tap(find.byKey(const Key('tracks_fullscreen')));
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('fullscreen button is absent off desktop windowing', (
      tester,
    ) async {
      // A mobile target stands in for "not desktop windowing" (the gate also
      // hides the button on web).
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_fullscreen')), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('per-track undo/redo', () {
    testWidgets('appear only on the selected column', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(lengthFrames: 100, state: TrackState.stopped),
            Track(channel: 1, lengthFrames: 100, state: TrackState.stopped),
          ],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_undo_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_redo_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_undo_1')), findsNothing);
      expect(find.byKey(const Key('tracks_redo_1')), findsNothing);
    });

    testWidgets('undo dispatches for the selected channel', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_undo_0')));
      verify(() => bloc.add(const LooperUndoPressed(0))).called(1);
    });

    testWidgets('undo is disabled when the track has no content', (
      tester,
    ) async {
      control.selectTrack(0);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_undo_0')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('redo is disabled with no redo history', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_redo_0')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('redo dispatches when a layer can be redone', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(lengthFrames: 100, state: TrackState.stopped, redoDepth: 1),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_redo_0')));
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
    });

    testWidgets('the tooltips name the macOS shortcut', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byTooltip(l10n.undoTooltip('⌘Z')), findsOneWidget);
      expect(find.byTooltip(l10n.redoTooltip('⌘⇧Z')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the tooltips use Ctrl off macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byTooltip(l10n.undoTooltip('Ctrl+Z')), findsOneWidget);
      expect(find.byTooltip(l10n.redoTooltip('Ctrl+Y')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('keyboard refactor parity', () {
    testWidgets('U undoes the selected track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.pump();
      verify(() => bloc.add(const LooperUndoPressed(1))).called(1);
    });

    testWidgets('Ctrl+Y redoes the selected track', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
    });

    testWidgets('Cmd/Ctrl+Z undoes and Cmd/Ctrl+Shift+Z redoes', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      verify(() => bloc.add(const LooperUndoPressed(0))).called(1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });
}
