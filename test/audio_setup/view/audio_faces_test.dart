import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/view/console/audio_tray_panel.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/tray/tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The host's own list: a Scarlett reported in both directions with its real
/// channel counts, the built-in pair, and a playback-only device.
const _devices = <AudioDevice>[
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
  // No capture half at all, and no count either — the two ways a device can
  // fail to answer, in one row.
  AudioDevice(
    id: 'hdmi-out',
    name: 'HDMI',
    isDefault: false,
    isInput: false,
  ),
];

const _open = EngineStatus(
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

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late AudioSetupCubit audio;
  late InputsCubit inputs;
  late QuantizeCubit quantize;
  late RecordOptionsCubit options;
  late SettingsTrayCubit tray;

  setUpAll(() {
    registerFallbackValue(const EngineConfig());
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(const LooperState(status: _open));
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'scarlett-out',
        captureDeviceId: 'scarlett-in',
      ),
    );
    when(() => repository.startEngine(any())).thenReturn(EngineResult.ok);
    when(repository.stopEngine).thenReturn(EngineResult.ok);
    when(repository.measureLatency).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(repository.devices).thenReturn(_devices);
    when(repository.asioDrivers).thenReturn(const []);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
  });

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(AudioTrayPanel)));

  /// Mounts the Audio face with the providers the real tray inherits.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view pushes the lower rows below the fold where a
  /// tap lands on nothing.
  Future<void> pump(
    WidgetTester tester, {
    AudioTab tab = AudioTab.device,
    LooperState looper = const LooperState(status: _open),
    SettingsTrayDestination destination = SettingsTrayDestination.audio,
    Widget? body,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(looper);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: looper,
    );

    settings = SettingsRepository(store: FakeKeyValueStore());
    audio = AudioSetupCubit(
      repository: repository,
      settings: settings,
      // No periodic re-enumeration: a timer live for the length of the test
      // body fails the binding's invariant check before any tearDown runs.
      deviceRefreshInterval: Duration.zero,
    );
    inputs = InputsCubit(settings: settings);
    quantize = QuantizeCubit(repository: repository, settings: settings);
    options = RecordOptionsCubit(repository: repository, settings: settings);
    tray = SettingsTrayCubit(settings: settings)
      ..showAudioTab(tab)
      ..showDestination(destination);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(audio.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(quantize.close()));
    addTearDown(() => unawaited(options.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: audio),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: quantize),
              BlocProvider.value(value: options),
              BlocProvider.value(value: tray),
            ],
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(19),
                child: body ?? const AudioTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ConsoleRow rowOf(WidgetTester tester, Key key) =>
      tester.widget<ConsoleRow>(find.byKey(key));

  // ------------------------------------------------------------------ device

  group('Audio — Device', () {
    testWidgets('rows open one at a time', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('audio_device_option_0')), findsNothing);

      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_device_option_0')), findsOneWidget);

      // Opening the rate row closes the device list rather than adding to it.
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_device_option_0')), findsNothing);
      expect(find.byKey(const Key('audio_buffer_128')), findsOneWidget);

      // And tapping the open row shuts it.
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_buffer_128')), findsNothing);
    });

    testWidgets('the device list GROWS open rather than appearing', (
      tester,
    ) async {
      await pump(tester);
      final chooser = find.byKey(const Key('audio_device_chooser'));
      expect(tester.getSize(chooser).height, 0);

      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pump();
      // Mid-flight: taller than nothing, shorter than settled. A golden only
      // ever photographs the settled state, so the movement needs asserting
      // here or a swap would pass for a growth.
      await tester.pump(kConsoleMotion ~/ 2);
      final midway = tester.getSize(chooser).height;
      expect(midway, greaterThan(0));

      await tester.pumpAndSettle();
      expect(tester.getSize(chooser).height, greaterThan(midway));
    });

    testWidgets('a device says its counts once, for both directions', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();

      // The host lists playback and capture separately; the row pairs them.
      expect(find.text('Scarlett 18i20'), findsWidgets);
      expect(find.text(l10n.audioDeviceChannels(18, 20)), findsOneWidget);
      expect(find.text(l10n.audioDeviceChannels(2, 2)), findsOneWidget);
    });

    testWidgets('a device with unknown counts says nothing, never zero', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();

      expect(find.text('HDMI'), findsOneWidget);
      expect(find.text(l10n.audioDeviceChannels(0, 0)), findsNothing);
      expect(find.text('0 in · 0 out'), findsNothing);
    });

    testWidgets('the pinned device is checked and names the closed row', (
      tester,
    ) async {
      await pump(tester);
      // The closed row names the PINNED device, not an em-dash.
      expect(
        rowOf(tester, const Key('audio_device_row')).value,
        'Scarlett 18i20',
      );

      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();
      final picked = tester.widget<ConsolePickRow>(
        find.byKey(const Key('audio_device_option_0')),
      );
      expect(picked.title, 'Scarlett 18i20');
      expect(picked.selected, isTrue);
    });

    testWidgets('picking a device pins BOTH directions in one write', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_device_option_1')));
      await tester.pumpAndSettle();

      expect(audio.state.playbackDeviceId, 'builtin-out');
      expect(audio.state.captureDeviceId, 'builtin-in');
      // One reopen, not two: the row is one interface.
      verify(() => repository.startEngine(any())).called(1);
    });

    testWidgets('EVERY buffer option carries its own cost', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();

      for (final (frames, ms) in const [
        (64, '2.7'),
        (128, '5.3'),
        (256, '10.7'),
        (512, '21.3'),
      ]) {
        final row = tester.widget<ConsolePickRow>(
          find.byKey(Key('audio_buffer_$frames')),
        );
        expect(row.state, l10n.latencyMs(ms));
      }
    });

    testWidgets('only the rate that costs something says so', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ConsolePickRow>(
              find.byKey(const Key('audio_sample_rate_48000')),
            )
            .state,
        isNull,
      );
      expect(
        tester
            .widget<ConsolePickRow>(
              find.byKey(const Key('audio_sample_rate_96000')),
            )
            .state,
        l10n.audioSampleRateCost96,
      );
    });

    testWidgets('a rate and a buffer reach the engine', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_rate_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_sample_rate_44100')));
      await tester.pumpAndSettle();
      expect(audio.state.sampleRate, 44100);

      await tester.tap(find.byKey(const Key('audio_buffer_256')));
      await tester.pumpAndSettle();
      expect(audio.state.bufferFrames, 256);
    });

    testWidgets('inputs are listed by the name they were given', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await inputs.rename(0, 'guitar');
      await tester.pumpAndSettle();

      final row = rowOf(tester, const Key('audio_inputs_row'));
      expect(row.title, l10n.audioInputsRow);
      expect(row.value, l10n.audioInputsNamed(1));

      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();
      expect(find.text('guitar'), findsOneWidget);
      // The socket rides beside the name, never replacing it.
      expect(find.text(l10n.inputOrdinal(1)), findsOneWidget);
      // An unnamed socket falls back to its ordinal.
      expect(find.text(l10n.inputChannelLabel(3)), findsOneWidget);
    });

    testWidgets('renaming an input goes through the console sheet', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_input_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      for (final key in ['m', 'i', 'c']) {
        await tester.tap(find.text(key).first);
        await tester.pump();
      }
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(inputs.state.names[0], 'mic');
    });

    testWidgets('clearing a name hands the socket back its ordinal', (
      tester,
    ) async {
      await pump(tester);
      await inputs.rename(0, 'mic');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_input_0')));
      await tester.pumpAndSettle();

      // Three backspaces and Save — the sheet has no Clear button, and this
      // IS how an input is un-named.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
        await tester.pump();
      }
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(inputs.state.names[0], isEmpty);
      expect(find.text(l10nOf(tester).inputChannelLabel(1)), findsOneWidget);
    });

    testWidgets('a device with no inputs says so instead of listing two', (
      tester,
    ) async {
      // A playback-only device pinned here records nothing. The list says that
      // rather than offering two sockets that are not there.
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          playbackDeviceId: 'hdmi-out',
        ),
      );
      await pump(tester, looper: const LooperState());
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audio_no_inputs_card')), findsOneWidget);
      expect(find.byKey(const Key('audio_input_0')), findsNothing);
      expect(find.text(l10nOf(tester).audioNoInputs), findsOneWidget);
    });

    testWidgets('a pinned device the host has lost stays listed, greyed', (
      tester,
    ) async {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          playbackDeviceId: 'gone-out',
          captureDeviceId: 'gone-in',
        ),
      );
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();

      // A pin still points at it, so dropping it would read as a device you
      // never had.
      final row = tester.widget<ConsolePickRow>(
        find.byKey(const Key('audio_device_option_3')),
      );
      expect(row.dimmed, isTrue);
      expect(row.selected, isTrue);
      expect(row.state, l10nOf(tester).audioDeviceUnplugged);
    });

    testWidgets('every output off gets a banner, not silence', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('audio_no_outputs_banner')), findsNothing);

      // The mask a real rig produces: default-on across 32 bits with only the
      // sockets the device HAS cleared. `mask == 0` is unreachable, so a test
      // that asserted on it would pass over a banner nothing could ever show.
      const bothOff = LooperState(
        status: EngineStatus(outputChannels: 2),
        outputEnabledMask: 0xFFFFFFFC,
      );
      await pump(tester, looper: bothOff);
      expect(find.byKey(const Key('audio_no_outputs_banner')), findsOneWidget);
      expect(
        find.text(l10nOf(tester).audioNoOutputsBanner),
        findsOneWidget,
      );

      // One of the two still on is not silence.
      await pump(
        tester,
        looper: const LooperState(
          status: EngineStatus(outputChannels: 2),
          outputEnabledMask: 0xFFFFFFFE,
        ),
      );
      expect(find.byKey(const Key('audio_no_outputs_banner')), findsNothing);
    });

    testWidgets('the inputs list stops at the engine ceiling', (tester) async {
      // The rig reports eighteen; the engine lanes and monitors eight, and a
      // name for a socket past that is one the rig could never use.
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_inputs_row')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audio_input_${InputsState.maxInputs - 1}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audio_input_${InputsState.maxInputs}')),
        findsNothing,
      );
    });

    testWidgets('the count says what the LIST shows, not what disk holds', (
      tester,
    ) async {
      // A name kept from a wider rig is still on disk. On a two-input device
      // it must not be counted — "3 named" over a list of two is a row
      // disagreeing with itself.
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          playbackDeviceId: 'builtin-out',
          captureDeviceId: 'builtin-in',
        ),
      );
      await pump(tester, looper: const LooperState());
      await inputs.rename(0, 'guitar');
      await inputs.rename(6, 'talkback');
      await tester.pumpAndSettle();

      expect(
        rowOf(tester, const Key('audio_inputs_row')).value,
        l10nOf(tester).audioInputsNamed(1),
      );
    });

    testWidgets('re-picking the pinned device does not reopen it', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_device_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_device_option_0')));
      await tester.pumpAndSettle();

      verifyNever(() => repository.startEngine(any()));
    });
  });

  // -------------------------------------------------------------- ASIO group

  group('Audio — the ASIO group', () {
    setUp(() {
      when(repository.asioDrivers).thenReturn(const [
        AudioDevice(
          id: 'focusrite',
          name: 'Focusrite USB ASIO',
          isDefault: true,
          isInput: false,
          inputChannels: 18,
          outputChannels: 20,
        ),
        AudioDevice(
          id: 'asio4all',
          name: 'ASIO4ALL v2',
          isDefault: false,
          isInput: false,
          inputChannels: 2,
          outputChannels: 2,
        ),
      ]);
    });

    /// Windows: ASIO is the only backend, so its driver is a setting of its
    /// own rather than one of the devices above it.
    Future<void> pumpWindows(
      WidgetTester tester, {
      List<AudioDevice> drivers = const [],
    }) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      when(() => bloc.state).thenReturn(const LooperState(status: _open));
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(status: _open),
      );
      settings = SettingsRepository(store: FakeKeyValueStore());
      audio = AudioSetupCubit(
        repository: repository,
        settings: settings,
        asioSelectable: true,
        initialAsioDrivers: drivers,
        deviceRefreshInterval: Duration.zero,
      );
      inputs = InputsCubit(settings: settings);
      quantize = QuantizeCubit(repository: repository, settings: settings);
      options = RecordOptionsCubit(repository: repository, settings: settings);
      tray = SettingsTrayCubit(settings: settings)
        ..showDestination(SettingsTrayDestination.audio);
      addTearDown(() => unawaited(audio.close()));
      addTearDown(() => unawaited(inputs.close()));
      addTearDown(() => unawaited(quantize.close()));
      addTearDown(() => unawaited(options.close()));
      addTearDown(() => unawaited(tray.close()));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: RepositoryProvider<LooperRepository>.value(
            value: repository,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<LooperBloc>.value(value: bloc),
                BlocProvider.value(value: audio),
                BlocProvider.value(value: inputs),
                BlocProvider.value(value: quantize),
                BlocProvider.value(value: options),
                BlocProvider.value(value: tray),
              ],
              child: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(19),
                  child: AudioTrayPanel(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the probed drivers are listed with their channel counts', (
      tester,
    ) async {
      await pumpWindows(
        tester,
        drivers: const [
          AudioDevice(
            id: 'focusrite',
            name: 'Focusrite USB ASIO',
            isDefault: true,
            isInput: false,
            inputChannels: 18,
            outputChannels: 20,
          ),
        ],
      );
      final l10n = l10nOf(tester);
      // Twice: the pinned caption, and the bottom-edge preview of the group
      // the viewport has not reached yet.
      expect(find.text(l10n.audioAsioDriverGroup), findsWidgets);
      final row = tester.widget<ConsolePickRow>(
        find.byKey(const Key('audio_asio_driver_0')),
      );
      expect(row.title, 'Focusrite USB ASIO');
      expect(row.state, l10n.audioDeviceChannels(18, 20));
      expect(row.selected, isTrue);
    });

    testWidgets('with no driver installed it offers the install note', (
      tester,
    ) async {
      when(repository.asioDrivers).thenReturn(const []);
      await pumpWindows(tester);
      final l10n = l10nOf(tester);
      expect(find.byKey(const Key('audio_no_asio_banner')), findsOneWidget);
      expect(find.text(l10n.audioNoAsioDriver), findsOneWidget);
      // Linked, never bundled — the licence forbids redistribution.
      expect(find.text(l10n.audioOpenAsio4all), findsOneWidget);
      expect(find.byKey(const Key('audio_asio_driver_0')), findsNothing);
    });

    testWidgets('the group you have not reached waits at the bottom edge', (
      tester,
    ) async {
      // Two groups and one viewport: the caption you have not scrolled to yet
      // previews at the bottom. Only reachable on Windows, where the ASIO
      // group is the second one.
      await pumpWindows(
        tester,
        drivers: const [
          AudioDevice(
            id: 'focusrite',
            name: 'Focusrite USB ASIO',
            isDefault: true,
            isInput: false,
            inputChannels: 18,
            outputChannels: 20,
          ),
        ],
      );
      expect(find.byKey(const Key('audio_upcoming_group')), findsOneWidget);
    });
  });

  // --------------------------------------------------------------- recording

  group('Audio — Recording', () {
    testWidgets('the tab rests with every row shut', (tester) async {
      await pump(tester, tab: AudioTab.recording);
      expect(find.byKey(const Key('audio_max_loop_0')), findsNothing);
      expect(find.byKey(const Key('audio_default_length_0')), findsNothing);
    });

    testWidgets('its two openable rows also open one at a time', (
      tester,
    ) async {
      await pump(tester, tab: AudioTab.recording);
      await tester.tap(find.byKey(const Key('audio_max_loop_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_max_loop_5')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio_default_length_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_max_loop_5')), findsNothing);
      expect(find.byKey(const Key('audio_default_length_2')), findsOneWidget);
    });

    testWidgets('the loop cap chooser GROWS open rather than appearing', (
      tester,
    ) async {
      await pump(tester, tab: AudioTab.recording);
      final chooser = find.byKey(const Key('audio_max_loop_chooser'));
      expect(tester.getSize(chooser).height, 0);

      await tester.tap(find.byKey(const Key('audio_max_loop_row')));
      await tester.pump();
      await tester.pump(kConsoleMotion ~/ 2);
      final midway = tester.getSize(chooser).height;
      expect(midway, greaterThan(0));

      await tester.pumpAndSettle();
      expect(tester.getSize(chooser).height, greaterThan(midway));
    });

    testWidgets('the loop cap opens in place and writes', (tester) async {
      await pump(tester, tab: AudioTab.recording);
      await tester.tap(find.byKey(const Key('audio_max_loop_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio_max_loop_5')));
      await tester.pumpAndSettle();
      expect(audio.state.maxLoopMinutes, 5);
    });

    testWidgets('the three switches write through their own cubits', (
      tester,
    ) async {
      await pump(tester, tab: AudioTab.recording);

      await tester.tap(find.byKey(const Key('audio_quantize_switch')));
      await tester.pumpAndSettle();
      expect(quantize.state, isTrue);

      await tester.tap(find.byKey(const Key('audio_rec_dub_switch')));
      await tester.pumpAndSettle();
      expect(options.state.recDub, isTrue);

      await tester.tap(find.byKey(const Key('audio_auto_record_switch')));
      await tester.pumpAndSettle();
      expect(options.state.autoRecord, isTrue);
    });

    testWidgets('the default length is a chip grid that shuts on a pick', (
      tester,
    ) async {
      await pump(tester, tab: AudioTab.recording);
      await tester.tap(find.byKey(const Key('audio_default_length_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_default_length_2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio_default_length_2')));
      await tester.pumpAndSettle();
      expect(options.state.defaultMultiple, 2);
      // A pick-one: the question is answered, so the drawer shuts.
      expect(find.byKey(const Key('audio_default_length_2')), findsNothing);
    });
  });

  // ------------------------------------------------------------------ status

  group('Audio — Status', () {
    testWidgets('every row is a readout — no tap, no marker', (tester) async {
      await pump(tester, tab: AudioTab.status);
      for (final key in const [
        'audio_status_device',
        'audio_status_rate',
        'audio_status_buffer',
        'audio_status_latency',
        'audio_status_offset',
      ]) {
        final row = tester.widget<ConsoleRow>(find.byKey(Key(key)));
        expect(row.onTap, isNull, reason: '$key must not be editable');
        expect(row.showDisclosure, isFalse);
      }
    });

    testWidgets('it reports what the engine reports', (tester) async {
      await pump(tester, tab: AudioTab.status);
      final l10n = l10nOf(tester);
      expect(find.text('Scarlett 18i20'), findsOneWidget);
      expect(find.text(l10n.sampleRateHz(48000)), findsOneWidget);
      expect(find.text(l10n.bufferFrames(128)), findsOneWidget);
      expect(find.text(l10n.latencyMs('7.42')), findsOneWidget);
      expect(find.text(l10n.bufferFrames(64)), findsOneWidget);
    });

    testWidgets('a stopped engine says what it does not know', (tester) async {
      when(() => repository.state).thenReturn(const LooperState());
      await pump(tester, looper: const LooperState(), tab: AudioTab.status);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.emDash), findsNWidgets(3));
      expect(find.text(l10n.notMeasured), findsOneWidget);
    });

    testWidgets('a timed-out measurement says so', (tester) async {
      const timedOut = EngineStatus(
        isConnected: true,
        deviceName: 'Scarlett 18i20',
        sampleRate: 48000,
        bufferFrames: 128,
        latencyState: LatencyState.timeout,
      );
      when(
        () => repository.state,
      ).thenReturn(const LooperState(status: timedOut));
      await pump(
        tester,
        looper: const LooperState(status: timedOut),
        tab: AudioTab.status,
      );
      expect(find.text(l10nOf(tester).noSignalDetected), findsOneWidget);
    });

    testWidgets('the measurement refuses to restart itself', (tester) async {
      const measuring = EngineStatus(
        isConnected: true,
        deviceName: 'Scarlett 18i20',
        sampleRate: 48000,
        bufferFrames: 128,
        latencyState: LatencyState.measuring,
      );
      when(
        () => repository.state,
      ).thenReturn(const LooperState(status: measuring));
      await pump(
        tester,
        looper: const LooperState(status: measuring),
        tab: AudioTab.status,
      );

      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('audio_measure_row')),
      );
      expect(row.onTap, isNull);
      expect(row.title, l10nOf(tester).measuringEllipsis);
    });

    testWidgets('measuring is the one action', (tester) async {
      await pump(tester, tab: AudioTab.status);
      await tester.tap(find.byKey(const Key('audio_measure_row')));
      await tester.pumpAndSettle();
      verify(repository.measureLatency).called(1);
    });
  });

  // -------------------------------------------------------------------- rail

  group('the rail', () {
    testWidgets('reaches the Audio face', (tester) async {
      await pump(tester, body: const TrayPanel());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_tray_panel')), findsOneWidget);
      // And the rail item that gets you there.
      expect(
        find.byKey(const Key('settingsTrayRail_audio')),
        findsOneWidget,
      );
    });

    testWidgets('the tab strip swaps the body and the choice survives', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.audioStatusTab));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_status_tab')), findsOneWidget);
      expect(find.byKey(const Key('audio_device_tab')), findsNothing);
      expect(tray.state.audioTab, AudioTab.status);

      // Leaving the domain and coming back lands where it was left.
      tray
        ..showDestination(SettingsTrayDestination.home)
        ..showDestination(SettingsTrayDestination.audio);
      await tester.pumpAndSettle();
      expect(tray.state.audioTab, AudioTab.status);
    });
  });
}
