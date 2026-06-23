@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
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
              BlocProvider<BigPictureCubit>.value(
                value: BigPictureCubit(settings: settings),
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
              BlocProvider<BankCubit>.value(value: BankCubit()),
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
            ],
            child: const BigPictureSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('View section — performance defaults', (tester) async {
    await pump(tester);
    // Reveal the PERFORMANCE group (default mode + refresh rate).
    await tester.scrollUntilVisible(
      find.byKey(const Key('bpSettings_refreshRate_120')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(BigPictureSettingsPage),
      matchesGoldenFile('goldens/settings_view_performance.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Audio section — recording', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('bpSettings_tab_audio')));
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
      find.byType(BigPictureSettingsPage),
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
                  TrackEffect(type: TrackEffectType.filter),
                  TrackEffect(type: TrackEffectType.delay),
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
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<BigPictureCubit>(
              create: (_) => BigPictureCubit(settings: settings),
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
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('signal_page')),
      matchesGoldenFile('goldens/signal_surface.png'),
    );
  }, skip: !hasScreenshotFonts);
}

class _ScreenshotLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}
