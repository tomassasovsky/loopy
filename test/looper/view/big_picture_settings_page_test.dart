import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

void main() {
  late SettingsRepository settings;
  late UiModeCubit uiMode;
  late BigPictureCubit bigPicture;
  late WaveformWindowCubit waveformWindow;
  late BankCubit bank;
  late AudioSetupCubit audioSetup;
  late RefreshRateCubit refreshRate;
  late QuantizeCubit quantize;
  late MonitorCubit monitor;
  late LooperRepository repository;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    uiMode = UiModeCubit(settings: settings);
    bigPicture = BigPictureCubit(settings: settings);
    waveformWindow = WaveformWindowCubit(settings: settings);
    bank = BankCubit(settings: settings);
    audioSetup = _MockAudioSetupCubit();
    when(() => audioSetup.state).thenReturn(const AudioSetupState());
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
    refreshRate = RefreshRateCubit(repository: repository, settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    monitor = MonitorCubit(repository: repository, settings: settings);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorInputMask(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorOutputMask(any()),
    ).thenReturn(EngineResult.ok);
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<UiModeCubit>.value(value: uiMode),
            BlocProvider<BigPictureCubit>.value(value: bigPicture),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<BankCubit>.value(value: bank),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
          ],
          child: const BigPictureSettingsPage(),
        ),
      ),
    ),
  );

  testWidgets('toggling the waveform window persists the preference', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(
      find.byKey(const Key('bpSettings_waveformWindow_switch')),
    );
    await tester.pumpAndSettle();

    expect(waveformWindow.state, isFalse);
    expect(await settings.loadShowWaveformWindow(), isFalse);
  });

  testWidgets('toggling the second bank persists it', (tester) async {
    await pump(tester);
    expect(bank.state.enabled, isTrue);

    // Bank + track controls live under the Tracks section.
    await tester.tap(find.byKey(const Key('bpSettings_tab_tracks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bpSettings_bank_switch')));
    await tester.pumpAndSettle();

    expect(bank.state.enabled, isFalse);
    expect(await settings.loadBankEnabled(), isFalse);
  });

  testWidgets('renaming a track updates the list and persists it', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('bpSettings_tab_tracks')));
    await tester.pumpAndSettle();
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bpSettings_trackName_0')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('renameTrack_field')),
      'DRUMS',
    );
    await tester.tap(find.byKey(const Key('renameTrack_save')));
    await tester.pumpAndSettle();

    expect(find.text('DRUMS'), findsOneWidget);
    expect(await settings.loadTrackName(0), 'DRUMS');
  });

  testWidgets('choosing a default performance mode persists it', (
    tester,
  ) async {
    await pump(tester);
    expect(bigPicture.state.defaultMode, PerformanceMode.record);

    final play = find.byKey(const Key('bpSettings_defaultMode_play'));
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();

    expect(bigPicture.state.defaultMode, PerformanceMode.play);
    expect(bigPicture.state.mode, PerformanceMode.play);
    expect(
      await settings.loadDefaultPerformanceMode(),
      PerformanceMode.play.token,
    );
  });

  testWidgets('choosing a refresh rate persists it and applies it', (
    tester,
  ) async {
    await pump(tester);
    expect(refreshRate.state, 60);

    final fast = find.byKey(const Key('bpSettings_refreshRate_120'));
    await tester.ensureVisible(fast);
    await tester.tap(fast);
    await tester.pumpAndSettle();

    expect(refreshRate.state, 120);
    expect(await settings.loadRefreshHz(), 120);
    // 120 Hz -> 1_000_000 / 120 ≈ 8333 µs.
    verify(
      () => repository.setPollInterval(const Duration(microseconds: 8333)),
    ).called(1);
  });

  testWidgets('toggling quantize on the Audio tab persists and applies it', (
    tester,
  ) async {
    await pump(tester);
    expect(quantize.state, isFalse);

    // Quantize lives in the Audio > Recording group.
    await tester.tap(find.byKey(const Key('bpSettings_tab_audio')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('audioSettings_quantize_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quantize.state, isTrue);
    expect(await settings.loadQuantize(), isTrue);
    verify(() => repository.setQuantize(enabled: true)).called(1);
  });

  testWidgets('the Big Picture switch reflects the current mode', (
    tester,
  ) async {
    await pump(tester);

    final toggle = tester.widget<Switch>(
      find.byKey(const Key('bpSettings_bigPicture_switch')),
    );
    expect(toggle.value, isTrue); // default is big picture
  });

  testWidgets('selecting a section tab shows only that section', (
    tester,
  ) async {
    await pump(tester);
    // Defaults to the View section.
    expect(
      find.byKey(const Key('bpSettings_bigPicture_switch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('bpSettings_bank_switch')), findsNothing);

    await tester.tap(find.byKey(const Key('bpSettings_tab_tracks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bpSettings_bank_switch')), findsOneWidget);
    expect(find.byKey(const Key('bpSettings_bigPicture_switch')), findsNothing);

    await tester.tap(find.byKey(const Key('bpSettings_tab_audio')));
    await tester.pumpAndSettle();
    // The Audio section renders the inline device controls (not a nav tile).
    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_measure_button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('bpSettings_bank_switch')), findsNothing);

    await tester.tap(find.byKey(const Key('bpSettings_tab_routing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsNothing,
    );
  });

  testWidgets('the Routing tab shows the signal-flow graph', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('bpSettings_tab_routing')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
  });

  testWidgets('Escape pops the settings page', (tester) async {
    // Providers above MaterialApp so the pushed settings route can read them.
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<UiModeCubit>.value(value: uiMode),
            BlocProvider<BigPictureCubit>.value(value: bigPicture),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<BankCubit>.value(value: bank),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BigPictureSettingsPage(),
                      ),
                    ),
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
    expect(find.byType(BigPictureSettingsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(BigPictureSettingsPage), findsNothing);
  });
}
