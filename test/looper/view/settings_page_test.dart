import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

void main() {
  late SettingsRepository settings;
  late TracksCubit tracks;
  late WaveformWindowCubit waveformWindow;
  late HighContrastCubit highContrast;
  late AudioSetupCubit audioSetup;
  late MidiSetupCubit midiSetup;
  late ControlOverlay store;
  late ControlOverlayCubit overlay;
  late ControlIntents intents;
  late PedalCubit pedal;
  late RefreshRateCubit refreshRate;
  late QuantizeCubit quantize;
  late MonitorCubit monitor;
  late RecordOptionsCubit recordOptions;
  late LooperRepository repository;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    tracks = TracksCubit(settings: settings);
    waveformWindow = WaveformWindowCubit(settings: settings);
    highContrast = HighContrastCubit(settings: settings);
    audioSetup = _MockAudioSetupCubit();
    when(() => audioSetup.state).thenReturn(const AudioSetupState());
    midiSetup = _MockMidiSetupCubit();
    when(() => midiSetup.state).thenReturn(const MidiSetupState());
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: const MidiSetupState(),
    );
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
    // A real overlay + intents pair: they own the shared LooperMode whose
    // persisted default the View section edits.
    store = ControlOverlay(looper: repository);
    addTearDown(store.dispose);
    intents = ControlIntents(
      looper: repository,
      overlay: store,
      settings: settings,
    );
    overlay = ControlOverlayCubit(overlay: store, intents: intents);
    addTearDown(overlay.close);
    // The Audio tab embeds the pedal output picker, driven by PedalCubit.
    pedal = PedalCubit(
      pedal: PedalRepository(const NoopPedalTransport()),
      looper: repository,
      overlay: store,
      intents: intents,
      settings: settings,
      pollInterval: Duration.zero,
    );
    addTearDown(pedal.close);
    refreshRate = RefreshRateCubit(repository: repository, settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    monitor = MonitorCubit(repository: repository, settings: settings);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorInputEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    recordOptions = RecordOptionsCubit(
      repository: repository,
      settings: settings,
    );
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
          RepositoryProvider<ControlIntents>.value(value: intents),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlOverlayCubit>.value(value: overlay),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
          ],
          child: const SettingsPage(),
        ),
      ),
    ),
  );

  testWidgets('toggling the waveform window persists the preference', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(
      find.byKey(const Key('settings_waveformWindow_switch')),
    );
    await tester.pumpAndSettle();

    expect(waveformWindow.state, isFalse);
    expect(await settings.loadShowWaveformWindow(), isFalse);
  });

  testWidgets('toggling high contrast persists the preference', (
    tester,
  ) async {
    await pump(tester);

    expect(highContrast.state, isFalse);
    await tester.tap(
      find.byKey(const Key('settings_highContrast_switch')),
    );
    await tester.pumpAndSettle();

    expect(highContrast.state, isTrue);
    expect(await settings.loadHighContrast(), isTrue);
  });

  testWidgets('track-indicators toggle renders, reflects state, and flips it', (
    tester,
  ) async {
    await pump(tester);

    final toggle = find.byKey(const Key('settings_trackIndicators_switch'));
    expect(toggle, findsOneWidget);
    // Default on (the cubit seeds true).
    expect(tracks.state.showIndicators, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tracks.state.showIndicators, isFalse);
    expect(await settings.loadShowTrackIndicators(), isFalse);
  });

  testWidgets('renaming a track updates the list and persists it', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_trackName_0')));
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

  testWidgets('choosing a default mode persists it', (
    tester,
  ) async {
    await pump(tester);
    expect(overlay.state.defaultMode, LooperMode.record);

    final play = find.byKey(const Key('settings_defaultMode_play'));
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();

    expect(overlay.state.defaultMode, LooperMode.play);
    expect(overlay.state.mode, LooperMode.play);
    expect(
      await settings.loadDefaultLooperMode(),
      LooperMode.play.token,
    );
  });

  testWidgets('choosing a refresh rate persists it and applies it', (
    tester,
  ) async {
    await pump(tester);
    expect(refreshRate.state, 60);

    final fast = find.byKey(const Key('settings_refreshRate_120'));
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
    await tester.tap(find.byKey(const Key('settings_tab_audio')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('audioSettings_quantize_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quantize.state, isTrue);
    expect(await settings.loadQuantize(), isTrue);
    verify(() => repository.setQuantize(enabled: true)).called(1);
  });

  testWidgets('selecting a section tab shows only that section', (
    tester,
  ) async {
    await pump(tester);
    // Defaults to the View section (the waveform-window toggle lives there).
    expect(
      find.byKey(const Key('settings_waveformWindow_switch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_trackName_0')), findsNothing);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();
    // The Tracks section renders the per-track rename rows.
    expect(find.byKey(const Key('settings_trackName_0')), findsOneWidget);
    expect(
      find.byKey(const Key('settings_waveformWindow_switch')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('settings_tab_audio')));
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
    expect(find.byKey(const Key('settings_trackName_0')), findsNothing);

    // There is no longer a Routing tab — the whole-system signal flow moved to
    // the Signal surface.
    expect(find.byKey(const Key('settings_tab_routing')), findsNothing);
  });

  testWidgets('Escape pops the settings page', (tester) async {
    // Providers above MaterialApp so the pushed settings route can read them.
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
          RepositoryProvider<ControlIntents>.value(value: intents),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlOverlayCubit>.value(value: overlay),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
          ],
          child: MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsPage(),
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
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
  });
}
