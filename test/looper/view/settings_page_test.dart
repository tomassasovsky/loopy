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
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late SettingsRepository settings;
  late TracksCubit tracks;
  late WaveformWindowCubit waveformWindow;
  late HighContrastCubit highContrast;
  late AudioSetupCubit audioSetup;
  late MidiSetupCubit midiSetup;
  late PedalRepository pedalRepo;
  late PerformanceRepository performance;
  late ControlCubit control;
  late PedalCubit pedal;
  late RefreshRateCubit refreshRate;
  late QuantizeCubit quantize;
  late MonitorCubit monitor;
  late RecordOptionsCubit recordOptions;
  late LooperRepository repository;
  late LooperBloc looperBloc;
  late TempoCubit tempo;

  setUpAll(() {
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(const LooperRecordPressed(0));
  });

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
    // The real control cubit: it owns the shared InteractionMode whose
    // persisted default the View section edits.
    pedalRepo = PedalRepository(const NoopPedalTransport());
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    // The Audio tab embeds the pedal output picker, driven by PedalCubit.
    pedal = PedalCubit(
      pedal: pedalRepo,
      settings: settings,
      pollInterval: Duration.zero,
    );
    addTearDown(pedal.close); // disposes pedalRepo (the lifecycle owner)
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
    // The Tracks section's length-preset picker reads/drives LooperBloc,
    // provided app-wide in the real app (lib/app/view/app.dart) — mirrored
    // here (mocked, like the other MockCubit/MockBloc fixtures above) so the
    // settings route can find it.
    looperBloc = _MockLooperBloc();
    when(() => looperBloc.state).thenReturn(const LooperState());
    whenListen(
      looperBloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setSyncTempo(on: any(named: 'on')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setQuantizeDiv(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setCountIn(any()),
      ).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
    tempo = TempoCubit(repository: repository, settings: settings);
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
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
            BlocProvider<LooperBloc>.value(value: looperBloc),
            BlocProvider<TempoCubit>.value(value: tempo),
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

  testWidgets(
    'the length preset row shows the current preset and dispatches a change',
    (tester) async {
      const seeded = LooperState(tracks: [Track(lengthPresetBars: 4)]);
      when(() => looperBloc.state).thenReturn(seeded);
      whenListen(
        looperBloc,
        const Stream<LooperState>.empty(),
        initialState: seeded,
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('settings_tab_tracks')));
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('settings_trackLengthPreset_0'));
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(find.text('4 bars'), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.text('8 bars').last);
      await tester.pumpAndSettle();

      verify(
        () => looperBloc.add(const LooperTrackLengthPresetChanged(0, 8)),
      ).called(1);
    },
  );

  testWidgets(
    'the length preset row uses the singular "1 bar" for a 1-bar preset',
    (tester) async {
      // ICU plural coverage (code review): "{bars} bars" alone would render
      // "1 bars" for the singular case — the ARB uses a plural rule instead.
      const seeded = LooperState(tracks: [Track(lengthPresetBars: 1)]);
      when(() => looperBloc.state).thenReturn(seeded);
      whenListen(
        looperBloc,
        const Stream<LooperState>.empty(),
        initialState: seeded,
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('settings_tab_tracks')));
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('settings_trackLengthPreset_0'));
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(find.text('1 bar'), findsOneWidget);
      expect(find.text('1 bars'), findsNothing);
    },
  );

  testWidgets('the length preset row shows AUTO by default', (tester) async {
    const seeded = LooperState(tracks: [Track()]);
    when(() => looperBloc.state).thenReturn(seeded);
    whenListen(
      looperBloc,
      const Stream<LooperState>.empty(),
      initialState: seeded,
    );
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();

    final row = find.byKey(const Key('settings_trackLengthPreset_0'));
    await tester.ensureVisible(row);
    expect(row, findsOneWidget);
    expect(find.text('AUTO'), findsOneWidget);
  });

  testWidgets('choosing a default mode persists it', (
    tester,
  ) async {
    await pump(tester);
    expect(control.state.defaultMode, InteractionMode.record);

    final mute = find.byKey(const Key('settings_defaultMode_mute'));
    await tester.ensureVisible(mute);
    await tester.tap(mute);
    await tester.pumpAndSettle();

    expect(control.state.defaultMode, InteractionMode.mute);
    expect(control.state.mode, InteractionMode.mute);
    expect(
      await settings.loadDefaultInteractionMode(),
      InteractionMode.mute.token,
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

  testWidgets('choosing a quantize granularity on the Tempo tab applies it', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_tab_tempo')));
    await tester.pumpAndSettle();
    final option = find.byKey(
      const Key('tempoSettings_quantizeDiv_quarter'),
    );
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(tempo.state.quantizeDiv, GridDivision.quarter);
    verify(() => repository.setQuantizeDiv(GridDivision.quarter)).called(1);
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

    await tester.tap(find.byKey(const Key('settings_tab_tempo')));
    await tester.pumpAndSettle();
    // The Tempo section renders the BPM control (its own settings surface,
    // not audio_setup — index plan UI conventions).
    expect(find.byKey(const Key('tempoSettings_bpm_field')), findsOneWidget);
    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsNothing,
    );

    // There is no longer a Routing tab — the whole-system signal flow moved to
    // the Signal surface.
    expect(find.byKey(const Key('settings_tab_routing')), findsNothing);
  });

  testWidgets(
    'the mode tab renders the mode picker with the live mode selected',
    (tester) async {
      const seeded = LooperState(
        transport: TransportState(looperMode: LooperMode.sync),
      );
      when(() => looperBloc.state).thenReturn(seeded);
      whenListen(
        looperBloc,
        const Stream<LooperState>.empty(),
        initialState: seeded,
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('settings_tab_mode')));
      await tester.pumpAndSettle();

      for (final mode in LooperMode.values) {
        expect(
          find.byKey(Key('looperMode_option_${mode.name}')),
          findsOneWidget,
        );
      }
      // Selecting the mode already active is a no-op (no content, no
      // dialog needed either way) — proves the live transport state reached
      // the picker, not just its default.
      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();
      verifyNever(() => looperBloc.add(any()));
    },
  );

  testWidgets(
    'the one-shot row shows the current flag and dispatches a change',
    (tester) async {
      const seeded = LooperState(tracks: [Track(oneShot: true)]);
      when(() => looperBloc.state).thenReturn(seeded);
      whenListen(
        looperBloc,
        const Stream<LooperState>.empty(),
        initialState: seeded,
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('settings_tab_tracks')));
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('settings_trackOneShot_0'));
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(tester.widget<Switch>(row).value, isTrue);

      await tester.tap(row);
      await tester.pumpAndSettle();

      verify(
        () => looperBloc.add(const LooperOneShotToggled(0, oneShot: false)),
      ).called(1);
    },
  );

  testWidgets('the one-shot row is off by default', (tester) async {
    const seeded = LooperState(tracks: [Track()]);
    when(() => looperBloc.state).thenReturn(seeded);
    whenListen(
      looperBloc,
      const Stream<LooperState>.empty(),
      initialState: seeded,
    );
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();

    final row = find.byKey(const Key('settings_trackOneShot_0'));
    await tester.ensureVisible(row);
    expect(tester.widget<Switch>(row).value, isFalse);
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
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<QuantizeCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
            BlocProvider<LooperBloc>.value(value: looperBloc),
            BlocProvider<TempoCubit>.value(value: tempo),
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
