import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tray/pedal_tray_panel.dart';
import 'package:segno/pedal/view/pedal_assignment_page.dart';
import 'package:segno/theme/surface_theme.dart';
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
  late SettingsRepository settings;

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
    settings = SettingsRepository(store: FakeKeyValueStore());
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

  /// Mounts the tray FACE rather than the pushed route, with the providers
  /// the real tray inherits from `App` (it mounts below them, so the face
  /// re-provides nothing itself).
  Future<void> pumpTrayFace(
    WidgetTester tester, {
    required VoidCallback onBack,
  }) async {
    settings = SettingsRepository(store: FakeKeyValueStore());
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
            child: Scaffold(body: PedalTrayPanel(onBack: onBack)),
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

      final binding = control.state.globalBindings.lookup(
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
        control.state.globalBindings
            .lookup(PedalButton.recPlay, bank: 0)
            ?.behavior,
        BindingBehavior.momentary,
      );
    });

    testWidgets('edits the set IN FORCE — with a session remap loaded the '
        'globals are overridden wholesale (A12), so editing them would write '
        'to a set that never dispatches', (tester) async {
      await pump(tester);
      final chain3 = const FxChainTarget(
        FxAddress(stage: FxStage.track, index: 3),
      ).canonicalString();
      // A session remap is in force; the globals are inert.
      await control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.undo),
            target: chain3,
          ),
        ]),
      );
      control.applySessionBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.stop),
            target: chain3,
          ),
        ]),
      );
      await tester.pump();

      // The screen shows the SESSION binding, not the global one.
      await select(tester, PedalButton.stop);
      expect(find.byKey(const Key('assign_row')), findsOneWidget);
      await select(tester, PedalButton.undo);
      expect(find.byKey(const Key('assign_row')), findsNothing);

      // And an edit PROMOTES the session copy to the persistent global set,
      // dropping the override — so what is on screen stays in force and now
      // survives a restart, instead of vanishing on quit.
      await select(tester, PedalButton.stop);
      await tapVisible(tester, find.byKey(const Key('assign_clear')));

      expect(control.state.sessionBindings.isEmpty, isTrue);
      expect(
        control.state.globalBindings.lookup(PedalButton.stop, bank: 0),
        isNull,
        reason: 'the clear landed on the promoted set',
      );
      expect(
        control.state.globalBindings.lookup(PedalButton.undo, bank: 0),
        isNull,
        reason: 'the promoted session copy replaced the old globals wholesale',
      );
    });

    testWidgets('every edit persists to settings immediately, including one '
        'made while a session remap was in force', (tester) async {
      await pump(tester);
      final chain3 = const FxChainTarget(
        FxAddress(stage: FxStage.track, index: 3),
      ).canonicalString();
      control.applySessionBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.stop),
            target: chain3,
          ),
        ]),
      );
      await tester.pump();

      await select(tester, PedalButton.stop);
      await tapVisible(tester, find.text(tester.l10n.pedalAssignMomentary));

      // The settings key — not just the in-memory set — carries the edit, so
      // quitting without saving the session cannot lose it.
      final persisted = PedalBindingSet.decode(
        await settings.loadPedalBindings() ?? '',
      );
      expect(
        persisted.lookup(PedalButton.stop, bank: 0)?.behavior,
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
          control.state.globalBindings.lookup(PedalButton.recPlay, bank: 0),
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
          control.state.globalBindings
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
          control.state.globalBindings.lookup(PedalButton.recPlay, bank: 0),
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

  testWidgets('showPedalAssignmentPage opens the surface and re-provides what '
      'it drives — a pushed route does not inherit the caller providers', (
    tester,
  ) async {
    await pump(tester);
    final context = tester.element(find.byType(PedalAssignmentPage));

    // NOT awaited: the push future completes only when the route is POPPED,
    // so awaiting it here would hang until the test timed out.
    unawaited(showPedalAssignmentPage(context));
    await tester.pumpAndSettle();

    // Two in the tree — the one pumped above (now offstage behind the opaque
    // route) and the pushed route's own. The pushed one builds at all only
    // because the helper re-provided the cubit and the repository; without
    // them it would have thrown ProviderNotFound instead.
    expect(
      find.byType(PedalAssignmentPage, skipOffstage: false),
      findsNWidgets(2),
    );
    expect(find.byKey(const Key('assign_prompt')), findsOneWidget);
  });

  group('PedalTrayPanel (console rail destination, #440)', () {
    testWidgets('renders the same assignment surface as the pushed route', (
      tester,
    ) async {
      await pumpTrayFace(tester, onBack: () {});

      // The face carries the surface itself, not a copy of it, and brings no
      // route chrome of its own.
      expect(find.byType(PedalAssignmentView), findsOneWidget);
      expect(find.byType(PedalAssignmentPage), findsNothing);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('selecting a footswitch still drives the editor', (
      tester,
    ) async {
      await pumpTrayFace(tester, onBack: () {});

      // The extraction moved _selected/_bank into PedalAssignmentView; if that
      // state had been dropped, the plate would select nothing and the editor
      // would stay on its prompt.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PedalAssignmentView)),
      );
      expect(find.text(l10n.pedalAssignSelectPrompt), findsOneWidget);

      await select(tester, PedalButton.recPlay);

      expect(find.text(l10n.pedalAssignSelectPrompt), findsNothing);
    });

    testWidgets('back returns to the tray home without dismissing', (
      tester,
    ) async {
      var backs = 0;
      await pumpTrayFace(tester, onBack: () => backs++);

      await tester.tap(find.byKey(const Key('pedal_back')));
      await tester.pump();

      expect(backs, 1);
    });
  });
}

extension on WidgetTester {
  AppLocalizations get l10n =>
      AppLocalizations.of(element(find.byType(PedalAssignmentView)));
}
