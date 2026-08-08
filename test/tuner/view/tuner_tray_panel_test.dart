import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/tuner/pitch.dart';
import 'package:segno/tuner/view/tuner_tray_panel.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The face's cubit, driven directly.
///
/// The real [TunerCubit] earns its own tests; what this file is for is the
/// face, and pushing a reading through a repository stream to get one on
/// screen would test the wiring twice and the drawing once. Feeding states
/// straight in puts the face in a state and lets it draw.
class _MockTunerCubit extends MockCubit<TunerState> implements TunerCubit {}

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;
  late SettingsRepository settings;
  late _MockTunerCubit tuner;
  late StreamController<TunerState> readings;
  late InputsCubit inputs;

  /// A rig with [channels] inputs open, which is what puts the face past its
  /// "No audio device" branch and into everything this file exists to cover.
  LooperState rig({int channels = 2, int excluded = 0}) => LooperState(
    status: EngineStatus(
      inputChannels: channels,
      excludedInputMask: excluded,
      deviceName: 'Fake',
    ),
  );

  /// A reading of [hz], resolved the same way the real cubit resolves one.
  TunerState heard(double hz, {bool isStale = false}) => TunerState(
    isOpen: true,
    hz: hz,
    pitch: pitchFromHz(hz),
    isStale: isStale,
  );

  setUp(() {
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast();
    settings = SettingsRepository(store: FakeKeyValueStore());
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(rig());
    tuner = _MockTunerCubit();
    readings = StreamController<TunerState>.broadcast();
    whenListen(
      tuner,
      readings.stream,
      initialState: const TunerState(isOpen: true),
    );
    inputs = InputsCubit(settings: settings, repository: repository);
  });

  tearDown(() async {
    await inputs.close();
    await readings.close();
    await states.close();
  });

  Future<void> pump(WidgetTester tester, {int channels = 2, int excluded = 0}) {
    when(
      () => repository.state,
    ).thenReturn(rig(channels: channels, excluded: excluded));
    // Unmount before the outer tearDown closes the cubits: the face disarms in
    // `dispose`, and emitting into a closed cubit throws. In the app the cubit
    // is provided ABOVE this face, so the face always unmounts first — the
    // harness has to reproduce that order rather than invert it.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TunerCubit>.value(value: tuner),
              BlocProvider<InputsCubit>.value(value: inputs),
            ],
            child: Scaffold(body: TunerTrayPanel(onBack: () {})),
          ),
        ),
      ),
    );
  }

  /// Puts the face in [next] and lets the frame it schedules land.
  Future<void> draw(WidgetTester tester, TunerState next) async {
    readings.add(next);
    await tester.pumpAndSettle();
  }

  /// Where the needle's centre sits, in global pixels.
  double needleX(WidgetTester tester) =>
      tester.getCenter(find.byKey(const Key('tuner_needle'))).dx;

  Text noteText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('tuner_note')));

  Text centsText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('tuner_cents')));

  group('TunerTrayPanel', () {
    testWidgets('arms on show and disarms on hide', (tester) async {
      await pump(tester);
      verify(() => tuner.arm()).called(1);
      verifyNever(() => tuner.disarm());

      await tester.pumpWidget(const SizedBox.shrink());
      verify(() => tuner.disarm()).called(1);
    });

    testWidgets('offers a tab per hardware input and switches on tap', (
      tester,
    ) async {
      await pump(tester, channels: 3);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byType(PillTabs<int>), findsOneWidget);
      for (var input = 0; input < 3; input++) {
        expect(find.text(l10n.inputName(const {}, input)), findsOneWidget);
      }

      // The second pill is input 1 — the strip is zero-based, the label is not.
      await tester.tap(find.text(l10n.inputName(const {}, 1)));
      await tester.pumpAndSettle();

      verify(() => tuner.selectInput(1)).called(1);
    });

    testWidgets('says it is listening until a note arrives', (tester) async {
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(l10n.tunerListening), findsOneWidget);
      expect(find.byKey(const Key('tuner_readout')), findsNothing);

      await draw(tester, heard(110));

      expect(find.byKey(const Key('tuner_readout')), findsOneWidget);
      expect(noteText(tester).data, 'A');
    });

    testWidgets('writes cents with a real minus and an explicit plus', (
      tester,
    ) async {
      await pump(tester);

      // A4 a touch sharp: +8 cents, which the readout signs explicitly.
      await draw(tester, heard(442.1));
      expect(centsText(tester).data, startsWith('+8'));

      // E3 flat: the sign is U+2212 MINUS SIGN, not an ASCII hyphen. 163.94
      // rather than a flat 163.9 for the reason `pitch_test.dart` spells out —
      // the band that both prints as 163.9 and rounds to −9 cents is narrow,
      // and 163.9 itself sits just outside it at −9.6.
      await draw(tester, heard(163.94));
      expect(centsText(tester).data, startsWith('−9'));
      expect(centsText(tester).data, isNot(contains('-')));

      // Dead on reads bare, with no sign at all.
      await draw(tester, heard(440));
      expect(centsText(tester).data, startsWith('0 '));
    });

    testWidgets('slides the needle with the error, right of centre when '
        'sharp and left when flat', (tester) async {
      await pump(tester);

      await draw(tester, heard(440));
      final centre = needleX(tester);

      await draw(tester, heard(449));
      expect(needleX(tester), greaterThan(centre));

      await draw(tester, heard(431));
      expect(needleX(tester), lessThan(centre));
    });

    testWidgets('softens the note while the reading is held', (tester) async {
      await pump(tester);
      final surface = tester.element(find.byType(TunerTrayPanel)).surface;

      await draw(tester, heard(110));
      expect(noteText(tester).style!.color, surface.textPrimary);

      // Same note, but nothing fresh behind it: drawn as held, not as a lie.
      await draw(tester, heard(110, isStale: true));
      expect(noteText(tester).style!.color, surface.textSecondary);

      // And once the cubit lets go there is nothing to draw a needle for.
      await draw(tester, const TunerState(isOpen: true));
      expect(find.byKey(const Key('tuner_readout')), findsNothing);
    });

    testWidgets('never offers a loopback capture, which carries the '
        "console's own output rather than an instrument", (tester) async {
      // A Scarlett-class rig: four captures, the last pair being "Loop 1/2".
      await pump(tester, channels: 4, excluded: 0xC);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(l10n.inputName(const {}, 0)), findsOneWidget);
      expect(find.text(l10n.inputName(const {}, 1)), findsOneWidget);
      expect(find.text(l10n.inputName(const {}, 2)), findsNothing);
      expect(find.text(l10n.inputName(const {}, 3)), findsNothing);
    });

    testWidgets('says there is nothing to tune when a device is open but '
        'every capture on it is a loopback', (tester) async {
      await pump(tester, excluded: 0x3);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // A device IS open, so neither of the other two messages would be true.
      expect(find.text(l10n.tunerNoTunableInput), findsOneWidget);
      expect(find.text(l10n.tunerNoDevice), findsNothing);
      expect(find.text(l10n.tunerListening), findsNothing);
      expect(find.byType(PillTabs<int>), findsNothing);
    });

    testWidgets('says there is no device when none is open', (tester) async {
      await pump(tester, channels: 0);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(l10n.tunerNoDevice), findsOneWidget);
      expect(find.byType(PillTabs<int>), findsNothing);
    });
  });
}
