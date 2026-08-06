@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/loop/loop_tray_panel.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno_engine/segno_engine.dart'
    as snapshot
    show EngineSnapshot, LaneSnapshot, LatencyState, TrackSnapshot;
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

class _PreviewWifiClient implements WifiClient {
  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => const WifiStatus(
    supported: true,
    enabled: true,
    connected: true,
    ssid: 'Studio-5G',
    ip: '192.168.1.42',
    signal: -48,
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [
    WifiNetwork(ssid: 'Studio-5G', signal: -48, secured: true, saved: true),
    WifiNetwork(
      ssid: 'Studio-Backline',
      signal: -70,
      secured: true,
      saved: true,
      inRange: false,
    ),
    WifiNetwork(ssid: 'Studio-Guest', signal: -62, secured: true),
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

/// Radio present but switched off — the mockups' `wifi-off` / `bluetooth-off`.
class _PreviewWifiOffClient implements WifiClient {
  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async =>
      const WifiStatus(supported: true, enabled: false, connected: false);

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

  @override
  Future<List<BluetoothDevice>> scan() async => const [
    BluetoothDevice(
      name: 'WH-1000XM4',
      address: 'AA:BB:CC:11:22:33',
      paired: true,
      connected: true,
      kind: 'headphones',
    ),
    BluetoothDevice(
      name: 'Page turner',
      address: 'DD:EE:FF:44:55:66',
      paired: true,
      inRange: false,
    ),
    BluetoothDevice(name: 'AirTurn BT-200', address: '11:22:33:44:55:66'),
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

  testWidgets('Network face, WiFi tab', (tester) async {
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

  testWidgets('Network face, Bluetooth tab', (tester) async {
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

  testWidgets('Network face, WiFi switched off', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)..openWifi();
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      wifi: WifiRepository(client: _PreviewWifiOffClient()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_wifi_off.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network face, WiFi row opened', (tester) async {
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
    await tester.tap(find.byKey(const Key('wifi_network_Studio-5G')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_wifi_expanded.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network face, WiFi forget confirmation', (tester) async {
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
    await tester.tap(find.byKey(const Key('wifi_network_Studio-5G')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wifi_forget')));
    await tester.pumpAndSettle();
    await expectLater(
      // The dialog is an overlay entry ABOVE the Scaffold, so capturing the
      // Scaffold alone would photograph the face without the dialog on it.
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_network_wifi_forget.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network face, WiFi join sheet', (tester) async {
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
    // An unsaved, secured network is the one that needs a passphrase.
    await tester.tap(find.byKey(const Key('wifi_network_Studio-Guest')));
    // Pumped rather than settled: the sheet's caret blinks forever, so
    // `pumpAndSettle` would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final key in ['s', 'e', 'g', 'n', 'o']) {
      await tester.tap(find.widgetWithText(InkWell, key).first);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_network_wifi_join.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network face, Bluetooth row opened', (tester) async {
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
      find.byKey(const Key('bluetooth_device_AA:BB:CC:11:22:33')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_network_bt_expanded.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Control face, Pedal tab', (tester) async {
    await size(tester);
    // An explicit (empty) ticker: the default 16ms poll timer outlives the
    // widget tree, and the binding fails a test that leaves one pending.
    final looper = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
      reconnectTicker: const Stream<void>.empty(),
    );
    addTearDown(looper.dispose);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: SettingsRepository(store: FakeKeyValueStore()),
      performance: performance,
      keepAliveInterval: Duration.zero,
      mappingsWriteDebounce: Duration.zero,
    );
    addTearDown(() => unawaited(control.close()));
    final midiDevices = MidiDeviceRepository(
      source: null,
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    // The repository polls for hotplug on a periodic timer; a screenshot must
    // not leave one running past the widget tree.
    addTearDown(() => unawaited(midiDevices.dispose()));
    final midi = MidiSetupCubit(repository: midiDevices);
    addTearDown(() => unawaited(midi.close()));

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<MidiSetupCubit>.value(value: midi),
              BlocProvider<TracksCubit>(
                create: (_) => TracksCubit(
                  settings: SettingsRepository(store: FakeKeyValueStore()),
                ),
              ),
            ],
            child: Scaffold(
              body: ColoredBox(
                color: SurfaceTheme.dark.background,
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(19, 19, 19, 41),
                  child: ControlTrayPanel(
                    tab: ControlTab.pedal,
                    onTabChanged: _ignoreTab,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_control_pedal.png'),
    );
  }, skip: !hasFonts);

  Future<void> pumpLoop(WidgetTester tester, LoopTab tab) async {
    await size(tester);
    // An explicit (empty) ticker: the default 16ms poll timer outlives the
    // widget tree, and the binding fails a test that leaves one pending.
    final looper = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
      reconnectTicker: const Stream<void>.empty(),
    );
    addTearDown(looper.dispose);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
      mappingsWriteDebounce: Duration.zero,
    );
    addTearDown(() => unawaited(control.close()));
    final bloc = LooperBloc(repository: looper);
    addTearDown(() => unawaited(bloc.close()));
    final tempo = TempoCubit(repository: looper, settings: settings);
    addTearDown(() => unawaited(tempo.close()));
    final record = RecordOptionsCubit(repository: looper, settings: settings);
    addTearDown(() => unawaited(record.close()));

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<TempoCubit>.value(value: tempo),
            BlocProvider<RecordOptionsCubit>.value(value: record),
            BlocProvider<ControlCubit>.value(value: control),
          ],
          child: Scaffold(
            body: ColoredBox(
              color: SurfaceTheme.dark.background,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(19, 19, 19, 41),
                child: LoopTrayPanel(tab: tab, onTabChanged: _ignoreLoopTab),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Loop face, Tempo tab', (tester) async {
    await pumpLoop(tester, LoopTab.tempo);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_tempo.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Loop face, Click tab', (tester) async {
    await pumpLoop(tester, LoopTab.click);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_click.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Loop face, Mode tab', (tester) async {
    await pumpLoop(tester, LoopTab.mode);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_mode.png'),
    );
  }, skip: !hasFonts);

  Future<void> pumpTracks(
    WidgetTester tester,
    TracksTab tab, {
    int tracks = 4,
  }) async {
    await size(tester);
    // A stopped engine reports no tracks at all, and a Tracks face with an
    // empty list is not the screen worth pinning. The fake's snapshot is the
    // rig these mockups draw: four tracks, the third recording two inputs
    // into three outputs, the fourth going nowhere.
    final fakeEngine = FakeAudioEngine()
      ..nextSnapshot = snapshot.EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 256,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: snapshot.LatencyState.idle,
        measuredLatencyMs: -1,
        devicePresent: true,
        inputChannels: 4,
        outputChannels: 4,
        tracks: [
          for (var i = 0; i < tracks; i++)
            snapshot.TrackSnapshot(
              state: TrackState.empty,
              volume: 1,
              muted: false,
              lengthFrames: 0,
              undoDepth: 0,
              rms: 0,
              peak: 0,
              lengthPresetBars: i == 0 ? 8 : 0,
              inputMask: switch (i) {
                1 => 0x2,
                3 => 0,
                _ => 0x1,
              },
              outputMask: switch (i) {
                2 => 0x7,
                3 => 0,
                _ => 0x3,
              },
              lanes: [
                for (final input in switch (i) {
                  // Track 3 is the multi-input case the mockups draw: two
                  // inputs, two lanes, one loop.
                  1 => const [1],
                  2 => const [0, 2],
                  3 => const <int>[],
                  _ => const [0],
                })
                  snapshot.LaneSnapshot(
                    inputChannel: input,
                    outputMask: switch (i) {
                      2 => 0x7,
                      _ => 0x3,
                    },
                    volume: 1,
                    muted: false,
                    lengthFrames: 0,
                    rms: 0,
                    peak: 0,
                  ),
              ],
            ),
        ],
      );
    final looper = LooperRepository(
      engine: fakeEngine,
      ticker: const Stream<void>.empty(),
      reconnectTicker: const Stream<void>.empty(),
    );
    addTearDown(looper.dispose);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final bloc = LooperBloc(repository: looper);
    addTearDown(() => unawaited(bloc.close()));
    final names = TracksCubit(settings: settings);
    addTearDown(() => unawaited(names.close()));
    for (final (channel, name) in const [
      (0, 'drums'),
      (1, 'bass'),
      (2, 'rhythm'),
      (3, 'lead'),
    ]) {
      await names.rename(channel, name);
    }
    final quantize = QuantizeCubit(repository: looper, settings: settings);
    addTearDown(() => unawaited(quantize.close()));
    final inputs = InputsCubit(settings: settings);
    addTearDown(() => unawaited(inputs.close()));

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<TracksCubit>.value(value: names),
              BlocProvider<QuantizeCubit>.value(value: quantize),
              BlocProvider<InputsCubit>.value(value: inputs),
            ],
            child: Scaffold(
              body: ColoredBox(
                color: SurfaceTheme.dark.background,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(19, 19, 19, 41),
                  child: TracksTrayPanel(
                    tab: tab,
                    onTabChanged: _ignoreTracksTab,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Tracks face, Names tab', (tester) async {
    await pumpTracks(tester, TracksTab.names);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_names.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Tracks face, Lengths tab', (tester) async {
    await pumpTracks(tester, TracksTab.lengths);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_lengths.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Tracks face, Routing tab', (tester) async {
    await pumpTracks(tester, TracksTab.routing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_routing.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Tracks face, nothing to show', (tester) async {
    await pumpTracks(tester, TracksTab.names, tracks: 0);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_empty.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Loop face, the chip dialog', (tester) async {
    await pumpLoop(tester, LoopTab.tempo);
    await tester.tap(find.byKey(const Key('loop_quantise_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Dialog),
      matchesGoldenFile('goldens/control_center_chip_dialog.png'),
    );
  }, skip: !hasFonts);

  testWidgets("Tracks face, one track's routing sheet", (tester) async {
    await pumpTracks(tester, TracksTab.routing);
    await tester.tap(find.byKey(const Key('track_routing_row_2')));
    await tester.pumpAndSettle();
    // Open the first lane, which is what the mockup draws: a lane's outputs
    // belong to the lane.
    await tester.tap(find.byKey(const Key('track_input_0')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Dialog),
      matchesGoldenFile('goldens/control_center_track_routing_sheet.png'),
    );
  }, skip: !hasFonts);
}

/// The golden pumps one tab; switching is covered by the widget tests.
void _ignoreTracksTab(TracksTab _) {}

/// The golden pumps one tab; switching is covered by the widget tests.
void _ignoreLoopTab(LoopTab _) {}

/// The golden pumps one tab; switching is covered by the widget tests.
void _ignoreTab(ControlTab _) {}
