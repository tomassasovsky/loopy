import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/bluetooth/bluetooth_tray_body.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_tray_body.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// A WiFi stack that behaves: the console can turn the radio on and off, join,
/// disconnect and forget, and every call is recorded so a test can assert what
/// the face actually asked the radio to do.
class _FakeWifiClient implements WifiClient {
  bool enabled = true;
  bool connected = true;
  String ssid = 'Studio-5G';
  bool failJoin = false;
  final List<String> calls = [];

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: connected && enabled,
    ssid: connected && enabled ? ssid : '',
    ip: connected && enabled ? '192.168.1.42' : '',
  );

  @override
  Future<List<WifiNetwork>> scan() async {
    calls.add('scan');
    if (!enabled) return const [];
    return const [
      WifiNetwork(ssid: 'Studio-5G', signal: -48, secured: true, saved: true),
      WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
      WifiNetwork(ssid: 'Studio-Guest', signal: -62, secured: true),
    ];
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    calls.add('connect:$ssid:${psk ?? ''}');
    if (failJoin) throw StateError('WRONG_PASSPHRASE');
    connected = true;
    this.ssid = ssid;
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    connected = false;
  }

  @override
  Future<void> forget(String ssid) async {
    calls.add('forget:$ssid');
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    calls.add('setEnabled:$enabled');
    this.enabled = enabled;
  }
}

class _FakeBluetoothClient implements BluetoothClient {
  bool powered = true;
  final List<String> calls = [];

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
  Future<List<BluetoothDevice>> scan() async {
    calls.add('scan');
    if (!powered) return const [];
    return const [
      BluetoothDevice(
        name: 'WH-1000XM4',
        address: 'AA:BB:CC:11:22:33',
        paired: true,
        connected: true,
        kind: 'headphones',
      ),
      BluetoothDevice(name: 'AirTurn BT-200', address: '11:22:33:44:55:66'),
    ];
  }

  @override
  Future<void> setPowered({required bool enabled}) async {
    calls.add('setPowered:$enabled');
    powered = enabled;
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    calls.add('setDiscoverable:$enabled');
  }

  @override
  Future<void> setAdvertising({required bool enabled}) async {
    calls.add('setAdvertising:$enabled');
  }

  @override
  Future<void> pair(String address) async {
    calls.add('pair:$address');
  }

  @override
  Future<void> connect(String address) async {
    calls.add('connect:$address');
  }

  @override
  Future<void> disconnect(String address) async {
    calls.add('disconnect:$address');
  }

  @override
  Future<void> forget(String address) async {
    calls.add('forget:$address');
  }
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  Future<void> pumpWifi(WidgetTester tester, _FakeWifiClient client) async {
    final cubit = WifiCubit(repository: WifiRepository(client: client));
    addTearDown(cubit.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<WifiCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(19),
              child: WifiTrayBody(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpBluetooth(
    WidgetTester tester,
    _FakeBluetoothClient client,
  ) async {
    final cubit = BluetoothCubit(
      repository: BluetoothRepository(client: client),
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<BluetoothCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(19),
              child: BluetoothTrayBody(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('WiFi face', () {
    testWidgets('lists networks with their state on the right', (tester) async {
      await pumpWifi(tester, _FakeWifiClient());

      expect(find.byKey(const Key('wifi_network_Studio-5G')), findsOneWidget);
      expect(find.text(l10n.wifiRowConnected), findsOneWidget);
      expect(find.text(l10n.wifiRowOpen), findsOneWidget);
      // The associated network is listed once, from the status, not twice.
      expect(find.text('Studio-5G'), findsOneWidget);
      expect(find.text('192.168.1.42'), findsOneWidget);
    });

    testWidgets(
      'switched off, the title row is the whole face',
      (tester) async {
        final client = _FakeWifiClient()..enabled = false;
        await pumpWifi(tester, client);

        expect(find.byKey(const Key('wifi_power')), findsOneWidget);
        // No list, and no rescan button for a radio that cannot scan.
        expect(find.byKey(const Key('wifi_scan')), findsNothing);
        expect(find.byType(ConsoleCard), findsNothing);
      },
    );

    testWidgets('the power switch drives the radio', (tester) async {
      final client = _FakeWifiClient();
      await pumpWifi(tester, client);

      await tester.tap(find.byKey(const Key('wifi_power')));
      await tester.pumpAndSettle();

      expect(client.calls, contains('setEnabled:false'));
      expect(find.byType(ConsoleCard), findsNothing);
    });

    testWidgets(
      'a saved row opens in place and offers disconnect + forget',
      (tester) async {
        final client = _FakeWifiClient();
        await pumpWifi(tester, client);

        expect(find.byKey(const Key('wifi_disconnect')), findsNothing);

        await tester.tap(find.byKey(const Key('wifi_network_Studio-5G')));
        await tester.pumpAndSettle();

        expect(find.byType(ConsoleExpandedRow), findsOneWidget);
        expect(find.byKey(const Key('wifi_disconnect')), findsOneWidget);
        expect(find.byKey(const Key('wifi_forget')), findsOneWidget);

        await tester.tap(find.byKey(const Key('wifi_disconnect')));
        await tester.pumpAndSettle();
        expect(client.calls, contains('disconnect'));
      },
    );

    testWidgets('forgetting confirms first', (tester) async {
      final client = _FakeWifiClient();
      await pumpWifi(tester, client);

      await tester.tap(find.byKey(const Key('wifi_network_Studio-5G')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();

      // Nothing has happened yet — the dialog is the point.
      expect(client.calls, isNot(contains('forget:Studio-5G')));
      expect(find.text(l10n.wifiForgetConfirmBody), findsOneWidget);

      await tester.tap(find.text(l10n.networkKeepItAction));
      await tester.pumpAndSettle();
      expect(client.calls, isNot(contains('forget:Studio-5G')));

      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget_confirm')));
      await tester.pumpAndSettle();
      expect(client.calls, contains('forget:Studio-5G'));
    });

    testWidgets('an open network joins straight from the row', (tester) async {
      final client = _FakeWifiClient();
      await pumpWifi(tester, client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(client.calls, contains('connect:Cafe Free:'));
    });

    testWidgets(
      'a secured network asks for a passphrase, and short ones are refused',
      (tester) async {
        final client = _FakeWifiClient();
        await pumpWifi(tester, client);

        await tester.tap(find.byKey(const Key('wifi_network_Studio-Guest')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const Key('wifi_join_field')), findsOneWidget);

        // Four characters is under the WPA2 floor: the sheet says so and stays
        // open rather than handing the supplicant something that cannot work.
        for (final key in ['s', 'e', 'g', 'n']) {
          await tester.tap(find.widgetWithText(InkWell, key).first);
          await tester.pump();
        }
        await tester.tap(find.widgetWithText(InkWell, l10n.wifiJoinAction));
        await tester.pump();

        expect(find.byKey(const Key('wifi_join_error')), findsOneWidget);
        expect(client.calls.where((c) => c.startsWith('connect:')), isEmpty);

        await tester.tap(find.widgetWithText(InkWell, 'o'));
        await tester.tap(find.widgetWithText(InkWell, 'p'));
        await tester.tap(find.widgetWithText(InkWell, 'q'));
        await tester.tap(find.widgetWithText(InkWell, 'r'));
        await tester.pump();
        await tester.tap(find.widgetWithText(InkWell, l10n.wifiJoinAction));
        await tester.pumpAndSettle();

        expect(client.calls, contains('connect:Studio-Guest:segnopqr'));
      },
    );

    testWidgets('a failed join explains itself and offers a retry', (
      tester,
    ) async {
      final client = _FakeWifiClient()..failJoin = true;
      await pumpWifi(tester, client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_error_retry')), findsOneWidget);
      expect(find.text(l10n.wifiHeaderJoinFailed), findsOneWidget);
    });
  });

  group('Bluetooth face', () {
    testWidgets('lists devices and the console visibility switches', (
      tester,
    ) async {
      await pumpBluetooth(tester, _FakeBluetoothClient());

      expect(find.text('WH-1000XM4'), findsOneWidget);
      expect(find.text('headphones'), findsOneWidget);
      expect(find.text(l10n.bluetoothConnectedLabel), findsOneWidget);
      expect(find.byKey(const Key('bluetooth_discoverable')), findsOneWidget);
      expect(find.byKey(const Key('bluetooth_advertise')), findsOneWidget);
      expect(find.text(l10n.bluetoothDiscoverableSubtitle), findsOneWidget);
    });

    testWidgets('a paired row opens with disconnect + forget', (tester) async {
      final client = _FakeBluetoothClient();
      await pumpBluetooth(tester, client);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_AA:BB:CC:11:22:33')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bluetooth_disconnect')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bluetooth_disconnect')));
      await tester.pumpAndSettle();

      expect(client.calls, contains('disconnect:AA:BB:CC:11:22:33'));
    });

    testWidgets('an unpaired device pairs straight from the row', (
      tester,
    ) async {
      final client = _FakeBluetoothClient();
      await pumpBluetooth(tester, client);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_11:22:33:44:55:66')),
      );
      await tester.pumpAndSettle();

      expect(client.calls, contains('pair:11:22:33:44:55:66'));
    });

    testWidgets('forgetting a device confirms first', (tester) async {
      final client = _FakeBluetoothClient();
      await pumpBluetooth(tester, client);

      await tester.tap(
        find.byKey(const Key('bluetooth_device_AA:BB:CC:11:22:33')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bluetooth_forget')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.bluetoothForgetConfirmBody), findsOneWidget);
      expect(client.calls, isNot(contains('forget:AA:BB:CC:11:22:33')));

      await tester.tap(find.byKey(const Key('bluetooth_forget_confirm')));
      await tester.pumpAndSettle();
      expect(client.calls, contains('forget:AA:BB:CC:11:22:33'));
    });

    testWidgets('switched off, the title row is the whole face', (
      tester,
    ) async {
      final client = _FakeBluetoothClient()..powered = false;
      await pumpBluetooth(tester, client);

      expect(find.byKey(const Key('bluetooth_power')), findsOneWidget);
      expect(find.byKey(const Key('bluetooth_scan')), findsNothing);
      expect(find.byType(ConsoleCard), findsNothing);
    });
  });
}
