import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/view/settings_tray.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late SettingsTrayCubit cubit;

  setUp(() => cubit = SettingsTrayCubit());
  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<SettingsTrayCubit>.value(
        value: cubit,
        // A Scaffold + Stack mirrors how TracksView actually mounts the
        // tray: as a Stack sibling over full-screen content, top edge at
        // (0, 0).
        child: const Scaffold(
          body: Stack(children: [SizedBox.expand(), SettingsTray()]),
        ),
      ),
    ),
  );

  testWidgets('renders the always-visible handle', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('settingsTray_handle')), findsOneWidget);
  });

  testWidgets('renders the scrim', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('settingsTray_scrim')), findsOneWidget);
  });

  testWidgets(
    'renders the nav buttons, stub buttons, and brightness slider once open',
    (tester) async {
      cubit.open();
      await pump(tester);
      await tester.pump();

      expect(find.byKey(const Key('settingsTray_settings')), findsOneWidget);
      expect(find.byKey(const Key('settingsTray_signal')), findsOneWidget);
      expect(find.byKey(const Key('settingsTray_wifi')), findsOneWidget);
      expect(find.byKey(const Key('settingsTray_bluetooth')), findsOneWidget);
      expect(find.byKey(const Key('settingsTray_tuner')), findsOneWidget);
      expect(
        find.byKey(const Key('settingsTray_brightness')),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping the handle opens a closed tray', (tester) async {
    await pump(tester);
    expect(cubit.state.dragProgress, 0);

    await tester.tap(find.byKey(const Key('settingsTray_handle')));
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 1);
  });

  testWidgets('tapping the handle closes an open tray', (tester) async {
    cubit.open();
    await pump(tester);
    await tester.pump();

    await tester.tap(find.byKey(const Key('settingsTray_handle')));
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 0);
  });

  testWidgets('dragging the handle down past the threshold opens the tray', (
    tester,
  ) async {
    await pump(tester);
    expect(cubit.state.dragProgress, 0);

    // Past 50% of the tray's fixed reveal height (well past — the drag
    // helper delivers the offset over several synthetic pointer moves, and
    // only the net displacement needs to clear the threshold).
    await tester.drag(
      find.byKey(const Key('settingsTray_handle')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 1);
  });

  testWidgets(
    'dragging the handle down under the threshold settles closed',
    (tester) async {
      await pump(tester);

      await tester.drag(
        find.byKey(const Key('settingsTray_handle')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();

      expect(cubit.state.dragProgress, 0);
    },
  );

  testWidgets('tapping the scrim closes an open tray', (tester) async {
    cubit.open();
    await pump(tester);
    await tester.pump();

    await tester.tap(find.byKey(const Key('settingsTray_scrim')));
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 0);
  });

  testWidgets('the scrim does not intercept touches while closed', (
    tester,
  ) async {
    await pump(tester);

    // Tapping where the scrim would sit (center of the screen) must not
    // close an already-closed tray or throw — it is ignored (both for hit
    // testing and semantics) while the tray has no visible extent.
    await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
    await tester.pump();

    expect(cubit.state.dragProgress, 0);
    expect(tester.takeException(), isNull);
  });

  group('WiFi/Bluetooth/Tuner stub buttons', () {
    for (final (key, labelOf) in [
      ('settingsTray_wifi', (AppLocalizations l10n) => l10n.trayWifiLabel),
      (
        'settingsTray_bluetooth',
        (AppLocalizations l10n) => l10n.trayBluetoothLabel,
      ),
      ('settingsTray_tuner', (AppLocalizations l10n) => l10n.trayTunerLabel),
    ]) {
      testWidgets(
        'tapping $key opens a coming-soon stub naming it and leaves the '
        'tray open underneath',
        (tester) async {
          cubit.open();
          await pump(tester);
          await tester.pump();

          await tester.tap(find.byKey(Key(key)));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('en'),
          );
          expect(
            find.byKey(const Key('comingSoonStub_dialog')),
            findsOneWidget,
          );
          expect(
            find.text(l10n.trayComingSoonMessage(labelOf(l10n))),
            findsOneWidget,
          );
          expect(cubit.state.dragProgress, 1);

          await tester.tap(find.byKey(const Key('comingSoonStub_close')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('comingSoonStub_dialog')), findsNothing);
        },
      );
    }

    testWidgets('the stub dialog also dismisses on tap-outside (barrier)', (
      tester,
    ) async {
      cubit.open();
      await pump(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('settingsTray_wifi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('comingSoonStub_dialog')), findsOneWidget);

      // Tap far outside the dialog's content — the modal barrier.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('comingSoonStub_dialog')), findsNothing);
    });
  });

  group('isNavigating guard on Settings/Signal', () {
    testWidgets('disables both nav buttons while a push is in flight', (
      tester,
    ) async {
      cubit
        ..open()
        ..beginNavigating();
      await pump(tester);
      await tester.pump();

      expect(
        tester
            .widget<FocusableTapTarget>(
              find.descendant(
                of: find.byKey(const Key('settingsTray_settings')),
                matching: find.byType(FocusableTapTarget),
              ),
            )
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<FocusableTapTarget>(
              find.descendant(
                of: find.byKey(const Key('settingsTray_signal')),
                matching: find.byType(FocusableTapTarget),
              ),
            )
            .onTap,
        isNull,
      );
    });

    testWidgets(
      'tapping Settings closes the tray and clears isNavigating once the '
      'push settles (no navigator wired in this harness, so the push '
      'no-ops instead of actually pushing a route)',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pump();

        await tester.tap(find.byKey(const Key('settingsTray_settings')));
        await tester.pumpAndSettle();

        expect(cubit.state.dragProgress, 0);
        expect(cubit.state.isNavigating, isFalse);
      },
    );

    testWidgets(
      'tapping Signal closes the tray, pushes the Signal surface once, '
      'holds isNavigating while the page is open, and clears it once the '
      "page pops — the guard's actual motivating scenario (showSignalPage "
      'has no re-entrancy guard of its own, unlike openLoopySettings)',
      (tester) async {
        // Unlike Settings (openLoopySettings no-ops safely with no navigator
        // wired), showSignalPage pushes onto THIS test's own Navigator via
        // Navigator.of(context) — so a real push needs the providers it
        // reads from context, matching signal_list_view_test.dart's setup.
        final looperRepository = LooperRepository(
          engine: FakeAudioEngine(),
          ticker: const Stream<void>.empty(),
        );
        addTearDown(looperRepository.dispose);
        final settings = SettingsRepository(store: FakeKeyValueStore());
        final bloc = _MockLooperBloc();
        when(() => bloc.state).thenReturn(const LooperState());
        whenListen(
          bloc,
          const Stream<LooperState>.empty(),
          initialState: const LooperState(),
        );
        final monitor = MonitorCubit(
          repository: looperRepository,
          settings: settings,
        );
        addTearDown(monitor.close);
        final tracks = TracksCubit(settings: settings);
        addTearDown(tracks.close);

        cubit.open();
        tester.view
          ..physicalSize = const Size(1200, 900)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsTrayCubit>.value(value: cubit),
                BlocProvider<LooperBloc>.value(value: bloc),
                BlocProvider<MonitorCubit>.value(value: monitor),
                BlocProvider<TracksCubit>.value(value: tracks),
              ],
              child: const Scaffold(
                body: Stack(children: [SizedBox.expand(), SettingsTray()]),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('settingsTray_signal')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Pushed exactly once — the signal page's own Scaffold is on screen.
        expect(find.byKey(const Key('signal_page')), findsOneWidget);
        expect(cubit.state.dragProgress, 0);
        // `Navigator.push`'s Future only resolves on pop — the guard
        // legitimately stays engaged (and the nav buttons disabled) for as
        // long as the Signal page is on screen, since a second tap while
        // it's up would otherwise double-push (showSignalPage has no guard
        // of its own).
        expect(cubit.state.isNavigating, isTrue);

        Navigator.of(
          tester.element(find.byKey(const Key('signal_page'))),
        ).pop();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('signal_page')), findsNothing);
        expect(cubit.state.isNavigating, isFalse);
      },
    );
  });

  testWidgets('the brightness slider renders the state default (0.8)', (
    tester,
  ) async {
    cubit.open();
    await pump(tester);
    await tester.pump();

    expect(
      tester
          .widget<Slider>(find.byKey(const Key('settingsTray_brightness')))
          .value,
      0.8,
    );
  });

  testWidgets('dragging the brightness slider updates the cubit', (
    tester,
  ) async {
    cubit.open();
    await pump(tester);
    await tester.pump();

    final slider = find.byKey(const Key('settingsTray_brightness'));
    await tester.drag(slider, const Offset(-200, 0));
    await tester.pump();

    expect(cubit.state.brightness, lessThan(0.8));
  });

  testWidgets('every tap target is labeled (labeledTapTargetGuideline)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    cubit.open();
    await pump(tester);
    await tester.pump();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
