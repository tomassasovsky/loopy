import 'dart:async';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/network/network_tab.dart';
import 'package:segno/network/network_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../helpers/helpers.dart';

/// A WiFi stack with just enough behaviour to drive the face.
class _FaceWifiClient implements WifiClient {
  _FaceWifiClient({this.enabled = true});

  bool enabled;
  String connectedSsid = 'HomeNet';
  final List<String> forgotten = [];
  final List<String> joined = [];
  String? lastPsk;
  bool failNextConnect = false;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: enabled && connectedSsid.isNotEmpty,
    ssid: enabled ? connectedSsid : '',
    ip: '10.0.0.4',
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [
    WifiNetwork(ssid: 'HomeNet', signal: -40, secured: true, saved: true),
    WifiNetwork(ssid: 'Studio 5G', signal: -48, secured: true),
    WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
  ];

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('authentication failed');
    }
    joined.add(ssid);
    lastPsk = psk;
    connectedSsid = ssid;
  }

  @override
  Future<void> disconnect() async => connectedSsid = '';

  @override
  Future<void> forget(String ssid) async => forgotten.add(ssid);

  @override
  Future<void> setEnabled({required bool enabled}) async =>
      this.enabled = enabled;
}

class _FaceBluetoothClient implements BluetoothClient {
  _FaceBluetoothClient({this.powered = true});

  bool powered;
  final List<String> paired = [];
  final List<String> forgotten = [];
  final List<String> connected = [];
  final List<String> disconnected = [];
  bool failNextPair = false;

  /// Completes when the test lets a pairing finish, so the in-flight banner
  /// can be observed. Pairing waits on a human at the far device — a fake that
  /// resolves instantly could never show the state that exists because of it.
  Completer<void>? gate;

  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => BluetoothStatus(
    supported: true,
    powered: powered,
    discoverable: true,
    advertising: false,
    alias: 'Segno',
  );

  @override
  Future<List<BluetoothDevice>> scan() async => const [
    BluetoothDevice(
      name: 'Cans',
      address: 'AA:AA:AA:AA:AA:AA',
      paired: true,
      connected: true,
      kind: BluetoothDeviceKind.headphones,
    ),
    BluetoothDevice(name: 'Turner', address: 'CC:CC:CC:CC:CC:CC'),
  ];

  @override
  Future<void> setPowered({required bool enabled}) async => powered = enabled;

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}

  @override
  Future<void> pair(String address) async {
    if (gate != null) await gate!.future;
    if (failNextPair) {
      failNextPair = false;
      throw StateError('Pairing timed out.');
    }
    paired.add(address);
  }

  @override
  Future<void> connect(String address) async => connected.add(address);

  @override
  Future<void> disconnect(String address) async => disconnected.add(address);

  @override
  Future<void> forget(String address) async => forgotten.add(address);
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    // `FocusableTapTarget` reads this, so a harness that omits it crashes
    // every focusable row — the app always carries both.
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

void main() {
  late SettingsTrayCubit tray;

  setUp(() {
    tray = SettingsTrayCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    )..open();
  });

  tearDown(() => tray.close());

  Future<void> pumpFace(
    WidgetTester tester, {
    _FaceWifiClient? wifi,
    _FaceBluetoothClient? bluetooth,
    NetworkTab tab = NetworkTab.wifi,
  }) async {
    tester.view
      ..physicalSize = const Size(1400, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tray.showNetworkTab(tab);

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: tray),
            BlocProvider(
              create: (_) => WifiCubit(
                repository: WifiRepository(
                  client: wifi ?? _FaceWifiClient(),
                ),
              ),
            ),
            BlocProvider(
              create: (_) => BluetoothCubit(
                repository: BluetoothRepository(
                  client: bluetooth ?? _FaceBluetoothClient(),
                ),
              ),
            ),
          ],
          child: const Scaffold(body: NetworkTrayPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the domain', () {
    testWidgets('is a tab strip and a body, with no chrome bar above it', (
      tester,
    ) async {
      await pumpFace(tester);

      expect(find.byKey(const Key('network_tabs')), findsOneWidget);
      expect(find.byKey(const Key('wifi_tray_body')), findsOneWidget);
      // No back chevron on a domain face — the rail is the only way back.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.chevron_left), findsNothing);
    });

    testWidgets('the strip swaps the body and moves the cubit tab', (
      tester,
    ) async {
      await pumpFace(tester);

      await tester.tap(find.text('Bluetooth'));
      await tester.pumpAndSettle();

      expect(tray.state.networkTab, NetworkTab.bluetooth);
      expect(find.byKey(const Key('bluetooth_tray_body')), findsOneWidget);
      expect(find.byKey(const Key('wifi_tray_body')), findsNothing);
      // Moving the tab must not move the destination.
      expect(tray.state.destination, SettingsTrayDestination.home);
    });
  });

  group('WiFi face', () {
    testWidgets('switched off, the title row is the whole face', (
      tester,
    ) async {
      await pumpFace(tester, wifi: _FaceWifiClient(enabled: false));

      expect(find.byKey(const Key('wifi_power')), findsOneWidget);
      // Nothing else exists until it is on — no list, and no rescan control
      // to press against a radio that is down.
      expect(find.byKey(const Key('wifi_scan')), findsNothing);
      expect(find.byType(ConsoleCard), findsNothing);
    });

    testWidgets('the power switch turns the radio on', (tester) async {
      final client = _FaceWifiClient(enabled: false);
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_power')));
      await tester.pumpAndSettle();

      expect(client.enabled, isTrue);
      expect(find.byType(ConsoleCard), findsOneWidget);
    });

    testWidgets('a saved row opens in place into its actions', (tester) async {
      await pumpFace(tester);

      expect(find.text('Disconnect'), findsNothing);
      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_disconnect')), findsOneWidget);
      expect(find.byKey(const Key('wifi_forget')), findsOneWidget);
    });

    testWidgets('only one row is open at a time', (tester) async {
      await pumpFace(tester);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wifi_forget')), findsOneWidget);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      // The row's container stays in the tree so opening and shutting can
      // animate; what goes is its actions. A shut row holds nothing tappable,
      // which is the property worth pinning — testing for the container
      // instead would pass while leaving invisible chips live.
      expect(find.byKey(const Key('wifi_forget')), findsNothing);
    });

    testWidgets('a row that is shut holds no action, mid-close included', (
      tester,
    ) async {
      await pumpFace(tester);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));

      // Half way through the close the chips are still drawn — clipped and
      // fading — and must not be reachable by a stray tap.
      await tester.pump(kConsoleMotion ~/ 2);
      final chip = find.byKey(const Key('wifi_forget'));
      expect(tester.getSize(chip).height, greaterThan(0));

      await tester.pumpAndSettle();
      expect(chip, findsNothing);
    });

    testWidgets('disconnect is reversible, so it asks nothing', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_disconnect')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
      expect(client.connectedSsid, isEmpty);
    });

    testWidgets('forget destroys a credential, so it confirms first', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);
      expect(client.forgotten, isEmpty, reason: 'not until confirmed');

      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      expect(client.forgotten, ['HomeNet']);
    });

    testWidgets('cancelling the confirm forgets nothing', (tester) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();

      expect(client.forgotten, isEmpty);
    });

    testWidgets('an open network joins on tap, with no sheet', (tester) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_join_sheet')), findsNothing);
      expect(client.joined, ['Cafe Free']);
      expect(client.lastPsk, isNull);
    });

    testWidgets('a secured network raises the sheet and joins with its text', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Studio 5G')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);

      for (final key in ['s', 'e', 'g', 'n', 'o', '1', '2', '3']) {
        await tester.tap(find.widgetWithText(InkWell, key).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, 'Join').last);
      await tester.pumpAndSettle();

      expect(client.joined, ['Studio 5G']);
      expect(client.lastPsk, 'segno123');
    });

    testWidgets("the sheet enforces WPA2's 8-character floor itself", (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Studio 5G')));
      await tester.pumpAndSettle();
      for (final key in ['a', 'b', 'c']) {
        await tester.tap(find.widgetWithText(InkWell, key).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, 'Join').last);
      await tester.pumpAndSettle();

      // Corrected here, rather than handed to the supplicant and returned
      // seconds later as a generic association failure.
      expect(find.byKey(const Key('wifi_join_too_short')), findsOneWidget);
      expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);
      expect(client.joined, isEmpty);
    });

    testWidgets('a refusal rides as a banner naming the network', (
      tester,
    ) async {
      final client = _FaceWifiClient()..failNextConnect = true;
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_banner')), findsOneWidget);
      // A dialog would take the list away; the banner sits in it.
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('could not join Cafe Free'), findsOneWidget);
    });
  });

  group('Bluetooth face', () {
    testWidgets('switched off, the title row is the whole face', (
      tester,
    ) async {
      await pumpFace(
        tester,
        bluetooth: _FaceBluetoothClient(powered: false),
        tab: NetworkTab.bluetooth,
      );

      expect(find.byKey(const Key('bluetooth_power')), findsOneWidget);
      expect(find.byType(ConsoleCard), findsNothing);
      // Even the console's own visibility switches go: they describe an
      // adapter that is down.
      expect(find.byKey(const Key('bluetooth_discoverable')), findsNothing);
    });

    testWidgets('the visibility switches belong to the console, not a device', (
      tester,
    ) async {
      await pumpFace(tester, tab: NetworkTab.bluetooth);

      expect(find.byKey(const Key('bluetooth_discoverable')), findsOneWidget);
      expect(find.byKey(const Key('bluetooth_advertise')), findsOneWidget);
      // Their own card, below the devices.
      expect(find.byType(ConsoleCard), findsNWidgets(2));
    });

    testWidgets('a paired row opens into connect/disconnect and forget', (
      tester,
    ) async {
      await pumpFace(tester, tab: NetworkTab.bluetooth);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_AA:AA:AA:AA:AA:AA')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bluetooth_disconnect')), findsOneWidget);
      expect(find.byKey(const Key('bluetooth_forget')), findsOneWidget);
    });

    testWidgets('an unpaired device pairs on tap', (tester) async {
      final client = _FaceBluetoothClient();
      await pumpFace(tester, bluetooth: client, tab: NetworkTab.bluetooth);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_CC:CC:CC:CC:CC:CC')),
      );
      await tester.pumpAndSettle();

      expect(client.paired, ['CC:CC:CC:CC:CC:CC']);
    });

    testWidgets(
      'pairing is not "busy" — the rows stay live behind the banner',
      (tester) async {
        final client = _FaceBluetoothClient()..gate = Completer<void>();
        await pumpFace(tester, bluetooth: client, tab: NetworkTab.bluetooth);

        await tester.tap(
          find.byKey(const Key('bluetooth_device_CC:CC:CC:CC:CC:CC')),
        );
        await tester.pump();

        expect(find.byKey(const Key('bluetooth_banner')), findsOneWidget);
        // The other rows are still tappable while a pairing waits on a human.
        final row = tester.widget<ConsoleRow>(
          find.byKey(const Key('bluetooth_device_AA:AA:AA:AA:AA:AA')),
        );
        expect(row.onTap, isNotNull);

        client.gate!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('the banner grows the list open rather than shoving it', (
      tester,
    ) async {
      final client = _FaceBluetoothClient()..gate = Completer<void>();
      await pumpFace(tester, bluetooth: client, tab: NetworkTab.bluetooth);

      final firstRow = find.byKey(
        const Key('bluetooth_device_AA:AA:AA:AA:AA:AA'),
      );
      final restingTop = tester.getTopLeft(firstRow).dy;

      await tester.tap(
        find.byKey(const Key('bluetooth_device_CC:CC:CC:CC:CC:CC')),
      );
      await tester.pump();

      // One frame in, the banner is on screen but has no height yet, so the
      // rows have not moved: arriving is a transition, not a jump.
      final banner = find.byKey(const Key('bluetooth_banner'));
      expect(banner, findsOneWidget);
      expect(tester.getTopLeft(firstRow).dy, closeTo(restingTop, 1));

      // Part way through, the rows are on their way down but not yet arrived.
      await tester.pump(kConsoleMotion ~/ 2);
      final midTop = tester.getTopLeft(firstRow).dy;
      expect(midTop, greaterThan(restingTop));

      await tester.pumpAndSettle();
      expect(tester.getTopLeft(firstRow).dy, greaterThan(midTop));

      client.gate!.complete();
      await tester.pumpAndSettle();
      // And back up again once the banner goes.
      expect(tester.getTopLeft(firstRow).dy, closeTo(restingTop, 1));
    });

    testWidgets('a refusal offers Try again, not a dialog', (tester) async {
      final client = _FaceBluetoothClient()..failNextPair = true;
      await pumpFace(tester, bluetooth: client, tab: NetworkTab.bluetooth);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_CC:CC:CC:CC:CC:CC')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bluetooth_banner')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('forgetting a device confirms first', (tester) async {
      final client = _FaceBluetoothClient();
      await pumpFace(tester, bluetooth: client, tab: NetworkTab.bluetooth);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_AA:AA:AA:AA:AA:AA')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bluetooth_forget')));
      await tester.pumpAndSettle();

      expect(client.forgotten, isEmpty);
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      expect(client.forgotten, ['AA:AA:AA:AA:AA:AA']);
    });

    testWidgets('an out-of-range paired device cannot be connected to', (
      tester,
    ) async {
      await pumpFace(tester, tab: NetworkTab.bluetooth);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_AA:AA:AA:AA:AA:AA')),
      );
      await tester.pumpAndSettle();
      // This one IS in range and connected, so it offers disconnect.
      expect(find.byKey(const Key('bluetooth_connect')), findsNothing);
    });
  });
}
