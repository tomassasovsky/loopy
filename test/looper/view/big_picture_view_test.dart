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
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    bigPicture = BigPictureCubit(settings: settings);
    bank = BankCubit();
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

  testWidgets('tapping a tile records that channel', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('bigpicture_tile_1')));
    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
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
