import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late TempoCubit cubit;

  setUpAll(() {
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
  });

  setUp(() {
    bloc = _MockLooperBloc();
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
      () => when(
        () => repository.setCountIn(any()),
      ).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
    settings = SettingsRepository(store: FakeKeyValueStore());
    cubit = TempoCubit(repository: repository, settings: settings);
  });

  void seed(TransportState transport, {int outputChannels = 2}) {
    final state = LooperState(
      transport: transport,
      status: EngineStatus(outputChannels: outputChannels),
    );
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<TempoCubit>.value(value: cubit),
        ],
        child: const Scaffold(
          body: SingleChildScrollView(child: TempoSettingsSection()),
        ),
      ),
    ),
  );

  group('BPM control', () {
    testWidgets('shows the live effective tempo as the helper text', (
      tester,
    ) async {
      seed(
        const TransportState(tempoBpm: 128, tempoSource: TempoSource.manual),
      );
      await pump(tester);

      expect(find.text('128.0 BPM'), findsOneWidget);
    });

    testWidgets('shows "not set" before any tempo is established', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      expect(find.text('Not set'), findsOneWidget);
    });

    testWidgets('applying a typed BPM calls TempoCubit.setTempo', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      await tester.enterText(
        find.byKey(const Key('tempoSettings_bpm_field')),
        '140',
      );
      await tester.tap(find.byKey(const Key('tempoSettings_bpm_apply')));
      await tester.pumpAndSettle();

      expect(cubit.state.bpm, 140);
      expect(await settings.loadTempoBpm(), 140);
      verify(() => repository.setTempo(140)).called(1);
    });

    testWidgets('the tap button calls repository.tapTempo', (tester) async {
      seed(const TransportState());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tempoSettings_tap_button')));
      await tester.pumpAndSettle();

      verify(repository.tapTempo).called(1);
    });

    testWidgets('submitting the field (Enter/Done) also applies it', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      await tester.enterText(
        find.byKey(const Key('tempoSettings_bpm_field')),
        '90',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verify(() => repository.setTempo(90)).called(1);
    });

    testWidgets(
      'reflects a live BPM change (e.g. a pedal tap) while unfocused',
      (tester) async {
        // A real controller-backed stream (unlike `seed`'s empty one) so a
        // pushed state actually reaches `context.watch` and rebuilds the
        // field — exercising `_BpmControl.didUpdateWidget`.
        final controller = StreamController<LooperState>.broadcast();
        addTearDown(controller.close);
        const initial = LooperState(
          transport: TransportState(
            tempoBpm: 100,
            tempoSource: TempoSource.manual,
          ),
        );
        when(() => bloc.state).thenReturn(initial);
        whenListen(bloc, controller.stream, initialState: initial);
        await pump(tester);
        expect(find.text('100.0 BPM'), findsOneWidget);

        const updated = LooperState(
          transport: TransportState(
            tempoBpm: 132,
            tempoSource: TempoSource.tapped,
          ),
        );
        when(() => bloc.state).thenReturn(updated);
        controller.add(updated);
        await tester.pump();

        expect(find.text('132.0 BPM'), findsOneWidget);
      },
    );
  });

  group('time signature picker', () {
    testWidgets('shows only the 6 quarter-note signatures for /4', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      expect(find.byKey(const Key('tempoSettings_ts_4_4')), findsOneWidget);
      expect(find.byKey(const Key('tempoSettings_ts_7_4')), findsOneWidget);
      expect(find.byKey(const Key('tempoSettings_ts_5_8')), findsNothing);
    });

    testWidgets(
      'switching to /8 applies the smallest valid /8 signature (5/8)',
      (tester) async {
        // The chip wrap re-renders from LooperBloc's live TransportState
        // (see TempoSettingsSection's class doc), which this mocked bloc
        // does not auto-update — so this asserts the applied call, not a
        // visual chip-set change (covered structurally by the "/4 shows
        // only the 6 quarter-note signatures" test above).
        seed(const TransportState());
        await pump(tester);

        await tester.tap(find.byKey(const Key('tempoSettings_tsDen_8')));
        await tester.pumpAndSettle();

        verify(() => repository.setTimeSignature(5, 8)).called(1);
      },
    );

    testWidgets(
      'switching denominator keeps a numerator still valid in both ranges',
      (tester) async {
        // 7 is valid for both /4 (2-7) and /8 (5-15), so switching to /8
        // keeps it rather than falling back to the smallest (5).
        seed(const TransportState(tsNum: 7));
        await pump(tester);

        await tester.tap(find.byKey(const Key('tempoSettings_tsDen_8')));
        await tester.pumpAndSettle();

        verify(() => repository.setTimeSignature(7, 8)).called(1);
      },
    );

    testWidgets('tapping a numerator chip applies that signature', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tempoSettings_ts_7_4')));
      await tester.pumpAndSettle();

      expect(cubit.state, const TempoSettings(tsNum: 7));
      verify(() => repository.setTimeSignature(7, 4)).called(1);
    });
  });

  testWidgets('the sync-tempo toggle applies and persists the new value', (
    tester,
  ) async {
    seed(const TransportState());
    await pump(tester);

    await tester.tap(find.byKey(const Key('tempoSettings_sync_switch')));
    await tester.pumpAndSettle();

    expect(cubit.state.syncTempo, isFalse);
    verify(() => repository.setSyncTempo(on: false)).called(1);
  });

  group('quantize granularity picker', () {
    testWidgets('selecting a division applies it', (tester) async {
      seed(const TransportState());
      await pump(tester);

      final option = find.byKey(
        const Key('tempoSettings_quantizeDiv_quarter'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();

      expect(cubit.state.quantizeDiv, GridDivision.quarter);
      verify(() => repository.setQuantizeDiv(GridDivision.quarter)).called(1);
    });
  });

  group('click settings', () {
    testWidgets('selecting a click mode applies it', (tester) async {
      seed(const TransportState());
      await pump(tester);

      final option = find.byKey(const Key('tempoSettings_clickMode_rec'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();

      expect(cubit.state.clickMode, ClickMode.rec);
      verify(() => repository.setClickMode(ClickMode.rec)).called(1);
    });

    testWidgets('toggling an output chip applies the new mask', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      final chip = find.byKey(const Key('tempoSettings_clickOutput_0'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(cubit.state.clickOutputMask, 0x1);
      verify(() => repository.setClickOutput(0x1)).called(1);
    });

    testWidgets('dragging the volume slider applies the new value', (
      tester,
    ) async {
      seed(const TransportState());
      await pump(tester);

      final slider = find.byKey(
        const Key('tempoSettings_clickVolume_slider'),
      );
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      // Dragging right from the current (0) position raises the value; a
      // drag fires onChanged more than once (start + move), so this only
      // asserts it fired at all.
      await tester.drag(slider, const Offset(50, 0));
      await tester.pumpAndSettle();

      verify(() => repository.setClickVolume(any())).called(greaterThan(0));
    });
  });

  group('count-in picker', () {
    testWidgets('selecting a count-in length applies it', (tester) async {
      seed(const TransportState());
      await pump(tester);

      final option = find.byKey(const Key('tempoSettings_countIn_2'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();

      expect(cubit.state.countInBars, 2);
      verify(() => repository.setCountIn(2)).called(1);
    });
  });
}
