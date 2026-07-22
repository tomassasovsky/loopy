@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/console_mode.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/performance/performance.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(File(p).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

/// Manual generator for the console main-window decal (the artwork on the 16"
/// panel in the Fusion "VAMP console (populated)" doc). Renders [TracksView]
/// exactly as the physical console shows it and captures a 1920x1080 golden.
///
/// It only produces the CONSOLE layout when compiled with the flag on, so it is
/// gated on [kConsoleMode]. Regenerate on the author's machine with:
///
///   flutter test --tags screenshots --dart-define=LOOPY_CONSOLE=true \
///     --update-goldens test/screenshots/tracks_screenshots_test.dart
void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Golden generators load the local SDK's Material fonts and compare against
  // macOS-rendered goldens, so they only run where those fonts exist (the
  // author's machine); everywhere else they skip. Additionally gated on
  // console mode: without --dart-define=LOOPY_CONSOLE=true the layout would
  // carry the desktop toolbar and not match the console decal.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    const robotoTtfs = [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ];
    await _loadFont('Roboto', robotoTtfs);
    // TracksView wraps itself in LooperScreenTheme, which renders text in the
    // legend font (Helvetica / Arial / sans-serif — macOS/Linux system fonts,
    // absent under `flutter test`). Register the loaded Roboto glyphs under
    // those family names so the labels render instead of Ahem tofu.
    for (final family in ['Helvetica', 'Arial', 'sans-serif']) {
      await _loadFont(family, robotoTtfs);
    }
    await _loadFont('Space Grotesk', ['assets/fonts/SpaceGrotesk.ttf']);
    await _loadFont('IBM Plex Mono', [
      'assets/fonts/IBMPlexMono-Regular.ttf',
      'assets/fonts/IBMPlexMono-Medium.ttf',
      'assets/fonts/IBMPlexMono-SemiBold.ttf',
    ]);
  });

  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;
  late PerformanceRepository performance;
  late PerformanceRecorderCubit performanceRecorder;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    performanceRecorder = _MockPerformanceRecorderCubit();
    when(
      () => performanceRecorder.state,
    ).thenReturn(const PerformanceRecorderIdle());
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) async {
    // 16:9 at the panel's native 1920x1080 so the captured decal matches the
    // 344x194 (16:9) active area 1:1.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<PerformanceRepository>.value(value: performance),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<TracksCubit>.value(value: tracks),
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<SessionCubit>.value(value: session),
              BlocProvider<PerformanceRecorderCubit>.value(
                value: performanceRecorder,
              ),
            ],
            child: const TracksView(),
          ),
        ),
      ),
    );
    // Advance implicit animations to a steady state without pumpAndSettle
    // (the record/level meters may run a repeating ticker that never settles).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'console main window (16" panel decal)',
    (tester) async {
      // The real per-track names shown on the console.
      const names = ['GUITAR', 'BOOM', 'RC20', 'VOX'];
      for (var i = 0; i < names.length; i++) {
        await tracks.rename(i, names[i]);
      }
      seed(
        const LooperState(
          status: EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'VAMP',
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: [
            Track(
              state: TrackState.playing,
              rms: 0.72,
              peak: 0.9,
              lengthFrames: 96000,
            ),
            Track(
              channel: 1,
              state: TrackState.playing,
              rms: 0.5,
              peak: 0.68,
              lengthFrames: 96000,
            ),
            // RC20: loaded (has content) but muted.
            Track(
              channel: 2,
              state: TrackState.playing,
              muted: true,
              rms: 0.4,
              peak: 0.55,
              lengthFrames: 96000,
            ),
            Track(channel: 3),
          ],
        ),
      );
      await pump(tester);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_main_window.png'),
      );
    },
    skip: !hasScreenshotFonts || !kConsoleMode,
  );
}
