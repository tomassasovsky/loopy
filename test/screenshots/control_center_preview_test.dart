@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
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
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/system/system_tab.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

/// What the appliance reports about its own build. A real [UpdateCubit] over
/// the unsupported backend knows neither its version nor its channel, and the
/// About face correctly drops the row that would have said so — which makes
/// for a golden of the empty case rather than of the face.
final _consoleBuild = UpdateState(
  supported: true,
  channel: 'experimental',
  currentVersion: Version.parse('0.1.0'),
);

/// What the host reports for `AUDIO / settings-device`: an 18-in interface
/// listed in both directions, and the built-in pair. Both sides carry their
/// real channel counts, which is the fact the engine was never asking
/// miniaudio for.
const _previewDevices = <AudioDevice>[
  AudioDevice(
    id: 'scarlett-out',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: false,
    outputChannels: 20,
  ),
  AudioDevice(
    id: 'scarlett-in',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: true,
    inputChannels: 18,
  ),
  AudioDevice(
    id: 'builtin-out',
    name: 'Built-in audio',
    isDefault: true,
    isInput: false,
    outputChannels: 2,
  ),
  AudioDevice(
    id: 'builtin-in',
    name: 'Built-in audio',
    isDefault: true,
    isInput: true,
    inputChannels: 2,
  ),
];

/// What the engine reports while the Scarlett is open — the figures the Status
/// tab reads, and the device name the Device row falls back to.
const _previewStatus = EngineStatus(
  isConnected: true,
  deviceName: 'Scarlett 18i20',
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 18,
  outputChannels: 20,
  devicePresent: true,
  latencyState: LatencyState.done,
  measuredLatencyMs: 7.42,
  recordOffsetFrames: 64,
);

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
  setUpAll(() => registerFallbackValue(const EngineConfig()));
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
  ({
    ControlCubit control,
    MidiSetupCubit midi,
    LooperRepository looper,
    LooperBloc bloc,
    TracksCubit tracks,
    QuantizeCubit quantize,
    InputsCubit inputs,
    AudioSetupCubit audio,
    TempoCubit tempo,
    RecordOptionsCubit options,
  })
  controlProviders(
    WidgetTester tester, {
    MidiConnection connection = const MidiConnection(),
    LooperState looperState = const LooperState(),
  }) {
    final looper = _MockLooperRepository();
    final looperStates = StreamController<LooperState>.broadcast();
    addTearDown(looperStates.close);
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: _previewStatus,
      ),
    );
    when(looper.allMonitors).thenReturn(const {});
    when(looper.allLaneChains).thenReturn(const {});
    when(looper.allTrackChains).thenReturn(const {});
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.masterEffects).thenAnswer((_) => _masterChain);
    when(() => looper.chainEntriesAt(_master)).thenAnswer((_) => _masterChain);
    when(looper.masterChainEnvelope).thenReturn(const FxChainEnvelope());
    // What `AUDIO / settings-device` draws: an interface the host reports in
    // both directions with its real channel counts, and the built-in pair.
    when(looper.devices).thenReturn(_previewDevices);
    when(looper.asioDrivers).thenReturn(const <AudioDevice>[]);
    when(looper.detectLoopback).thenReturn(
      const LoopbackInfo(
        available: true,
        kind: LoopbackKind.virtualDevice,
        deviceName: 'Scarlett 18i20',
      ),
    );
    // The saved config the cubit hydrates from — this is how the Scarlett is
    // the PINNED device without the preview having to open one.
    when(looper.stopEngine).thenReturn(EngineResult.ok);
    when(() => looper.startEngine(any())).thenReturn(EngineResult.ok);
    when(looper.measureLatency).thenReturn(EngineResult.ok);
    when(() => looper.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'scarlett-out',
        captureDeviceId: 'scarlett-in',
      ),
    );

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
    // The Loop face's own providers. A mock bloc rather than a real one over
    // the mock repository: these previews exist to pin a specific transport,
    // and a real bloc would only ever show the repository's defaults.
    final bloc = _MockLooperBloc();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: looperState,
    );
    when(() => bloc.state).thenReturn(looperState);
    final tempo = TempoCubit(repository: looper, settings: settings);
    final options = RecordOptionsCubit(repository: looper, settings: settings);
    final tracks = TracksCubit(settings: settings);
    final inputs = InputsCubit(settings: settings, repository: looper);
    final quantize = QuantizeCubit(repository: looper, settings: settings);
    final audio = AudioSetupCubit(
      repository: looper,
      settings: settings,
      // No re-enumeration: the preview's device list never changes, and a
      // periodic timer live for the length of the test body fails the
      // binding's own invariant check before any tearDown can cancel it.
      deviceRefreshInterval: Duration.zero,
    );
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(quantize.close()));
    addTearDown(() => unawaited(audio.close()));
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(midi.close()));
    addTearDown(() => unawaited(tempo.close()));
    addTearDown(() => unawaited(options.close()));
    return (
      control: control,
      midi: midi,
      looper: looper,
      bloc: bloc,
      tempo: tempo,
      options: options,
      tracks: tracks,
      quantize: quantize,
      inputs: inputs,
      audio: audio,
    );
  }

  /// The System face's own providers. The real tray inherits these from
  /// `App`; a preview showing the System destination has to stand them up too.
  ///
  /// The facts client is the FAKE at zero latency — that is the whole point of
  /// the seam: Storage and About are drivable, and photographable, from a
  /// desktop. Zero rather than the fake's own pretend latency because even a
  /// zero-duration delay schedules a timer a `testWidgets` body would wait on
  /// forever.
  ({
    WaveformWindowCubit waveform,
    HighContrastCubit contrast,
    RefreshRateCubit refresh,
    ConsoleFactsCubit facts,
    PedalCubit pedal,
    UpdateCubit update,
  })
  systemProviders(
    WidgetTester tester, {
    required LooperRepository looper,
    required SettingsRepository settings,
    ConsoleFactsClient? client,
    UpdateState? updateState,
  }) {
    final waveform = WaveformWindowCubit(settings: settings);
    final contrast = HighContrastCubit(settings: settings);
    final refresh = RefreshRateCubit(repository: looper, settings: settings);
    final facts = ConsoleFactsCubit(
      client: client ?? FakeConsoleFactsClient(latency: Duration.zero),
      settings: settings,
    );
    final pedal = PedalCubit(
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      pollInterval: Duration.zero,
    );
    final update = _MockUpdateCubit();
    whenListen(
      update,
      const Stream<UpdateState>.empty(),
      initialState: updateState ?? _consoleBuild,
    );
    addTearDown(() => unawaited(waveform.close()));
    addTearDown(() => unawaited(contrast.close()));
    addTearDown(() => unawaited(refresh.close()));
    addTearDown(() => unawaited(facts.close()));
    addTearDown(() => unawaited(pedal.close()));
    return (
      waveform: waveform,
      contrast: contrast,
      refresh: refresh,
      facts: facts,
      pedal: pedal,
      update: update,
    );
  }

  Future<void> pumpTray(
    WidgetTester tester, {
    required SettingsTrayCubit cubit,
    WifiRepository? wifi,
    BluetoothRepository? bluetooth,
    ({
      WaveformWindowCubit waveform,
      HighContrastCubit contrast,
      RefreshRateCubit refresh,
      ConsoleFactsCubit facts,
      PedalCubit pedal,
      UpdateCubit update,
    })?
    system,
    ({
      ControlCubit control,
      MidiSetupCubit midi,
      LooperRepository looper,
      LooperBloc bloc,
      TracksCubit tracks,
      QuantizeCubit quantize,
      InputsCubit inputs,
      AudioSetupCubit audio,
      TempoCubit tempo,
      RecordOptionsCubit options,
    })?
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
              BlocProvider<LooperBloc>.value(value: rig.bloc),
              BlocProvider.value(value: rig.tempo),
              BlocProvider.value(value: rig.options),
              BlocProvider.value(value: rig.tracks),
              BlocProvider.value(value: rig.quantize),
              BlocProvider.value(value: rig.inputs),
              BlocProvider.value(value: rig.audio),
              if (system case final s?) ...[
                BlocProvider.value(value: s.waveform),
                BlocProvider.value(value: s.contrast),
                BlocProvider.value(value: s.refresh),
                BlocProvider.value(value: s.facts),
                BlocProvider.value(value: s.pedal),
                BlocProvider.value(value: s.update),
              ],
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
    expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);
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

  /// The rig the Loop previews draw: a live 120 bpm grid, the click on while
  /// recording out of the first pair of outputs, and four tracks.
  const loopRig = LooperState(
    tracks: [
      Track(state: TrackState.playing, lengthFrames: 96000),
      Track(channel: 1, state: TrackState.playing, lengthFrames: 96000),
      Track(channel: 2),
      Track(channel: 3),
    ],
    status: EngineStatus(sampleRate: 48000, outputChannels: 4),
    transport: TransportState(
      isRunning: true,
      tempoBpm: 120,
      tempoSource: TempoSource.manual,
      quantizeDiv: GridDivision.bar,
      countInBars: 1,
      clickMode: ClickMode.rec,
      clickMask: 0x3,
      clickVolume: 1.4,
      masterLengthFrames: 96000,
    ),
  );

  Future<void> pumpLoop(WidgetTester tester, LoopTab tab) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.loop)
      ..showLoopTab(tab);
    addTearDown(cubit.close);

    await pumpTray(
      tester,
      cubit: cubit,
      control: controlProviders(tester, looperState: loopRig),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('loop domain, tempo tab', (tester) async {
    await pumpLoop(tester, LoopTab.tempo);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_tempo.png'),
    );
  }, skip: !hasFonts);

  testWidgets('loop domain, the time signature grid open', (tester) async {
    await pumpLoop(tester, LoopTab.tempo);
    // Seventeen options. As a column of rows this is a 1,200px scroll inside
    // an 830px sheet, each row spending its whole width on four characters.
    await tester.tap(find.byKey(const Key('loop_signature_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_signature.png'),
    );
  }, skip: !hasFonts);

  testWidgets('loop domain, click tab', (tester) async {
    await pumpLoop(tester, LoopTab.click);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_click.png'),
    );
  }, skip: !hasFonts);

  testWidgets('loop domain, mode tab with the mode chooser open', (
    tester,
  ) async {
    await pumpLoop(tester, LoopTab.mode);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_mode.png'),
    );

    // Opens in place, under the row — the shape `LOOP / settings-mode-confirm`
    // draws, and the same one `AUDIO / settings-rate` draws for its own pick.
    await tester.tap(find.byKey(const Key('loop_mode_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_loop_mode_chooser.png'),
    );
  }, skip: !hasFonts);

  testWidgets('loop domain, the tempo keypad sheet', (tester) async {
    await pumpLoop(tester, LoopTab.tempo);
    await tester.tap(find.byKey(const Key('loop_tempo_row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tempo_keypad_sheet')), findsOneWidget);
    // MaterialApp, not Scaffold: a modal route lives in the navigator's
    // overlay, above the Scaffold that opened it.
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_loop_tempo_sheet.png'),
    );
  }, skip: !hasFonts);

  /// The rig the Tracks previews draw, as `TRACKS / tracks-routing` sets it:
  /// a track on two inputs, one on one, one sent three ways, and one that
  /// records nothing and reaches nothing.
  ///
  /// A bare `Lane()` already records nothing out of the first output pair, so
  /// only the departures from that are spelled out.
  const tracksRig = LooperState(
    tracks: [
      Track(
        lengthPresetBars: 8,
        lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
      ),
      Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
      Track(channel: 2, lanes: [Lane(inputChannel: 0, outputMask: 0x7)]),
      Track(channel: 3, lanes: [Lane(outputMask: 0)]),
    ],
    status: EngineStatus(
      sampleRate: 48000,
      inputChannels: 4,
      outputChannels: 4,
    ),
  );

  Future<void> pumpTracks(WidgetTester tester, TracksTab tab) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.tracks)
      ..showTracksTab(tab);
    addTearDown(cubit.close);

    final providers = controlProviders(tester, looperState: tracksRig);
    for (final (channel, name) in ['drums', 'bass', 'rhythm', 'lead'].indexed) {
      await providers.tracks.rename(channel, name);
    }
    await pumpTray(tester, cubit: cubit, control: providers);
    await tester.pumpAndSettle();
  }

  testWidgets('tracks domain, names tab', (tester) async {
    await pumpTracks(tester, TracksTab.names);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_names.png'),
    );
  }, skip: !hasFonts);

  testWidgets('tracks domain, lengths tab with a preset grid open', (
    tester,
  ) async {
    await pumpTracks(tester, TracksTab.lengths);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_lengths.png'),
    );

    await tester.tap(find.byKey(const Key('tracks_lengths_row_0')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_length_pick.png'),
    );
  }, skip: !hasFonts);

  testWidgets('tracks domain, routing tab', (tester) async {
    await pumpTracks(tester, TracksTab.routing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_routing.png'),
    );
  }, skip: !hasFonts);

  testWidgets('tracks domain, a stopped engine has no tracks', (tester) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.tracks);
    addTearDown(cubit.close);
    await pumpTray(
      tester,
      cubit: cubit,
      control: controlProviders(tester),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_tracks_empty.png'),
    );
  }, skip: !hasFonts);

  testWidgets('tracks domain, the routing panel on an 8-input rig', (
    tester,
  ) async {
    // The case the 4-input drawing never showed: the lane list runs past the
    // panel, so it scrolls under its pinned caption while QUANTIZE RECORDING
    // and Done stay where they are.
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.tracks)
      ..showTracksTab(TracksTab.routing);
    addTearDown(cubit.close);
    final providers = controlProviders(
      tester,
      looperState: const LooperState(
        tracks: [
          Track(lanes: [Lane(inputChannel: 0)]),
        ],
        status: EngineStatus(
          sampleRate: 48000,
          inputChannels: 8,
          outputChannels: 8,
        ),
      ),
    );
    await providers.tracks.rename(0, 'drums');
    await pumpTray(tester, cubit: cubit, control: providers);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('track_routing_input_0')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_track_routing_tall.png'),
    );

    // Scrolled into the middle of the lane list: the LANES caption is still
    // overhead, and QUANTIZE RECORDING has not moved.
    await tester.drag(
      find.byKey(const Key('track_routing_input_2')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_track_routing_scrolled.png'),
    );

    // Scrolled to the end: QUANTIZE RECORDING has taken the pinned slot and
    // pushed LANES out — the handover that makes both captions sticky.
    // Dragged from a row that is actually on screen: a drag on an off-screen
    // finder warps the pointer and never reaches the scrollable.
    await tester.drag(
      find.byKey(const Key('track_routing_input_5')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_track_routing_handover.png'),
    );
  }, skip: !hasFonts);

  testWidgets("tracks domain, a track's own routing panel", (tester) async {
    await pumpTracks(tester, TracksTab.routing);
    await tester.tap(find.byKey(const Key('tracks_routing_row_0')));
    await tester.pumpAndSettle();
    // The open lane is what the panel is FOR: a checked input is a lane row,
    // and it carries that lane's own outputs.
    await tester.tap(find.byKey(const Key('track_routing_input_1')));
    await tester.pumpAndSettle();

    // MaterialApp, not Scaffold: a dialog route lives in the navigator's
    // overlay, above the Scaffold that opened it.
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_track_routing.png'),
    );
  }, skip: !hasFonts);

  testWidgets('tracks domain, the console rename sheet', (tester) async {
    await pumpTracks(tester, TracksTab.names);
    await tester.tap(find.byKey(const Key('tracks_names_row_2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_track_rename.png'),
    );
  }, skip: !hasFonts);

  /// The rig the Audio previews draw: an open device on a 48k/128 clock, with
  /// the latency measured and a record offset applied.
  const audioRig = LooperState(tracks: [Track()], status: _previewStatus);

  Future<
    ({
      ControlCubit control,
      MidiSetupCubit midi,
      LooperRepository looper,
      LooperBloc bloc,
      TracksCubit tracks,
      QuantizeCubit quantize,
      InputsCubit inputs,
      AudioSetupCubit audio,
      TempoCubit tempo,
      RecordOptionsCubit options,
    })
  >
  pumpAudio(WidgetTester tester, AudioTab tab) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.audio)
      ..showAudioTab(tab);
    addTearDown(cubit.close);

    final providers = controlProviders(tester, looperState: audioRig);
    // Two of the eighteen sockets have been given names, which is what the
    // Device row's `2 named` counts.
    await providers.inputs.rename(0, 'guitar');
    await providers.inputs.rename(1, 'mic');
    await pumpTray(tester, cubit: cubit, control: providers);
    await tester.pumpAndSettle();
    return providers;
  }

  testWidgets('audio domain, device tab with the device list open', (
    tester,
  ) async {
    await pumpAudio(tester, AudioTab.device);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_device.png'),
    );

    // Opened, because the per-device channel counts are the part worth
    // pinning: they read 0 in / 0 out until the engine started asking.
    await tester.tap(find.byKey(const Key('audio_device_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_device_list.png'),
    );
  }, skip: !hasFonts);

  testWidgets('audio domain, the rate and buffer grids', (
    tester,
  ) async {
    await pumpAudio(tester, AudioTab.device);
    await tester.tap(find.byKey(const Key('audio_rate_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_rate.png'),
    );
  }, skip: !hasFonts);

  testWidgets('audio domain, the named inputs', (tester) async {
    await pumpAudio(tester, AudioTab.device);
    await tester.tap(find.byKey(const Key('audio_inputs_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_inputs.png'),
    );
  }, skip: !hasFonts);

  testWidgets('audio domain, recording tab', (tester) async {
    await pumpAudio(tester, AudioTab.recording);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_recording.png'),
    );

    await tester.tap(find.byKey(const Key('audio_max_loop_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_max_loop.png'),
    );
  }, skip: !hasFonts);

  testWidgets('audio domain, a config the device refused', (tester) async {
    // The open SUCCEEDS and the device runs 48 anyway — the negotiation this
    // banner is for. (A device that will not open at all is a different state
    // and a different banner: `audio_open_failed_banner`, which names the
    // engine's error rather than a rate nothing asked to change.) The
    // selection has snapped back to what the device gave, so the banner is the
    // only place the request is still named.
    await pumpAudio(tester, AudioTab.device);
    await tester.tap(find.byKey(const Key('audio_rate_row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('audio_sample_rate_96000')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_audio_refused.png'),
    );
  }, skip: !hasFonts);

  /// Mounts the System face on [tab].
  Future<ConsoleFactsCubit> pumpSystem(
    WidgetTester tester,
    SystemTab tab, {
    ConsoleFactsClient? client,
    UpdateState? updateState,
  }) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final cubit = SettingsTrayCubit(settings: settings)
      ..open()
      ..showDestination(SettingsTrayDestination.system)
      ..showSystemTab(tab);
    addTearDown(cubit.close);

    final rig = controlProviders(tester, looperState: audioRig);
    final system = systemProviders(
      tester,
      looper: rig.looper,
      settings: settings,
      client: client,
      updateState: updateState,
    );
    await pumpTray(tester, cubit: cubit, control: rig, system: system);
    await tester.pumpAndSettle();
    return system.facts;
  }

  testWidgets('system domain, display tab', (tester) async {
    await pumpSystem(tester, SystemTab.display);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_display.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, the second window did not open', (tester) async {
    await pumpSystem(tester, SystemTab.display);
    // The failure the app shell reports, at the top of the list the setting
    // lives in — never a toast once this face is open.
    tester
        .element(find.byKey(const Key('system_display_tab')))
        .read<WaveformWindowCubit>()
        .reportOpenFailed();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_waveform_failed.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, updates tab', (tester) async {
    await pumpSystem(tester, SystemTab.updates);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_updates.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, an update on offer', (tester) async {
    await pumpSystem(
      tester,
      SystemTab.updates,
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.available,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_update_available.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, staging to the standby system', (tester) async {
    await pumpSystem(
      tester,
      SystemTab.updates,
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.downloading,
        progress: 0.42,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_update_downloading.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, staged and waiting for a restart', (
    tester,
  ) async {
    await pumpSystem(
      tester,
      SystemTab.updates,
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.staged,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_update_staged.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, the check failed', (tester) async {
    await pumpSystem(
      tester,
      SystemTab.updates,
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.error,
        errorMessage: 'could not reach the update server.',
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_update_error.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, storage tab', (tester) async {
    await pumpSystem(tester, SystemTab.storage);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_storage.png'),
    );
  }, skip: !hasFonts);

  /// Puts the licence registry in the state both LEGAL goldens are drawn
  /// against: exactly these three packages, and nothing an earlier test left.
  ///
  /// Called by BOTH of them rather than once by whichever runs first. The
  /// registry is process-global and accumulates, so a golden that inherits its
  /// predecessor's registration passes in file order and fails the moment it
  /// runs alone, under `--plain-name`, or with a randomised ordering seed —
  /// and the About row draws the COUNT, so an inherited registry is an
  /// inherited pixel.
  void seedLicences() {
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(
      () => Stream.fromIterable([
        const LicenseEntryWithLineBreaks(
          ['segno'],
          'GNU GENERAL PUBLIC LICENSE\n\nVersion 3, 29 June 2007\n\nThis '
          'program is free software: you can redistribute it and/or modify '
          'it under the terms of the GNU General Public License as '
          'published by the Free Software Foundation, either version 3 of '
          'the License, or (at your option) any later version.',
        ),
        const LicenseEntryWithLineBreaks(['miniaudio'], 'Public domain.'),
        const LicenseEntryWithLineBreaks(['vst3sdk'], 'MIT License'),
      ]),
    );
  }

  testWidgets('system domain, the open-source notices panel', (tester) async {
    seedLicences();
    await pumpSystem(tester, SystemTab.about);
    await tester.tap(find.byKey(const Key('system_about_notices')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('console_licence_segno')));
    await tester.pumpAndSettle();

    await expectLater(
      // MaterialApp, not Scaffold: the panel is a route in the navigator's
      // overlay, which sits ABOVE the Scaffold rather than inside it.
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/control_center_system_licences.png'),
    );
  }, skip: !hasFonts);

  testWidgets('system domain, about tab', (tester) async {
    seedLicences();
    await pumpSystem(tester, SystemTab.about);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/control_center_system_about.png'),
    );
  }, skip: !hasFonts);
}
