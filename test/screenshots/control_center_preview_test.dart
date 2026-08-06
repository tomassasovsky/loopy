@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../helpers/helpers.dart';

ThemeData _theme() => ThemeData(
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(
      File(p).readAsBytes().then((b) => ByteData.view(b.buffer)),
    );
  }
  await loader.load();
}

/// Home-tray preview: radio on, not associated — proves tile "on" ≠ connected.
class _PreviewWifiHomeClient implements WifiClient {
  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => const WifiStatus(
    supported: true,
    enabled: true,
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
  Future<void> setEnabled({required bool enabled}) async {}
}

/// Drawn to `NETWORK / wifi`: an associated saved network, a saved one out of
/// range, a secured one to join and an open one — the four row states the
/// mockups put in the card.
class _PreviewWifiClient implements WifiClient {
  _PreviewWifiClient({this.enabled = true});

  bool enabled;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: enabled,
    ssid: enabled ? 'MyHouseWTF_es' : '',
    ip: enabled ? '192.168.50.212' : '',
    signal: -42,
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [
    WifiNetwork(
      ssid: 'MyHouseWTF_es',
      signal: -42,
      secured: true,
      saved: true,
    ),
    WifiNetwork(
      ssid: 'MyHouseWTF_es_2.4G',
      signal: -80,
      secured: true,
      saved: true,
      inRange: false,
    ),
    WifiNetwork(ssid: 'Studio 5G', signal: -48, secured: true),
    WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
  ];

  @override
  Future<void> connect(String ssid, {String? psk}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {}
}

/// Home-tray preview: powered on without discoverable/advertise.
class _PreviewBluetoothHomeClient implements BluetoothClient {
  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => const BluetoothStatus(
    supported: true,
    powered: true,
    discoverable: false,
    advertising: false,
    alias: 'Segno',
  );

  @override
  Future<List<BluetoothDevice>> scan() async => const [];

  @override
  Future<void> setPowered({required bool enabled}) async {}

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}

  @override
  Future<void> pair(String address) async {}

  @override
  Future<void> connect(String address) async {}

  @override
  Future<void> disconnect(String address) async {}

  @override
  Future<void> forget(String address) async {}
}

class _PreviewBluetoothClient implements BluetoothClient {
  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => const BluetoothStatus(
    supported: true,
    powered: true,
    discoverable: true,
    advertising: true,
    alias: 'Segno',
  );

  /// Drawn to `NETWORK / bluetooth`: a connected device, a paired one out of
  /// range, and a fresh one.
  @override
  Future<List<BluetoothDevice>> scan() async => const [
    BluetoothDevice(
      name: 'WH-1000XM4',
      address: 'AA:AA:AA:AA:AA:AA',
      paired: true,
      connected: true,
      kind: BluetoothDeviceKind.headphones,
    ),
    BluetoothDevice(
      name: 'Page turner',
      address: 'BB:BB:BB:BB:BB:BB',
      paired: true,
      inRange: false,
      kind: BluetoothDeviceKind.keyboard,
    ),
    BluetoothDevice(name: 'AirTurn BT-200', address: 'CC:CC:CC:CC:CC:CC'),
  ];

  @override
  Future<void> setPowered({required bool enabled}) async {}

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}

  @override
  Future<void> pair(String address) async {}

  @override
  Future<void> connect(String address) async {}

  @override
  Future<void> disconnect(String address) async {}

  @override
  Future<void> forget(String address) async {}
}

void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  final hasFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasFonts) return;
    await _loadFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await _loadFont('MaterialIcons', [
      '$fontDir/MaterialIcons-Regular.otf',
    ]);
    // The console's own faces set state words and disclosure markers in the
    // bundled mono face. Without it they render as tofu and the golden is
    // useless for the eyeballing it exists to support.
    await _loadFont(SurfaceTheme.monoFont, [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
    ]);
  });

  Future<void> size(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpTray(
    WidgetTester tester, {
    required SettingsTrayCubit cubit,
    WifiRepository? wifi,
    BluetoothRepository? bluetooth,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(
              value:
                  wifi ?? const WifiRepository(client: UnsupportedWifiClient()),
            ),
            RepositoryProvider.value(
              value:
                  bluetooth ??
                  const BluetoothRepository(
                    client: UnsupportedBluetoothClient(),
                  ),
            ),
          ],
          child: BlocProvider.value(
            value: cubit,
            child: Scaffold(
              body: Stack(
                children: [
                  const ColoredBox(color: Color(0xFF1A1520)),
                  SettingsTray(
                    wifiRepository: wifi,
                    bluetoothRepository: bluetooth,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tray open', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..open();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiHomeClient()),
      bluetooth: BluetoothRepository(client: _PreviewBluetoothHomeClient()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tray.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, wifi tab', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiClient()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_wifi.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, wifi off', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiClient(enabled: false)),
    );
    await tester.pumpAndSettle();
    // The face is one switch and nothing else — there is nothing truthful to
    // list about a radio that is down.
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_wifi_off.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, wifi row open', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiClient()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wifi_network_MyHouseWTF_es')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_wifi_expanded.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, forget confirm', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiClient()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wifi_network_MyHouseWTF_es')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wifi_forget')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network_forget_confirm')), findsOneWidget);
    // The confirm rides in the route overlay, above the Scaffold.
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_network_wifi_forget.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, join sheet', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiClient()),
    );
    await tester.pumpAndSettle();
    // A secured network the console has no credential for opens the sheet.
    await tester.tap(find.byKey(const Key('wifi_network_Studio 5G')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_network_wifi_join.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, bluetooth tab', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openBluetooth();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      bluetooth: BluetoothRepository(client: _PreviewBluetoothClient()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_bluetooth.png'),
    );
  }, skip: !hasFonts);

  testWidgets('network domain, bluetooth row open', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openBluetooth();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      bluetooth: BluetoothRepository(client: _PreviewBluetoothClient()),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('bluetooth_device_AA:AA:AA:AA:AA:AA')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_bt_expanded.png'),
    );
  }, skip: !hasFonts);
}
