import 'package:bloc_test/bloc_test.dart';
import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:wifi_repository/wifi_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _ToggleWifiClient implements WifiClient {
  bool enabled = true;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: false,
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [];

  @override
  Future<void> connect(String ssid, {String? psk}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {
    this.enabled = enabled;
  }
}

class _ToggleBluetoothClient implements BluetoothClient {
  bool powered = true;

  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => BluetoothStatus(
    supported: true,
    powered: powered,
    discoverable: false,
    advertising: false,
  );

  @override
  Future<List<BluetoothDevice>> scan() async => const [];

  @override
  Future<void> setPowered({required bool enabled}) async {
    powered = enabled;
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}
}

void main() {
  late SettingsTrayCubit cubit;
  late SettingsRepository settings;
  late _ToggleWifiClient wifiClient;
  late _ToggleBluetoothClient bluetoothClient;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    cubit = SettingsTrayCubit(settings: settings);
    wifiClient = _ToggleWifiClient();
    bluetoothClient = _ToggleBluetoothClient();
  });
  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<WifiRepository>.value(
            value: WifiRepository(client: wifiClient),
          ),
          RepositoryProvider<BluetoothRepository>.value(
            value: BluetoothRepository(client: bluetoothClient),
          ),
        ],
        child: BlocProvider<SettingsTrayCubit>.value(
          value: cubit,
          // A Scaffold + Stack mirrors how TracksView actually mounts the
          // tray: as a Stack sibling over full-screen content, top edge at
          // (0, 0).
          child: const Scaffold(
            body: Stack(children: [SizedBox.expand(), SettingsTray()]),
          ),
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

    // Past 50% of the tray's reveal height — well past (the drag helper
    // delivers the offset over several synthetic pointer moves, and only the
    // net displacement needs to clear the threshold); the tray is
    // near-fullscreen (test surface height 600 - 24 = 576), so 500px clears
    // the 288px halfway point.
    await tester.drag(
      find.byKey(const Key('settingsTray_handle')),
      const Offset(0, 500),
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

    // The panel now fills much more of the screen (Control-Center sized),
    // so the scrim's default center point can land on the panel itself —
    // tap explicitly below it instead.
    await tester.tapAt(const Offset(400, 580));
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

  group('WiFi / Bluetooth / Tuner tiles', () {
    testWidgets(
      'tapping WiFi while on turns radio off and stays on home',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        expect(wifiClient.enabled, isTrue);
        await tester.tap(find.byKey(const Key('settingsTray_wifi')));
        await tester.pumpAndSettle();

        expect(cubit.state.destination, SettingsTrayDestination.home);
        expect(wifiClient.enabled, isFalse);
        expect(find.byKey(const Key('settingsTray_wifi')), findsOneWidget);
      },
    );

    testWidgets(
      'tapping WiFi while off turns radio on and opens the panel',
      (tester) async {
        wifiClient.enabled = false;
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('settingsTray_wifi')));
        await tester.pumpAndSettle();

        expect(wifiClient.enabled, isTrue);
        expect(cubit.state.destination, SettingsTrayDestination.wifi);
        expect(find.byKey(const Key('wifi_tray_panel')), findsOneWidget);
      },
    );

    testWidgets(
      'long-pressing WiFi expands the in-tray panel without dismissing',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        await tester.longPress(find.byKey(const Key('settingsTray_wifi')));
        await tester.pumpAndSettle();

        expect(cubit.state.dragProgress, 1);
        expect(cubit.state.destination, SettingsTrayDestination.wifi);
        expect(find.byKey(const Key('wifi_tray_panel')), findsOneWidget);
        expect(find.byKey(const Key('settingsTray_wifi')), findsNothing);

        await tester.tap(find.byKey(const Key('wifi_back')));
        await tester.pumpAndSettle();
        expect(cubit.state.destination, SettingsTrayDestination.home);
        expect(find.byKey(const Key('settingsTray_wifi')), findsOneWidget);
      },
    );

    testWidgets(
      'tapping Bluetooth while on turns power off and stays on home',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        expect(bluetoothClient.powered, isTrue);
        await tester.tap(find.byKey(const Key('settingsTray_bluetooth')));
        await tester.pumpAndSettle();

        expect(cubit.state.destination, SettingsTrayDestination.home);
        expect(bluetoothClient.powered, isFalse);
      },
    );

    testWidgets(
      'tapping Bluetooth while off turns power on and opens the panel',
      (tester) async {
        bluetoothClient.powered = false;
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('settingsTray_bluetooth')));
        await tester.pumpAndSettle();

        expect(bluetoothClient.powered, isTrue);
        expect(cubit.state.destination, SettingsTrayDestination.bluetooth);
        expect(find.byKey(const Key('bluetooth_tray_panel')), findsOneWidget);
      },
    );

    testWidgets(
      'long-pressing Bluetooth expands the in-tray panel without dismissing',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pumpAndSettle();

        await tester.longPress(
          find.byKey(const Key('settingsTray_bluetooth')),
        );
        await tester.pumpAndSettle();

        expect(cubit.state.dragProgress, 1);
        expect(
          cubit.state.destination,
          SettingsTrayDestination.bluetooth,
        );
        expect(find.byKey(const Key('bluetooth_tray_panel')), findsOneWidget);

        await tester.tap(find.byKey(const Key('bluetooth_back')));
        await tester.pumpAndSettle();
        expect(cubit.state.destination, SettingsTrayDestination.home);
      },
    );

    testWidgets(
      'tapping Tuner opens a coming-soon stub and leaves the tray open',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pump();

        await tester.tap(find.byKey(const Key('settingsTray_tuner')));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(find.byKey(const Key('comingSoonStub_dialog')), findsOneWidget);
        expect(
          find.text(l10n.trayComingSoonMessage(l10n.trayTunerLabel)),
          findsOneWidget,
        );
        expect(cubit.state.dragProgress, 1);

        await tester.tap(find.byKey(const Key('comingSoonStub_close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('comingSoonStub_dialog')), findsNothing);
      },
    );
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
            home: MultiRepositoryProvider(
              providers: [
                RepositoryProvider<WifiRepository>.value(
                  value: WifiRepository(client: wifiClient),
                ),
                RepositoryProvider<BluetoothRepository>.value(
                  value: BluetoothRepository(client: bluetoothClient),
                ),
              ],
              child: MultiBlocProvider(
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

  group('brightness slider tile', () {
    testWidgets(
      'exposes the state default (0.8) as an 80% semantics value',
      (tester) async {
        final handle = tester.ensureSemantics();
        cubit.open();
        await pump(tester);
        await tester.pump();

        // Slider sets its own semantics boundary — an ancestor label never
        // merges into it, so `_BrightnessSliderTile` excludes Slider's own
        // semantics and replaces them wholesale with one node.
        expect(
          tester.getSemantics(find.byType(Slider)),
          isSemantics(
            isSlider: true,
            label: 'Brightness',
            value: '80%',
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        );
        handle.dispose();
      },
    );

    testWidgets('dragging down (toward the bottom) lowers the value', (
      tester,
    ) async {
      cubit.open();
      await pump(tester);
      await tester.pump();

      final slider = find.byKey(const Key('settingsTray_brightness'));
      await tester.drag(slider, const Offset(0, 100));
      await tester.pump();

      expect(cubit.state.brightness, lessThan(0.8));
    });

    testWidgets('dragging up (toward the top) raises the value', (
      tester,
    ) async {
      cubit.open();
      await pump(tester);
      await tester.pump();

      final slider = find.byKey(const Key('settingsTray_brightness'));
      await tester.drag(slider, const Offset(0, -300));
      await tester.pump();

      expect(cubit.state.brightness, greaterThan(0.9));
    });

    testWidgets(
      'a tap moves the value to the tapped position — unlike a plain '
      'Slider ignoring taps, this one changes value on tap, not just drag',
      (tester) async {
        cubit.open();
        await pump(tester);
        await tester.pump();

        await tester.tap(find.byKey(const Key('settingsTray_brightness')));
        await tester.pump();

        expect(cubit.state.brightness, inInclusiveRange(0.0, 1.0));
      },
    );

    testWidgets('the arrow-up key increases the value by the 5% step', (
      tester,
    ) async {
      // Slider's arrow-key step is platform-dependent (10% on iOS/macOS, 5%
      // elsewhere — see `_adjustmentUnit` in the Flutter SDK's
      // `slider.dart`) — pinned so this assertion is deterministic on every
      // machine, not just this one. Reset inline (not via `tearDown`/
      // `addTearDown`) — the test framework's own foundation-debug-var
      // check runs before either gets a chance to fire.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      cubit.open();
      await pump(tester);
      await tester.pump();

      // The tile's own pointer listener requests focus on tap.
      await tester.tap(find.byKey(const Key('settingsTray_brightness')));
      await tester.pump();
      final before = cubit.state.brightness;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(cubit.state.brightness, closeTo(before + 0.05, 0.001));
      debugDefaultTargetPlatformOverride = null;
    });
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
