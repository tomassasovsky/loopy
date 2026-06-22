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
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';
import '../../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

void main() {
  late LooperBloc bloc;
  late BigPictureCubit bigPicture;
  late BankCubit bank;
  late LooperRepository repository;
  late SettingsRepository settings;
  late PedalCubit pedal;
  late StreamController<LooperState> looperStates;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    bigPicture = BigPictureCubit(settings: settings);
    bank = BankCubit();
    repository = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
    pedal = PedalCubit(
      pedal: PedalRepository(FakePedalTransport()),
      looper: repository,
      settings: settings,
      pollInterval: Duration.zero,
    );
  });

  tearDown(() async {
    await looperStates.close();
    await pedal.close();
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    looperStates.add(state);
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
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
              BlocProvider<PedalCubit>.value(value: pedal),
            ],
            child: const BigPictureView(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

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

  group('pedal LED bar emulation', () {
    final looper = AppTheme.bigPicture.extension<LooperTheme>()!;

    DecoratedBox ledBarOf(WidgetTester tester, int channel) =>
        tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(Key('bigpicture_led_bar_$channel')),
            matching: find.byType(DecoratedBox),
          ),
        );

    testWidgets('shows below the name when pedal output is not bound', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('bigpicture_led_bar_0')), findsOneWidget);
    });

    testWidgets('is hidden when pedal LED feedback is bound', (tester) async {
      final mockPedal = _MockPedalCubit();
      when(() => mockPedal.state).thenReturn(
        const PedalState(bindStatus: PedalBindStatus.bound),
      );
      when(() => mockPedal.trackLedFor(any())).thenReturn(PedalTrackLed.off);
      whenListen(
        mockPedal,
        const Stream<PedalState>.empty(),
        initialState: const PedalState(bindStatus: PedalBindStatus.bound),
      );

      seed(const LooperState(tracks: [Track()]));
      await tester.pumpWidget(
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
                BlocProvider<PedalCubit>.value(value: mockPedal),
              ],
              child: const BigPictureView(),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('bigpicture_led_bar_0')), findsNothing);
    });

    testWidgets('armed track shows red in record mode', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      pedal.armTrack(1);
      await pump(tester);

      final decoration = ledBarOf(tester, 1).decoration as BoxDecoration;
      expect(decoration.color, looper.pedalLedColor(PedalTrackLed.red));
    });

    testWidgets('capturing track shows red even when not armed', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, state: TrackState.recording),
          ],
        ),
      );
      await pump(tester);
      await tester.pump();

      final decoration = ledBarOf(tester, 1).decoration as BoxDecoration;
      expect(decoration.color, looper.pedalLedColor(PedalTrackLed.red));
    });
  });
}
