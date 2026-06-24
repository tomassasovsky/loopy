import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
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
  late BigPictureCubit bigPicture;
  late BankCubit bank;
  late TrackIndicatorsCubit trackIndicators;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    bigPicture = BigPictureCubit(settings: settings);
    bank = BankCubit();
    trackIndicators = TrackIndicatorsCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    when(() => session.saveSession()).thenAnswer((_) async {});
    when(() => session.loadSession()).thenAnswer((_) async {});
    when(() => session.exportMixdown()).thenAnswer((_) async {});
    when(() => session.exportStems()).thenAnswer((_) async {});
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.bigPicture,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<BigPictureCubit>.value(value: bigPicture),
            BlocProvider<BankCubit>.value(value: bank),
            BlocProvider<TrackIndicatorsCubit>.value(value: trackIndicators),
            BlocProvider<SessionCubit>.value(value: session),
          ],
          child: const BigPictureView(),
        ),
      ),
    ),
  );

  testWidgets('renders a tile per track', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    expect(find.byKey(const Key('bigpicture_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_1')), findsOneWidget);
  });

  testWidgets('exposes a visible entry to the Signal surface', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    // The chrome carries one global affordance opening the Signal surface
    // (the per-track routing dialog is gone — wiring lives on Signal now).
    expect(find.byKey(const Key('bigpicture_openSignal')), findsOneWidget);
  });

  testWidgets('tapping a tile records that channel in record mode', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('bigpicture_tile_1')));
    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
  });

  testWidgets('tapping a tile mutes/unmutes that channel in play mode', (
    tester,
  ) async {
    bigPicture.toggleMode(); // record -> play
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('bigpicture_tile_1')));
    // Mirrors the play-mode number-key behavior; does not arm recording.
    verify(() => bloc.add(const LooperMuteToggled(1))).called(1);
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    // The tap also selects the tapped channel.
    expect(bigPicture.state.selectedChannel, 1);
  });

  testWidgets('long-pressing a tile stops that channel', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.longPress(find.byKey(const Key('bigpicture_tile_0')));
    verify(() => bloc.add(const LooperStopPressed(0))).called(1);
  });

  testWidgets('shows one bank of four and switches A/B', (tester) async {
    seed(
      LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
    );
    await pump(tester);

    // Bank A shows channels 0-3 only.
    expect(find.byKey(const Key('bigpicture_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_3')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_4')), findsNothing);

    // Switch to bank B -> channels 4-7.
    await tester.tap(find.byKey(const Key('bigpicture_bank_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bigpicture_tile_4')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_7')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_0')), findsNothing);
  });

  group('keyboard', () {
    testWidgets('M toggles the performance mode', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(bigPicture.state.mode, PerformanceMode.record);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(bigPicture.state.mode, PerformanceMode.play);
    });

    testWidgets('a number key selects that track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(bigPicture.state.selectedChannel, 1);
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
      expect(bigPicture.state.selectedChannel, 0);
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
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      verify(() => bloc.add(const LooperClearAllPressed())).called(1);
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

    await tester.tap(find.byKey(const Key('bigpicture_name_0')));
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
    final looper = AppTheme.bigPicture.extension<LooperTheme>()!;

    // The meter Container inside a track tile (the _PeakBar's fill).
    Container barOf(WidgetTester tester, int channel) =>
        tester
                .widget<FractionallySizedBox>(
                  find.descendant(
                    of: find.byKey(Key('bigpicture_tile_$channel')),
                    matching: find.byType(FractionallySizedBox),
                  ),
                )
                .child!
            as Container;

    // The meter fill fraction (the _PeakBar's height factor) for a tile.
    double fillOf(WidgetTester tester, int channel) => tester
        .widget<FractionallySizedBox>(
          find.descendant(
            of: find.byKey(Key('bigpicture_tile_$channel')),
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
          of: find.byKey(const Key('bigpicture_tile_0')),
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
        looper.meterColor(LooperMeterState.recording, playMode: false),
      );
      expect(
        barOf(tester, 1).color,
        looper.meterColor(LooperMeterState.playing, playMode: false),
      );
    });

    testWidgets('play mode uses the play-mode meter table', (tester) async {
      bigPicture.toggleMode(); // record -> play
      seed(const LooperState(tracks: [Track(state: TrackState.playing)]));
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(LooperMeterState.playing, playMode: true),
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
        looper.meterColor(LooperMeterState.muted, playMode: false),
      );
    });

    testWidgets('the tile border is white only when selected', (tester) async {
      bigPicture.select(0);
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
                of: find.byKey(Key('bigpicture_tile_$channel')),
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
              of: find.byKey(const Key('bigpicture_tile_0')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = tile.decoration! as BoxDecoration;
      expect(decoration.boxShadow, anyOf(isNull, isEmpty));
    });
  });

  group('track indicators', () {
    final looper = AppTheme.bigPicture.extension<LooperTheme>()!;

    Color indicatorColorOf(WidgetTester tester, int channel) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(Key('bigpicture_indicator_$channel')),
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

      expect(
        find.byKey(const Key('bigpicture_indicator_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('bigpicture_indicator_1')),
        findsOneWidget,
      );
    });

    testWidgets('is absent from the tree when the pref is off', (tester) async {
      await trackIndicators.setEnabled(value: false);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('bigpicture_indicator_0')), findsNothing);
      // The tile itself still renders — only the strip is gone.
      expect(find.byKey(const Key('bigpicture_tile_0')), findsOneWidget);
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

    testWidgets('play mode arms the selected empty tile green', (
      tester,
    ) async {
      bigPicture
        ..toggleMode() // record -> play
        ..select(0);
      seed(const LooperState(tracks: [Track()])); // empty + selected
      await pump(tester);

      // Proves playMode flows from BigPictureCubit.state.mode into
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
      bigPicture.select(1);
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

    testWidgets('selecting an off-bank channel arms no visible tile', (
      tester,
    ) async {
      bigPicture.select(5); // channel in bank B, not visible in bank A
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // Bank A (0-3) is showing; none of them is the selected channel.
      for (var channel = 0; channel < 4; channel++) {
        expect(
          indicatorColorOf(tester, channel),
          looper.indicatorColor(TrackIndicator.idle),
        );
      }
    });

    testWidgets('a bank switch reassigns the armed tile', (tester) async {
      bigPicture.select(0);
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
      await tester.tap(find.byKey(const Key('bigpicture_bank_1')));
      await tester.pumpAndSettle();
      bigPicture.select(4);
      await tester.pumpAndSettle();

      // The previously-armed tile is no longer in the tree; the newly-selected
      // visible tile arms.
      expect(find.byKey(const Key('bigpicture_indicator_0')), findsNothing);
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
      expect(
        find.byKey(const Key('bigpicture_indicator_0')),
        findsOneWidget,
      );

      await trackIndicators.setEnabled(value: false);
      await tester.pump();
      expect(find.byKey(const Key('bigpicture_indicator_0')), findsNothing);

      await trackIndicators.setEnabled(value: true);
      await tester.pump();
      expect(
        find.byKey(const Key('bigpicture_indicator_0')),
        findsOneWidget,
      );
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
          of: find.byKey(const Key('bigpicture_indicator_0')),
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
        find.byKey(const Key('bigpicture_audioNotRunning')),
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

      expect(
        find.byKey(const Key('bigpicture_audioNotRunning')),
        findsNothing,
      );
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
        find.byKey(const Key('bigpicture_tile_0')),
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
        tester.getSemantics(find.byKey(const Key('bigpicture_tile_0'))),
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
        tester.getSemantics(find.byKey(const Key('bigpicture_bank_0'))),
        isSemantics(isButton: true, isSelected: true),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('bigpicture_bank_1'))),
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
        find.byKey(const Key('bigpicture_mode_indicator')),
      );
      expect(node, isSemantics(isButton: true));
      expect(node.label, isNotEmpty);
      handle.dispose();
    });

    testWidgets('Tab is not swallowed by the performance key handler', (
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
      await tester.tap(find.byKey(const Key('bigpicture_session_menu')));
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
      expect(find.byKey(const Key('bigpicture_session_menu')), findsOneWidget);
      expect(find.byTooltip(l10n.a11ySessionMenu), findsOneWidget);
    });

    testWidgets('save invokes the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('bigpicture_session_save')));
      await tester.pumpAndSettle();
      verify(() => session.saveSession()).called(1);
    });

    testWidgets('load invokes the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('bigpicture_session_load')));
      await tester.pumpAndSettle();
      verify(() => session.loadSession()).called(1);
    });

    testWidgets('export mixdown / stems invoke the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await openMenu(tester);
      await tester.tap(
        find.byKey(const Key('bigpicture_session_exportMixdown')),
      );
      await tester.pumpAndSettle();
      verify(() => session.exportMixdown()).called(1);

      await openMenu(tester);
      await tester.tap(find.byKey(const Key('bigpicture_session_exportStems')));
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
}
