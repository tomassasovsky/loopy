@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/looper/view/track_routing_dialog.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

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

  setUpAll(() async {
    await _loadFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
  });

  late SettingsRepository settings;
  late LooperRepository repository;
  late AudioSetupCubit audioSetup;

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
        theme: ThemeData(
          fontFamily: 'Roboto',
          brightness: Brightness.dark,
        ),
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UiModeCubit>.value(
                value: UiModeCubit(settings: settings),
              ),
              BlocProvider<BigPictureCubit>.value(
                value: BigPictureCubit(settings: settings),
              ),
              BlocProvider<WaveformWindowCubit>.value(
                value: WaveformWindowCubit(settings: settings),
              ),
              BlocProvider<BankCubit>.value(
                value: BankCubit(settings: settings),
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
  });

  testWidgets('Audio section — monitoring + recording', (tester) async {
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
      matchesGoldenFile('goldens/settings_audio_monitoring_recording.png'),
    );
  });

  testWidgets('Per-track routing dialog', (tester) async {
    tester.view
      ..physicalSize = const Size(1480, 1500)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // A before-track Filter and an after-track Delay so the graph shows cards
    // on the signal path.
    await settings.saveTrackEffects(
      1,
      encodeTrackEffects([
        TrackEffect(type: TrackEffectType.filter, stage: TrackEffectStage.pre),
        TrackEffect(type: TrackEffectType.delay),
      ]),
    );

    final bloc = _ScreenshotLooperBloc();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [Track(channel: 1)],
        status: EngineStatus(
          inputChannels: 4,
          outputChannels: 4,
          isConnected: true,
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: BlocProvider<LooperBloc>.value(
            value: bloc,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        showTrackRoutingDialog(context: context, channel: 1),
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
      find.byKey(const Key('trackRouting_dialog')),
      matchesGoldenFile('goldens/track_routing_dialog.png'),
    );
  });
}

class _ScreenshotLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}
