import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockUiModeCubit extends MockCubit<UiMode> implements UiModeCubit {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late LooperBloc bloc;
  late UiModeCubit uiMode;
  late BigPictureCubit bigPicture;
  late BankCubit bank;
  late LooperRepository repository;
  late SettingsRepository settings;

  setUpAll(() => registerFallbackValue(UiMode.desktop));

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    uiMode = _MockUiModeCubit();
    bigPicture = BigPictureCubit(settings: settings);
    bank = BankCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    whenListen(
      uiMode,
      const Stream<UiMode>.empty(),
      initialState: UiMode.bigPicture,
    );
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester, {ThemeData? theme}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: theme ?? AppTheme.bigPicture,
          home: RepositoryProvider<LooperRepository>.value(
            value: repository,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<LooperBloc>.value(value: bloc),
                BlocProvider<UiModeCubit>.value(value: uiMode),
                BlocProvider<BigPictureCubit>.value(value: bigPicture),
                BlocProvider<BankCubit>.value(value: bank),
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

  testWidgets('with the bank enabled, shows one bank and switches A/B', (
    tester,
  ) async {
    await bank.setEnabled(value: true);
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
    final desktop = AppTheme.desktop;
    final looper = desktop.extension<LooperTheme>()!;

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

    testWidgets('an idle track still shows a sliver', (tester) async {
      seed(const LooperState(tracks: [Track()])); // empty, peak 0
      await pump(tester);

      final box = tester.widget<FractionallySizedBox>(
        find.descendant(
          of: find.byKey(const Key('bigpicture_tile_0')),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(box.heightFactor, closeTo(0.01, 1e-9));
    });

    testWidgets('the selected track meter is the play color', (tester) async {
      bigPicture.select(0);
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester, theme: desktop);
      expect(barOf(tester, 0).color, looper.playColor);
    });

    testWidgets('an unselected idle track uses the track accent', (
      tester,
    ) async {
      bigPicture.select(0);
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester, theme: desktop);
      expect(barOf(tester, 1).color, looper.trackColor(1));
    });

    testWidgets('a muted track meter is white', (tester) async {
      bigPicture.select(0);
      seed(
        const LooperState(
          tracks: [Track(), Track(channel: 1, muted: true)],
        ),
      );
      await pump(tester, theme: desktop);
      expect(barOf(tester, 1).color, looper.mutedColor);
    });

    testWidgets('a recording track meter is the record color', (tester) async {
      bigPicture.select(0);
      seed(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, state: TrackState.recording),
          ],
        ),
      );
      await pump(tester, theme: desktop);
      expect(barOf(tester, 1).color, looper.recordColor);
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
}
