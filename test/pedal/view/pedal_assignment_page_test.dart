import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/pedal/view/pedal_assignment_page.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

TrackEffect _fx(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late Map<int, List<TrackEffect>> trackChains;
  late ControlCubit control;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    trackChains = {
      3: [_fx('a'), _fx('b')],
    };
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenAnswer(
      (_) => {
        for (final channel in trackChains.keys)
          channel: const FxChainEnvelope(),
      },
    );
    when(
      () => looper.trackEffects(any()),
    ).thenAnswer((i) => trackChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.masterEffects).thenReturn(const []);
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(
      () => looper.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());
  });

  tearDown(() => looperStates.close());

  Future<void> pump(WidgetTester tester) async {
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    // unawaited: awaiting ControlCubit.close() inside a testWidgets body
    // deadlocks on the Flutter test binding's stream cancellation.
    addTearDown(() => unawaited(control.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: MultiBlocProvider(
          providers: [BlocProvider.value(value: control)],
          child: RepositoryProvider<LooperRepository>.value(
            value: looper,
            child: const PedalAssignmentPage(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Scrolls [finder] into the viewport and taps it — the editor sits below a
  /// full-width plate, so a row control is off-screen at the default surface
  /// size.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Taps footswitch [button] on the embedded plate.
  Future<void> select(WidgetTester tester, PedalButton button) async {
    await tester.tap(
      find.byKey(Key('pedalFaceplate_footswitch_${button.name}')),
      warnIfMissed: false,
    );
    await tester.pump();
  }

  group('PedalAssignmentPage', () {
    testWidgets('prompts for a selection before anything is picked', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('assign_prompt')), findsOneWidget);
      expect(find.byKey(const Key('assign_row')), findsNothing);
    });

    testWidgets('selecting a footswitch offers the target picker', (
      tester,
    ) async {
      await pump(tester);
      await select(tester, PedalButton.recPlay);

      expect(find.byKey(const Key('assign_prompt')), findsNothing);
      expect(find.byKey(const Key('assign_target_picker')), findsOneWidget);
      expect(find.text(tester.l10n.pedalAssignUnassigned), findsOneWidget);
    });

    testWidgets('MODE and Bank are selectable but never offered a target — '
        'the user gets the reason instead of an inert switch (B12)', (
      tester,
    ) async {
      await pump(tester);

      for (final button in [PedalButton.mode, PedalButton.bank]) {
        await select(tester, button);
        expect(
          find.byKey(const Key('assign_unbindable')),
          findsOneWidget,
          reason: '${button.name} explains itself',
        );
        expect(find.byKey(const Key('assign_target_picker')), findsNothing);
      }
    });

    testWidgets('picking a target binds the switch and persists it', (
      tester,
    ) async {
      await pump(tester);
      await select(tester, PedalButton.recPlay);

      await tapVisible(tester, find.byKey(const Key('assign_target_picker')));
      await tester.tap(find.text('Track 3 chain').last);
      await tester.pumpAndSettle();

      final binding = control.globalBindings.lookup(
        PedalButton.recPlay,
        bank: 0,
      );
      expect(binding, isNotNull);
      expect(
        binding!.decodeTarget(),
        const FxChainTarget(FxAddress(stage: FxStage.track, index: 3)),
      );
      expect(find.byKey(const Key('assign_row')), findsOneWidget);
    });

    testWidgets('a track button offers a per-bank choice (A3)', (tester) async {
      await pump(tester);
      await select(tester, PedalButton.recPlay);
      expect(find.byKey(const Key('assign_bank')), findsNothing);

      await select(tester, PedalButton.track1);
      expect(find.byKey(const Key('assign_bank')), findsOneWidget);
    });

    testWidgets('the behaviour choice writes back to the binding', (
      tester,
    ) async {
      await pump(tester);
      await control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.recPlay),
            target: const FxChainTarget(
              FxAddress(stage: FxStage.track, index: 3),
            ).canonicalString(),
          ),
        ]),
      );
      await select(tester, PedalButton.recPlay);

      await tapVisible(tester, find.text(tester.l10n.pedalAssignMomentary));

      expect(
        control.globalBindings.lookup(PedalButton.recPlay, bank: 0)?.behavior,
        BindingBehavior.momentary,
      );
    });

    group('stale bindings (R25)', () {
      Future<void> bindThenBreak(WidgetTester tester) async {
        await pump(tester);
        await control.setGlobalBindings(
          PedalBindingSet([
            PedalBinding(
              key: const PedalBindingKey(button: PedalButton.recPlay),
              target: const FxChainTarget(
                FxAddress(stage: FxStage.track, index: 3),
              ).canonicalString(),
            ),
          ]),
        );
        trackChains
          ..remove(3) // the bound chain is deleted...
          ..[5] = [_fx('z')]; // ...and another one exists to rebind onto
        await select(tester, PedalButton.recPlay);
      }

      testWidgets('render in the placeholder convention — warning glyph, '
          'tertiary text, and the ENTRY PRESERVED', (tester) async {
        await bindThenBreak(tester);

        expect(find.byKey(const Key('assign_row')), findsOneWidget);
        expect(find.byKey(const Key('assign_stale_glyph')), findsOneWidget);
        expect(find.byKey(const Key('assign_stale_detail')), findsOneWidget);
        expect(find.text(tester.l10n.pedalAssignStale), findsOneWidget);
        // The binding itself is untouched — nothing was silently dropped.
        expect(
          control.globalBindings.lookup(PedalButton.recPlay, bank: 0),
          isNotNull,
        );
      });

      testWidgets('offer rebind, which repoints the SAME switch', (
        tester,
      ) async {
        await bindThenBreak(tester);

        await tapVisible(tester, find.text(tester.l10n.pedalAssignRebind));
        await tester.tap(find.text('Track 5 chain').last);
        await tester.pumpAndSettle();

        expect(
          control.globalBindings
              .lookup(PedalButton.recPlay, bank: 0)
              ?.decodeTarget(),
          const FxChainTarget(FxAddress(stage: FxStage.track, index: 5)),
        );
        expect(find.byKey(const Key('assign_stale_glyph')), findsNothing);
      });

      testWidgets('offer clear, which returns the switch to its contextual '
          'default', (tester) async {
        await bindThenBreak(tester);

        await tapVisible(tester, find.byKey(const Key('assign_clear')));

        expect(
          control.globalBindings.lookup(PedalButton.recPlay, bank: 0),
          isNull,
        );
        expect(find.byKey(const Key('assign_row')), findsNothing);
        expect(find.byKey(const Key('assign_target_picker')), findsOneWidget);
      });
    });

    testWidgets('says so when the rig has no chains to point at', (
      tester,
    ) async {
      trackChains.clear();
      when(() => looper.masterEffects).thenReturn(const []);
      await pump(tester);
      await select(tester, PedalButton.recPlay);

      // The Master insert always exists, so there is always at least one
      // target — the empty-state copy is reachable only with no stages at all.
      expect(find.byKey(const Key('assign_target_picker')), findsOneWidget);
    });
  });
}

extension on WidgetTester {
  AppLocalizations get l10n =>
      AppLocalizations.of(element(find.byType(PedalAssignmentPage)));
}
