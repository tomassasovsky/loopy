import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:led_client/led_client.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/audio_bootstrap.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/led/led.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// How often the main window pushes a waveform frame to the second window.
const _waveformFrame = Duration(milliseconds: 33); // ~30 fps

/// The root application widget.
class App extends StatelessWidget {
  /// Creates an [App] driven by the injected repositories.
  ///
  /// The repositories and [waveformWindow] are injected so tests can supply
  /// fakes / a no-op window service instead of the native device and a real
  /// second OS window. [initialAsioDrivers] is the ASIO driver list enumerated
  /// at startup, cached by the audio-setup cubit for the picker.
  const App({
    required this.repository,
    required this.controllerRepository,
    required this.midiDeviceRepository,
    required this.settings,
    required this.waveformWindow,
    required this.sessionRepository,
    required this.sessionDirectory,
    this.pedalRepository,
    this.pedalSimulator,
    this.ledRepository,
    this.displayCount,
    this.audioRecoveryConfig,
    this.initialAsioDrivers = const [],
    super.key,
  });

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI/GPIO → looper actions).
  final ControllerRepository controllerRepository;

  /// The MIDI input device repository (owns the foot-controller lifecycle). It
  /// borrows the long-lived native MIDI source from [controllerRepository] and
  /// never disposes it; the [MidiSetupCubit] projects its state.
  final MidiDeviceRepository midiDeviceRepository;

  /// The bidirectional pedal repository (MIDI output + reused input capture),
  /// or `null` when none was built — a no-op transport is substituted so pedal
  /// cubit always exists and its settings picker shows an empty state. Owned by
  /// the [PedalCubit], which disposes it.
  final PedalRepository? pedalRepository;

  /// The on-screen pedal simulator transport that [pedalRepository] is built
  /// over, or `null` when none was built. The `PedalFaceplate` injects presses
  /// and reads decoded frames from it. Disposed by the [PedalCubit] (via the
  /// repository), so it is provided by value, not created here.
  final SimulatorPedalTransport? pedalSimulator;

  /// The Raspberry Pi console's LED driver channel, or `null` off-Pi — a no-op
  /// channel is substituted so the [LedCubit] always exists. Owned by the
  /// [LedCubit], which disposes it.
  final LedRepository? ledRepository;

  /// Reports the number of connected displays, for the dual-display console's
  /// single-display fallback. `null` (the default) disables the fallback
  /// (assumes the usual multi-window desktop); the Pi entrypoint wires the real
  /// platform display count.
  final int Function()? displayCount;

  /// The pinned audio config a boot auto-start could not open, handed to the
  /// [AudioRecoveryCubit] so the engine auto-starts when that device reappears.
  /// `null` (the default) when the engine started or there is no pinned device.
  final EngineConfig? audioRecoveryConfig;

  /// The shared settings repository (persists latency calibration + config).
  final SettingsRepository settings;

  /// Manages the secondary output-waveform window.
  final WaveformWindowService waveformWindow;

  /// The ASIO drivers enumerated at startup, cached by the audio-setup cubit so
  /// the picker stays populated even while ASIO holds the device (R1).
  final List<AudioDevice> initialAsioDrivers;

  /// The shared session repository (save/load + export), sharing the engine.
  final SessionRepository sessionRepository;

  /// Resolves the on-disk session bundle directory.
  final Future<String> Function() sessionDirectory;

  @override
  Widget build(BuildContext context) {
    // The pedal simulator and the pedal repository share one transport graph
    // (the repository is built over the simulator), so the faceplate injects
    // into and reads frames from the same object the cubit drives. The `??`
    // short-circuits in production (both provided), so nothing is allocated on
    // rebuild; the fallbacks only fire in tests.
    final pedalSim =
        pedalSimulator ??
        SimulatorPedalTransport(inner: const NoopPedalTransport());
    final pedalRepo = pedalRepository ?? PedalRepository(pedalSim);
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: repository),
        RepositoryProvider.value(value: controllerRepository),
        RepositoryProvider.value(value: midiDeviceRepository),
        RepositoryProvider.value(value: settings),
        RepositoryProvider.value(value: sessionRepository),
        RepositoryProvider.value(value: pedalSim),
      ],
      child: MultiBlocProvider(
        providers: [
          // Provided app-wide (not just on the looper page) so the settings
          // route — pushed on the root navigator, above the looper page — can
          // drive routing edits through the bloc, mirroring the in-view routing
          // controls. The TracksCubit below is hoisted for the same reason.
          BlocProvider(
            create: (context) => LooperBloc(
              repository: context.read<LooperRepository>(),
              controller: context.read<ControllerRepository>(),
              settings: context.read<SettingsRepository>(),
            ),
          ),
          BlocProvider(
            create: (context) {
              final cubit = TracksCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = HighContrastCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = WaveformWindowCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = RefreshRateCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = QuantizeCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            // Not lazy: the monitor graph page is the only widget that reads
            // this cubit, but the saved per-input monitors must be applied to
            // the engine at startup — otherwise monitoring stays off until the
            // user opens "configure input monitoring".
            lazy: false,
            create: (context) {
              final cubit = MonitorCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = RecordOptionsCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Provided at the shell (not just the setup screen) so the device
          // picker, the persisted selection, and the connect/disconnect banner
          // stay live during normal looping, not only during first-run setup.
          BlocProvider(
            create: (context) => AudioSetupCubit(
              repository: context.read<LooperRepository>(),
              settings: context.read<SettingsRepository>(),
              asioSelectable: platformAsioSelectable,
              initialAsioDrivers: initialAsioDrivers,
            ),
          ),
          // Eager (not lazy): the MIDI-setup cubit performs the launch
          // auto-reconnect of the saved foot controller, so it must be created
          // on startup, not only when the settings page first reads it. It
          // holds no audio dependency — switching/losing MIDI never restarts
          // the engine.
          BlocProvider(
            lazy: false,
            create: (context) => MidiSetupCubit(
              repository: context.read<MidiDeviceRepository>(),
            ),
          ),
          // Eager (not lazy): the pedal cubit auto-binds the saved output
          // device on launch and starts projecting LED frames, so it must be at
          // startup. Its cursor is mirrored onto the shared TracksCubit by
          // PedalCursorBridge (a presentation-layer BlocListener), so the two
          // cubits stay decoupled.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PedalCubit(
                pedal: pedalRepo,
                looper: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Eager (not lazy): the LED cubit runs the boot-time driver health
          // handshake and starts projecting transport state to the console's
          // WS2812 driver at startup. Off-Pi it gets a no-op channel, no fault.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = LedCubit(
                led: ledRepository ?? LedRepository(),
                looper: context.read<LooperRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Eager (not lazy): the recovery cubit must be watching at boot for a
          // pinned interface that was unplugged when auto-start ran, so it can
          // start audio the moment it reappears. Inert when there is nothing to
          // recover (engine already running / no pinned device).
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = AudioRecoveryCubit(
                looper: context.read<LooperRepository>(),
                recoveryConfig: audioRecoveryConfig,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
        ],
        // Bridges the pedal's cursor onto the shared TracksCubit at the
        // presentation layer (bloc-to-bloc communication via BlocListener).
        child: PedalCursorBridge(
          child: _AppView(
            waveformWindow: waveformWindow,
            sessionDirectory: sessionDirectory,
            displayCount: displayCount,
          ),
        ),
      ),
    );
  }
}

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for tracks mode.
class _AppView extends StatefulWidget {
  const _AppView({
    required this.waveformWindow,
    required this.sessionDirectory,
    this.displayCount,
  });

  final WaveformWindowService waveformWindow;
  final Future<String> Function() sessionDirectory;
  final int Function()? displayCount;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  Timer? _pushTimer;

  /// Drives the app-level device connect/disconnect banner. Held at the shell
  /// (above the pages) so the banner survives navigation between layouts.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Resolves localized strings from inside [MaterialApp] when this state
  /// sits above it in the tree.
  AppLocalizations get _l10n {
    final localizedContext = loopyNavigatorKey.currentContext;
    if (localizedContext != null) {
      return localizedContext.l10n;
    }
    return lookupAppLocalizations(PlatformDispatcher.instance.locale);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_bootstrapWindow()),
    );
  }

  /// Waits for the persisted waveform-window preference before opening the
  /// window so a disabled preference does not flash a second OS window on
  /// launch.
  Future<void> _bootstrapWindow() async {
    await context.read<WaveformWindowCubit>().load();
    if (!mounted) return;
    await _syncWindow();
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    unawaited(widget.waveformWindow.close());
    super.dispose();
  }

  /// Whether only one display is connected (the console expects two). `null`
  /// detection (desktop default) is treated as multi-display.
  bool get _isSingleDisplay => (widget.displayCount?.call() ?? 2) < 2;

  /// Opens the secondary waveform window when it is enabled; closes it
  /// otherwise.
  Future<void> _syncWindow() async {
    if (!mounted) return;
    final shouldOpen = context.read<WaveformWindowCubit>().state;
    if (shouldOpen) {
      // On a single-display console the waveform has nowhere to land: skip the
      // second window and show a notice rather than a half-blank setup.
      if (_isSingleDisplay) {
        _showSingleDisplayNotice();
        return;
      }
      final ready = await widget.waveformWindow.open(
        title: _l10n.outputWaveformWindowTitle,
      );
      if (!mounted) return;
      if (!ready) {
        // The window never readied: surface it and don't stream frames to a
        // dead window (the real service has already set its controller, so
        // pushWaveform would otherwise not no-op).
        _showWaveformWindowFailedBanner();
        return;
      }
      _pushTimer ??= Timer.periodic(_waveformFrame, (_) {
        if (!mounted) return;
        final looper = context.read<LooperRepository>();
        final tracks = context.read<TracksCubit>();
        widget.waveformWindow.pushWaveform(
          looper.readWaveform(),
          looper.state.transport.progress,
          tracks.state.names[tracks.state.selectedChannel],
        );
      });
    } else {
      _pushTimer?.cancel();
      _pushTimer = null;
      await widget.waveformWindow.close();
    }
  }

  /// Shows a persistent "disconnected — trying to reconnect" banner when a
  /// pinned device is lost, and replaces it with a transient "reconnected"
  /// snackbar when it returns. Driven from [AudioSetupCubit] connectivity
  /// transitions; mounted on the shell messenger so it persists across layouts.
  void _showConnectivityBanner(AudioSetupState state) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = _l10n;
    messenger.clearMaterialBanners();
    final name = state.connectivityDeviceName.isEmpty
        ? l10n.audioDeviceFallbackName
        : state.connectivityDeviceName;
    switch (state.deviceConnectivity) {
      case DeviceConnectivity.lost:
        messenger.showMaterialBanner(
          MaterialBanner(
            key: const Key('app_deviceLost_banner'),
            content: Text(l10n.deviceDisconnectedBanner(name)),
            leading: const Icon(Icons.warning_amber_rounded),
            actions: [
              TextButton(
                onPressed: messenger.clearMaterialBanners,
                child: Text(l10n.dismiss),
              ),
            ],
          ),
        );
      case DeviceConnectivity.restored:
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              key: const Key('app_deviceRestored_snackbar'),
              content: Text(l10n.deviceReconnectedSnackbar(name)),
              duration: const Duration(seconds: 3),
            ),
          );
      case DeviceConnectivity.none:
        break;
    }
  }

  /// The MIDI analog of [_showConnectivityBanner]: a persistent disconnect
  /// banner when the pinned foot controller is unplugged, replaced by a
  /// transient "reconnected" snackbar when it returns. Independent of the audio
  /// device banner above (a separate messenger entry).
  void _showMidiConnectivityBanner(MidiSetupState state) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = _l10n;
    final connection = state.connection;
    final name = connection.connectivityDeviceName.isEmpty
        ? connection.selectedName
        : connection.connectivityDeviceName;
    switch (connection.connectivity) {
      case MidiConnectivity.lost:
        messenger.showMaterialBanner(
          MaterialBanner(
            key: const Key('app_midiLost_banner'),
            content: Text(l10n.midiDisconnectedBanner(name)),
            leading: const Icon(Icons.piano_off_outlined),
            actions: [
              TextButton(
                onPressed: messenger.clearMaterialBanners,
                child: Text(l10n.dismiss),
              ),
            ],
          ),
        );
      case MidiConnectivity.restored:
        messenger
          ..clearMaterialBanners()
          ..showSnackBar(
            SnackBar(
              key: const Key('app_midiRestored_snackbar'),
              content: Text(l10n.midiReconnectedSnackbar(name)),
              duration: const Duration(seconds: 3),
            ),
          );
      case MidiConnectivity.none:
        break;
    }
  }

  /// Shows a persistent banner when the console's LED driver does not answer
  /// the boot-time health ping, so a missing/unflashed driver is a visible fault
  /// rather than silent dark LEDs. Off-Pi the channel reports healthy, so this
  /// never fires there.
  void _showLedBanner(LedState state) {
    final messenger = _messengerKey.currentState;
    if (messenger == null || state.health != LedHealth.missing) return;
    final l10n = _l10n;
    messenger.showMaterialBanner(
      MaterialBanner(
        key: const Key('app_ledMissing_banner'),
        content: Text(l10n.ledDriverMissingBanner),
        leading: const Icon(Icons.lightbulb_outline),
        actions: [
          TextButton(
            onPressed: messenger.clearMaterialBanners,
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    );
  }

  /// Non-pointer signal that the console is waiting for its pinned audio
  /// interface to (re)appear at boot, after which it auto-starts the engine.
  /// The banner clears itself when recovery finishes (status returns to idle).
  void _showAudioRecoveryBanner(AudioRecoveryState state) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = _l10n;
    if (state.status != AudioRecoveryStatus.waitingForDevice) {
      messenger.clearMaterialBanners();
      return;
    }
    messenger.showMaterialBanner(
      MaterialBanner(
        key: const Key('app_audioRecovery_banner'),
        content: Text(l10n.audioRecoveryWaitingBanner),
        leading: const Icon(Icons.usb_off_outlined),
        actions: [
          TextButton(
            onPressed: () => unawaited(openLoopySettings()),
            child: Text(l10n.settingsMenuItem),
          ),
        ],
      ),
    );
  }

  /// Operator-visible banner when the secondary waveform window failed to come
  /// up (the open path would otherwise degrade silently to a dark screen).
  void _showWaveformWindowFailedBanner() {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = _l10n;
    messenger.showMaterialBanner(
      MaterialBanner(
        key: const Key('app_waveformWindowFailed_banner'),
        content: Text(l10n.waveformWindowFailedBanner),
        leading: const Icon(Icons.desktop_access_disabled_outlined),
        actions: [
          TextButton(
            onPressed: messenger.clearMaterialBanners,
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    );
  }

  /// Notice when only one display is connected on the dual-display console, so
  /// a missing second panel is obvious rather than a half-blank setup.
  void _showSingleDisplayNotice() {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = _l10n;
    messenger.showMaterialBanner(
      MaterialBanner(
        key: const Key('app_singleDisplay_banner'),
        content: Text(l10n.singleDisplayNotice),
        leading: const Icon(Icons.monitor_outlined),
        actions: [
          TextButton(
            onPressed: messenger.clearMaterialBanners,
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    );
  }

  List<PlatformMenuItem> _menus(BuildContext context) => [
    PlatformMenu(
      label: context.l10n.appMenuLabel,
      menus: [
        PlatformMenuItem(
          label: context.l10n.settingsMenuItem,
          shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: openLoopySettings,
        ),
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<WaveformWindowCubit, bool>(
          listenWhen: (previous, current) => previous != current,
          listener: (_, _) => unawaited(_syncWindow()),
        ),
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.deviceConnectivity != current.deviceConnectivity,
          listener: (_, state) => _showConnectivityBanner(state),
        ),
        BlocListener<MidiSetupCubit, MidiSetupState>(
          listenWhen: (previous, current) =>
              previous.connection.connectivity !=
              current.connection.connectivity,
          listener: (_, state) => _showMidiConnectivityBanner(state),
        ),
        BlocListener<LedCubit, LedState>(
          listenWhen: (previous, current) => previous.health != current.health,
          listener: (_, state) => _showLedBanner(state),
        ),
        BlocListener<AudioRecoveryCubit, AudioRecoveryState>(
          listenWhen: (previous, current) => previous.status != current.status,
          listener: (_, state) => _showAudioRecoveryBanner(state),
        ),
      ],
      child: MaterialApp(
        scaffoldMessengerKey: _messengerKey,
        navigatorKey: loopyNavigatorKey,
        // The manual toggle forces the high-contrast palette on every platform;
        // highContrastTheme additionally honors the OS flag where Flutter
        // delivers it (iOS only).
        theme: context.watch<HighContrastCubit>().state
            ? AppTheme.highContrast
            : AppTheme.neon,
        highContrastTheme: AppTheme.highContrast,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final page = LooperPage(sessionDirectory: widget.sessionDirectory);
            if (!loopyUsesFlutterTitleBar) return page;
            return LoopyWindowChromeShell(
              title: context.l10n.appMenuLabel,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: page,
            );
          },
        ),
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          var app = child ?? const SizedBox.shrink();
          if (defaultTargetPlatform == TargetPlatform.macOS) {
            app = PlatformMenuBar(menus: _menus(context), child: app);
          }
          return app;
        },
      ),
    );
  }
}
