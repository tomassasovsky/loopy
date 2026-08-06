@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

/// A rig with a Master insert carrying two effects — enough for the assign
/// list to have chains, slots and a bound target to draw.
const _master = FxAddress(stage: FxStage.master);

final _masterChain = <TrackEffect>[
  BuiltInEffect(type: TrackEffectType.drive, slotId: 'slot-drive'),
  BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-reverb'),
];

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

  /// The Control face's own providers — the real tray inherits these from
  /// `App`, so a preview that shows the Control destination has to stand them
  /// up too.
  ({ControlCubit control, MidiSetupCubit midi, LooperRepository looper})
  controlProviders(
    WidgetTester tester, {
    MidiConnection connection = const MidiConnection(),
  }) {
    final looper = _MockLooperRepository();
    final looperStates = StreamController<LooperState>.broadcast();
    addTearDown(looperStates.close);
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(looper.allMonitors).thenReturn(const {});
    when(looper.allLaneChains).thenReturn(const {});
    when(looper.allTrackChains).thenReturn(const {});
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.masterEffects).thenAnswer((_) => _masterChain);
    when(() => looper.chainEntriesAt(_master)).thenAnswer((_) => _masterChain);
    when(looper.masterChainEnvelope).thenReturn(const FxChainEnvelope());

    final devices = _MockMidiDevices();
    final connections = StreamController<MidiConnection>.broadcast();
    final activity = StreamController<void>.broadcast();
    addTearDown(connections.close);
    addTearDown(activity.close);
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.activity).thenAnswer((_) => activity.stream);
    when(() => devices.connection).thenReturn(connection);

    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    final midi = MidiSetupCubit(repository: devices);
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(midi.close()));
    return (control: control, midi: midi, looper: looper);
  }

  Future<void> pumpTray(
    WidgetTester tester, {
    required SettingsTrayCubit cubit,
    WifiRepository? wifi,
    BluetoothRepository? bluetooth,
    ({ControlCubit control, MidiSetupCubit midi, LooperRepository looper})?
    control,
  }) {
    final rig = control ?? controlProviders(tester);
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
            RepositoryProvider<LooperRepository>.value(value: rig.looper),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: cubit),
              BlocProvider.value(value: rig.control),
              BlocProvider.value(value: rig.midi),
            ],
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
    expect(find.byKey(const Key('console_forget_confirm')), findsOneWidget);
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

  testWidgets('control domain, pedal tab with a switch selected', (
    tester,
  ) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.control);
    addTearDown(cubit.close);

    final rig = controlProviders(tester);
    await rig.control.setGlobalBindings(
      PedalBindingSet([
        PedalBinding(
          key: const PedalBindingKey(button: PedalButton.recPlay),
          target: const FxChainTarget(_master).canonicalString(),
        ),
      ]),
    );
    await pumpTray(tester, cubit: cubit, control: rig);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('pedal_switch_track1')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_control_pedal.png'),
    );

    // And again on bank B, where the same four caps drive tracks 5-8.
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_control_pedal_bank_b.png'),
    );
  }, skip: !hasFonts);

  testWidgets('control domain, midi tab on a live link', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.control)
      ..showControlTab(ControlTab.midi);
    addTearDown(cubit.close);

    final rig = controlProviders(
      tester,
      connection: const MidiConnection(
        devices: [MidiDevice(id: 'dev-1', name: 'Nektar Pacer')],
        selectedId: 'dev-1',
        selectedName: 'Nektar Pacer',
        status: MidiConnectionStatus.connected,
      ),
    );
    await rig.control.setControllerBindings(
      ControllerBindingSet([
        ContinuousBinding(
          trigger: const MappingTrigger(
            kind: ControllerSourceKind.midiCc,
            id: 11,
            midiChannel: 0,
          ),
          target: const MasterGainTarget().canonicalString(),
        ),
        DiscreteBinding(
          trigger: const MappingTrigger(
            kind: ControllerSourceKind.midiNote,
            id: 36,
            midiChannel: 0,
          ),
          target: const FxChainTarget(_master).canonicalString(),
        ),
      ]),
    );
    await pumpTray(tester, cubit: cubit, control: rig);
    await tester.pumpAndSettle();
    // Past the mappings-write debounce, which would otherwise still be
    // pending when the tree comes down.
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_control_midi.png'),
    );
  }, skip: !hasFonts);

  testWidgets('control domain, midi device chooser open', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.control)
      ..showControlTab(ControlTab.midi);
    addTearDown(cubit.close);

    final rig = controlProviders(
      tester,
      connection: const MidiConnection(
        devices: [
          MidiDevice(id: 'dev-1', name: 'Nektar Pacer'),
          MidiDevice(id: 'dev-2', name: 'AirTurn BT-200'),
        ],
        selectedId: 'dev-1',
        selectedName: 'Nektar Pacer',
        status: MidiConnectionStatus.connected,
      ),
    );
    await pumpTray(tester, cubit: cubit, control: rig);
    await tester.pumpAndSettle();
    // Opens in place, under the row — the shape `AUDIO / settings-device`
    // draws for the same question.
    await tester.tap(find.byKey(const Key('midi_device_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_control_midi_device.png'),
    );
  }, skip: !hasFonts);
}
