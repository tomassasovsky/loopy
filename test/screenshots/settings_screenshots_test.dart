@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/looper/view/fx_editor/fx_dock.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// The deterministic golden theme: a bare dark [ThemeData] (fixed font, no
/// seeded colours) carrying the same surface + routing-graph extensions the
/// real app registers (via the shared [routingGraphThemeFromSurface] mapper),
/// so widgets resolving `context.surface` / `context.routingGraph` render
/// correctly under golden capture.
ThemeData _goldenTheme() => ThemeData(
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(
      File(p).readAsBytes().then((b) => ByteData.view(b.buffer)),
    );
  }
  await loader.load();
}

void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // These golden generators load the local Flutter SDK's Material fonts and
  // compare against macOS-rendered goldens, so they only run where those fonts
  // exist — the author's machine. Everywhere else (CI, other contributors) they
  // skip: cross-platform golden rendering would not match the committed goldens
  // anyway. Run them with `flutter test --tags screenshots` on that setup.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    await _loadFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    // The Signal surface's bundled typefaces, so its mono readouts and grotesk
    // headings render as text (not Ahem boxes) under golden capture.
    await _loadFont('Space Grotesk', ['assets/fonts/SpaceGrotesk.ttf']);
    await _loadFont('IBM Plex Mono', [
      'assets/fonts/IBMPlexMono-Regular.ttf',
      'assets/fonts/IBMPlexMono-Medium.ttf',
      'assets/fonts/IBMPlexMono-SemiBold.ttf',
    ]);
  });

  late SettingsRepository settings;
  late LooperRepository repository;
  late AudioSetupCubit audioSetup;
  late MidiDeviceRepository midi;
  late PedalCubit pedal;
  late ControlCubit control;

  const runningAudio = AudioSetupState(
    status: AudioSetupStatus.running,
    devices: [
      AudioDevice(
        id: 'out-1',
        name: 'Scarlett 4i4',
        isDefault: true,
        isInput: false,
      ),
      AudioDevice(
        id: 'in-1',
        name: 'Scarlett Input 1',
        isDefault: true,
        isInput: true,
      ),
    ],
    engineStatus: EngineStatus(
      deviceName: 'Scarlett 4i4',
      sampleRate: 48000,
      bufferFrames: 128,
      isConnected: true,
      inputChannels: 4,
      outputChannels: 4,
      latencyState: LatencyState.done,
      measuredLatencyMs: 9.5,
      recordOffsetFrames: 456,
    ),
  );

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(() => repository.state).thenReturn(
      const LooperState(
        tracks: [Track()],
        status: EngineStatus(inputChannels: 2, outputChannels: 2),
      ),
    );
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    audioSetup = _MockAudioSetupCubit();
    when(() => audioSetup.state).thenReturn(runningAudio);
    midi = _MockMidiDeviceRepository();
    when(() => midi.connection).thenReturn(const MidiConnection());
    when(
      () => midi.connections,
    ).thenAnswer((_) => const Stream<MidiConnection>.empty());
    when(() => midi.activity).thenAnswer((_) => const Stream<void>.empty());
    pedal = _MockPedalCubit();
    when(() => pedal.state).thenReturn(const PedalState());
    whenListen(
      pedal,
      const Stream<PedalState>.empty(),
      initialState: const PedalState(),
    );
    // The real control cubit: the View section reads the looper-wide default
    // mode from it. Its `const ControlState()` default (LooperMode.record) is
    // what the golden captures, so no stubbing is needed — only the keep-alive
    // timer has to go, or it would pump frames under golden capture.
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    // Disposed here rather than by PedalCubit (its lifecycle owner in the real
    // app, and in settings_page_test): the cubit above is a mock, so its close
    // is a no-op and would leave the transport and event streams open.
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1980, 1480)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TracksCubit>.value(
                value: TracksCubit(settings: settings),
              ),
              BlocProvider<WaveformWindowCubit>.value(
                value: WaveformWindowCubit(settings: settings),
              ),
              BlocProvider<HighContrastCubit>.value(
                value: HighContrastCubit(settings: settings),
              ),
              BlocProvider<MidiSetupCubit>.value(
                value: MidiSetupCubit(repository: midi),
              ),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
              BlocProvider<RefreshRateCubit>.value(
                value: RefreshRateCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<QuantizeCubit>.value(
                value: QuantizeCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<MonitorCubit>.value(
                value: MonitorCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<RecordOptionsCubit>.value(
                value: RecordOptionsCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<PedalCubit>.value(value: pedal),
              BlocProvider<ControlCubit>.value(value: control),
            ],
            child: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('View section — tracks defaults', (tester) async {
    await pump(tester);
    // Reveal the PERFORMANCE group (default mode + refresh rate).
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_refreshRate_120')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_view_tracks.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Audio section — recording', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_tab_audio')));
    await tester.pumpAndSettle();
    // Reveal the RECORDING controls (quantize, rec/dub, sound-activated, and
    // the global default loop length).
    await tester.scrollUntilVisible(
      find.byKey(const Key('audioSettings_defaultMultiple_0')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_audio_recording.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Signal surface — inputs, lanes, outputs', (tester) async {
    tester.view
      ..physicalSize = const Size(1980, 1320)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bloc = _ScreenshotLooperBloc();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: LooperState(
        tracks: [
          Track(
            lanes: [
              Lane(
                inputChannel: 0,
                effects: [
                  BuiltInEffect(type: TrackEffectType.filter),
                  BuiltInEffect(type: TrackEffectType.delay),
                ],
              ),
              const Lane(inputChannel: 1),
            ],
          ),
          const Track(channel: 1, lanes: [Lane(inputChannel: 2)]),
        ],
        status: const EngineStatus(
          inputChannels: 4,
          outputChannels: 4,
          isConnected: true,
        ),
      ),
    );

    // One live input carries an FX chain — the tone that records onto a take.
    // A real repository (fake engine) so the monitor's mutations actually land.
    final monitorRepo = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    addTearDown(monitorRepo.dispose);
    final monitor = MonitorCubit(repository: monitorRepo, settings: settings);
    await monitor.setEnabled(0, enabled: true);
    monitor
      ..addEffect(0)
      ..addEffect(0);

    await tester.pumpWidget(
      // Above the MaterialApp's Navigator so the pushed signal page (and its
      // plugin browser / live param readouts) can read the repository.
      RepositoryProvider<LooperRepository>.value(
        value: monitorRepo,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _goldenTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<MonitorCubit>.value(value: monitor),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
              BlocProvider<TracksCubit>(
                create: (_) => TracksCubit(settings: settings),
              ),
            ],
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showSignalPage(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('signal_page')),
      matchesGoldenFile('goldens/signal_surface.png'),
    );
  }, skip: !hasScreenshotFonts);

  // --- FX editor (part 2) ------------------------------------------------

  const editorStatus = EngineStatus(
    inputChannels: 2,
    outputChannels: 2,
    isConnected: true,
  );

  Future<void> openFxEditor(
    WidgetTester tester, {
    required LooperState state,
    required FxScope Function(
      LooperBloc bloc,
      MonitorCubit monitor,
      LooperRepository repo,
    )
    scopeOf,
    Future<void> Function(MonitorCubit monitor)? primeMonitor,
  }) async {
    tester.view
      ..physicalSize = const Size(1400, 1000)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bloc = _ScreenshotLooperBloc();
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    final repo = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    addTearDown(repo.dispose);
    final monitor = MonitorCubit(repository: repo, settings: settings);
    addTearDown(monitor.close);
    if (primeMonitor != null) await primeMonitor(monitor);

    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: repo,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _goldenTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<MonitorCubit>.value(value: monitor),
            ],
            child: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    FxDock(
                      scope: scopeOf(bloc, monitor, repo),
                      onClose: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('FX editor — lane scope with a chain', (tester) async {
    await openFxEditor(
      tester,
      state: LooperState(
        tracks: [
          Track(
            lanes: [
              Lane(
                inputChannel: 0,
                effects: [
                  BuiltInEffect(type: TrackEffectType.filter),
                  BuiltInEffect(type: TrackEffectType.delay),
                ],
              ),
            ],
          ),
        ],
        status: editorStatus,
      ),
      scopeOf: (bloc, monitor, repo) =>
          LaneFxScope(looper: bloc, repository: repo, track: 0, lane: 0),
    );

    await expectLater(
      find.byKey(const Key('fx_dock')),
      matchesGoldenFile('goldens/fx_editor_lane.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('FX editor — input scope', (tester) async {
    await openFxEditor(
      tester,
      state: const LooperState(status: editorStatus),
      scopeOf: (bloc, monitor, repo) => InputFxScope(
        monitor: monitor,
        looper: bloc,
        repository: repo,
        input: 0,
      ),
      primeMonitor: (m) async {
        await m.setEnabled(0, enabled: true);
        m
          ..addEffect(0)
          ..addEffect(0);
      },
    );

    await expectLater(
      find.byKey(const Key('fx_dock')),
      matchesGoldenFile('goldens/fx_editor_input.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('FX editor — empty clean state', (tester) async {
    await openFxEditor(
      tester,
      state: const LooperState(
        tracks: [
          Track(lanes: [Lane()]),
        ],
        status: editorStatus,
      ),
      scopeOf: (bloc, monitor, repo) =>
          LaneFxScope(looper: bloc, repository: repo, track: 0, lane: 0),
    );

    await expectLater(
      find.byKey(const Key('fx_dock')),
      matchesGoldenFile('goldens/fx_editor_empty.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('FX editor — plugin block', (tester) async {
    await openFxEditor(
      tester,
      state: const LooperState(
        tracks: [
          Track(
            lanes: [
              Lane(
                effects: [
                  PluginEffect(
                    ref: PluginRef(format: PluginFormat.vst3, id: 'comp'),
                    name: 'Compressor',
                    params: [
                      PluginParamInfo(
                        id: 1,
                        name: 'Ratio',
                        unit: ':1',
                        min: 1,
                        max: 20,
                        def: 4,
                        stepCount: 0,
                        flags: 0x01,
                      ),
                      PluginParamInfo(
                        id: 2,
                        name: 'Threshold',
                        unit: 'dB',
                        min: -60,
                        max: 0,
                        def: -18,
                        stepCount: 0,
                        flags: 0x01,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
        status: editorStatus,
      ),
      scopeOf: (bloc, monitor, repo) =>
          LaneFxScope(looper: bloc, repository: repo, track: 0, lane: 0),
    );

    await expectLater(
      find.byKey(const Key('fx_dock')),
      matchesGoldenFile('goldens/fx_editor_plugin.png'),
    );
  }, skip: !hasScreenshotFonts);
}

class _ScreenshotLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}
