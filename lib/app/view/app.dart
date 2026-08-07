import 'dart:async';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/audio_bootstrap.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';
import 'package:segno/common/pedal_device.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/flashed_firmware.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/update/view/pedal_firmware_gate.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:segno/window/window_chrome.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';
import 'package:update_repository/update_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

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
    required this.performanceRepository,
    required this.exportDirectory,
    this.pedalRepository,
    this.pedalSimulator,
    this.displayCount,
    this.audioRecoveryConfig,
    this.initialAsioDrivers = const [],
    this.updates = const UpdateRepository(
      backend: UnsupportedPlatformBackend(),
    ),
    this.wifi = const WifiRepository(client: UnsupportedWifiClient()),
    this.bluetooth = const BluetoothRepository(
      client: UnsupportedBluetoothClient(),
    ),
    this.brightness = const UnsupportedBrightnessClient(),
    super.key,
  });

  /// The software-update repository. Defaults to an inert
  /// (unsupported-platform) instance so the update UI stays hidden; the app
  /// entrypoint injects the platform-appropriate one.
  final UpdateRepository updates;

  /// Appliance WiFi repository (Control Center). Defaults unsupported.
  final WifiRepository wifi;

  /// Appliance Bluetooth repository (Control Center). Defaults unsupported.
  final BluetoothRepository bluetooth;

  /// Appliance brightness client (Control Center slider). Defaults unsupported.
  final BrightnessClient brightness;

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI → looper actions).
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

  /// The shared performance-recording repository, sharing the engine.
  final PerformanceRepository performanceRepository;

  /// Resolves the directory a mixdown / stems export is written to.
  final Future<String> Function() exportDirectory;

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
        RepositoryProvider.value(value: performanceRepository),
        RepositoryProvider.value(value: pedalSim),
        RepositoryProvider.value(value: updates),
        RepositoryProvider.value(value: wifi),
        RepositoryProvider.value(value: bluetooth),
        RepositoryProvider.value(value: brightness),
      ],
      child: MultiBlocProvider(
        providers: [
          // Provided app-wide so the startup update banner and the settings
          // Updates section share one cubit. lazy:false so the passive check
          // (when auto-check is on) runs at launch to power the banner.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = UpdateCubit(
                updates: context.read<UpdateRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Runs the pedal flash an OS update left pending, and holds the
          // looper closed while it does. lazy:false so it starts with the app
          // rather than when something first reads it.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PedalFirmwareCubit(
                updates: context.read<UpdateRepository>(),
              );
              unawaited(cubit.run());
              return cubit;
            },
          ),
          // App-wide brightness: software dim in [MaterialApp.builder] + DDC
          // when the host helper supports it (LG TVs often do not).
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = DisplayBrightnessCubit(
                settings: context.read<SettingsRepository>(),
                client: context.read<BrightnessClient>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Provided app-wide (not just on the looper page) so the settings
          // route — pushed on the root navigator, above the looper page — can
          // drive routing edits through the bloc, mirroring the in-view routing
          // controls. The TracksCubit below is hoisted for the same reason.
          BlocProvider(
            create: (context) {
              final bloc = LooperBloc(
                repository: context.read<LooperRepository>(),
                controller: context.read<ControllerRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              // Boot-restore the persisted mode (B5c) — dispatched as an
              // event, not a bloc method (bloc_lint's
              // avoid_public_bloc_methods).
              unawaited(
                restoreLooperMode(bloc, context.read<SettingsRepository>()),
              );
              return bloc;
            },
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
          // Beside the track names and for the same reason: an input is called
          // what the player calls it on every surface that shows one — the
          // Audio face's input list, the Tracks routing summary, and the
          // per-track lane list — so the names load once, here.
          BlocProvider(
            create: (context) {
              final cubit = InputsCubit(
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
            create: (context) {
              final cubit = TempoCubit(
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
          // Eager (not lazy): the ONE control-surface interpreter and owner
          // of stored user intent (mode / cursor / bank / play intent). The
          // pedal's decoded footswitches reach it through PedalRepository's
          // event stream and its projected LED frames leave through the same
          // repository, so the keyboard, on-screen widgets, and the pedal
          // share one cursor, one mode, one command path — with repositories
          // composed at the bloc level, per the layered architecture.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = ControlCubit(
                looper: context.read<LooperRepository>(),
                pedal: pedalRepo,
                settings: context.read<SettingsRepository>(),
                performance: context.read<PerformanceRepository>(),
                // Both of these were missing, and external MIDI mapping had
                // therefore never worked in a shipped build: without
                // `controller` nothing subscribes to the binding events and
                // `learnControllerBinding` returns on its first line, so Add
                // sweep / Add switch picked a target and then did nothing at
                // all; without `midiDevices` a controller coming back re-armed
                // nothing. Both repositories were already built and provided
                // app-wide — they were simply never handed to the one cubit
                // that owns controller intent.
                controller: context.read<ControllerRepository>(),
                midiDevices: context.read<MidiDeviceRepository>(),
              );
              unawaited(cubit.load()); // boot-default mode restore
              return cubit;
            },
          ),
          // Eager (not lazy): the pedal LINK feature auto-binds the saved
          // output device on launch and keeps it bound across hotplugs. It
          // shares the PedalRepository with ControlCubit (binding here,
          // events/frames there) — the cubits know nothing of each other.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PedalCubit(
                pedal: pedalRepo,
                settings: context.read<SettingsRepository>(),
                // Redundant only on a desktop analysis run — see run_segno.
                // ignore: avoid_redundant_argument_values
                autoBindProductNames: kPedalAutoBindProductNames,
                // Console only; null on desktop, where the manual setting
                // stays in charge.
                // ignore: avoid_redundant_argument_values
                flashedProtocolVersion: kFlashedPedalProtocolVersionReader,
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
          // Eager (not lazy): must be watching at boot to find a capture a
          // crash left unfinalized (D-SALVAGE) before the tracks view first
          // builds, so the recovery prompt is ready the instant it mounts.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PerformanceRecorderCubit(
                performance: context.read<PerformanceRepository>(),
                // The real tempo to stamp the `.als` export with, read fresh
                // at each export (not captured once here) — the live
                // engine's current tempo via the looper repository, the same
                // TransportState.tempoBpm field session_repository threads
                // into the v4 manifest. `0` (grid off / tempo never set)
                // falls through to daw_export's own 120 BPM fallback.
                currentTempoBpm: () =>
                    context.read<LooperRepository>().state.transport.tempoBpm,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
        ],
        child: _AppView(
          waveformWindow: waveformWindow,
          exportDirectory: exportDirectory,
          displayCount: displayCount,
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
    required this.exportDirectory,
    this.displayCount,
  });

  final WaveformWindowService waveformWindow;
  final Future<String> Function() exportDirectory;
  final int Function()? displayCount;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  Timer? _pushTimer;

  /// Resolves localized strings from inside [MaterialApp] when this state
  /// sits above it in the tree.
  AppLocalizations get _l10n {
    final localizedContext = segnoNavigatorKey.currentContext;
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
        final control = context.read<ControlCubit>().state;
        final cursor = control.cursor;
        widget.waveformWindow.pushWaveform(
          looper.readWaveform(),
          looper.state.transport.progress,
          tracks.state.nameOf(cursor),
        );
        // Same timer, different discipline: the waveform changes every frame,
        // the readout does not, so `pushReadout` drops anything equal to what
        // it last sent rather than re-serialising eight track records at frame
        // rate across an engine boundary.
        widget.waveformWindow.pushReadout(
          _readoutOf(looper.state, tracks.state, control.mode, cursor),
        );
      });
    } else {
      _pushTimer?.cancel();
      _pushTimer = null;
      await widget.waveformWindow.close();
    }
  }

  /// Projects engine + control state onto the 7" readout's value type.
  ///
  /// Pure and static so it can be tested without a window: what the second
  /// screen shows is a function of state, never of when the timer fired.
  static PerformanceReadout _readoutOf(
    LooperState looper,
    TracksState tracks,
    InteractionMode mode,
    int cursor,
  ) {
    final transport = looper.transport;
    return PerformanceReadout(
      tracks: [
        for (final track in looper.tracks)
          ReadoutTrack(
            name: tracks.nameOf(track.channel),
            state: track.state.name,
            muted: track.muted,
            pending: track.pending,
            selected: track.channel == cursor,
          ),
      ],
      tempoBpm: transport.tempoBpm,
      tsNum: transport.tsNum,
      tsDen: transport.tsDen,
      loopBars: transport.loopBars,
      isRunning: transport.isRunning,
      mode: mode.token,
    );
  }

  /// Persistent "disconnected — trying to reconnect" toast when a pinned
  /// device is lost; replaced by a short "reconnected" toast when it returns.
  void _showConnectivityBanner(AudioSetupState state) {
    final l10n = _l10n;
    dismissAppToast(AppToastId.deviceLost);
    final name = state.connectivityDeviceName.isEmpty
        ? l10n.audioDeviceFallbackName
        : state.connectivityDeviceName;
    switch (state.deviceConnectivity) {
      case DeviceConnectivity.lost:
        showAppToast(
          id: AppToastId.deviceLost,
          type: ToastificationType.warning,
          title: Text(l10n.deviceDisconnectedBanner(name)),
          icon: const Icon(Icons.warning_amber_rounded),
        );
      case DeviceConnectivity.restored:
        showAppSnackToast(
          id: AppToastId.deviceRestored,
          title: Text(l10n.deviceReconnectedSnackbar(name)),
          icon: const Icon(Icons.check_circle_outline),
        );
      case DeviceConnectivity.none:
        break;
    }
  }

  /// MIDI analog of [_showConnectivityBanner].
  void _showMidiConnectivityBanner(MidiSetupState state) {
    final l10n = _l10n;
    dismissAppToast(AppToastId.midiLost);
    final connection = state.connection;
    final name = connection.connectivityDeviceName.isEmpty
        ? connection.selectedName
        : connection.connectivityDeviceName;
    switch (connection.connectivity) {
      case MidiConnectivity.lost:
        showAppToast(
          id: AppToastId.midiLost,
          type: ToastificationType.warning,
          title: Text(l10n.midiDisconnectedBanner(name)),
          icon: const Icon(Icons.piano_off_outlined),
        );
      case MidiConnectivity.restored:
        showAppSnackToast(
          id: AppToastId.midiRestored,
          title: Text(l10n.midiReconnectedSnackbar(name)),
          icon: const Icon(Icons.check_circle_outline),
        );
      case MidiConnectivity.none:
        break;
    }
  }

  /// Waiting for the pinned audio interface at boot; clears when recovery
  /// finishes (status returns to idle).
  void _showAudioRecoveryBanner(AudioRecoveryState state) {
    final l10n = _l10n;
    if (state.status != AudioRecoveryStatus.waitingForDevice) {
      dismissAppToast(AppToastId.audioRecovery);
      return;
    }
    showAppToast(
      id: AppToastId.audioRecovery,
      type: ToastificationType.warning,
      title: Text(l10n.audioRecoveryWaitingBanner),
      icon: const Icon(Icons.usb_off_outlined),
      actions: [
        TextButton(
          onPressed: () => unawaited(openSegnoSettings()),
          child: Text(l10n.settingsMenuItem),
        ),
      ],
    );
  }

  /// Startup notice that a newer build is available. Skipped when Settings →
  /// Updates is already open. "Not now" dismisses that version; "Update…"
  /// opens the Updates section.
  void _showUpdateBanner(BuildContext context, UpdateState state) {
    final manifest = state.available;
    if (!state.shouldNotify || manifest == null) {
      dismissAppToast(AppToastId.update);
      return;
    }
    if (isSegnoUpdatesSettingsOpen) {
      dismissAppToast(AppToastId.update);
      return;
    }
    final l10n = _l10n;
    final cubit = context.read<UpdateCubit>();
    showAppToast(
      id: AppToastId.update,
      title: Text(l10n.updateBannerTitle('${manifest.version}')),
      icon: const Icon(Icons.system_update_outlined),
      actions: [
        TextButton(
          key: const Key(AppToastId.updateDismiss),
          onPressed: () {
            dismissAppToast(AppToastId.update);
            unawaited(cubit.dismiss(manifest.version));
          },
          child: Text(l10n.updateBannerDismissAction),
        ),
        TextButton(
          key: const Key(AppToastId.updateAction),
          onPressed: () {
            dismissAppToast(AppToastId.update);
            unawaited(openSegnoSettings(section: SettingsSection.updates));
          },
          child: Text(l10n.updateBannerUpdateAction),
        ),
      ],
    );
  }

  /// Secondary waveform window failed to open.
  void _showWaveformWindowFailedBanner() {
    final l10n = _l10n;
    showAppToast(
      id: AppToastId.waveformFailed,
      type: ToastificationType.error,
      title: Text(l10n.waveformWindowFailedBanner),
      icon: const Icon(Icons.desktop_access_disabled_outlined),
    );
  }

  /// Only one display on the dual-display console.
  void _showSingleDisplayNotice() {
    final l10n = _l10n;
    showAppToast(
      id: AppToastId.singleDisplay,
      type: ToastificationType.warning,
      title: Text(l10n.singleDisplayNotice),
      icon: const Icon(Icons.monitor_outlined),
    );
  }

  List<PlatformMenuItem> _menus(BuildContext context) => [
    PlatformMenu(
      label: context.l10n.appMenuLabel,
      menus: [
        PlatformMenuItem(
          label: context.l10n.settingsMenuItem,
          shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: openSegnoSettings,
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
        BlocListener<AudioRecoveryCubit, AudioRecoveryState>(
          listenWhen: (previous, current) => previous.status != current.status,
          listener: (_, state) => _showAudioRecoveryBanner(state),
        ),
        BlocListener<UpdateCubit, UpdateState>(
          listenWhen: (previous, current) =>
              previous.shouldNotify != current.shouldNotify ||
              previous.available?.version != current.available?.version,
          listener: _showUpdateBanner,
        ),
      ],
      child: ToastificationWrapper(
        config: const ToastificationConfig(
          alignment: Alignment.topCenter,
          itemWidth: 520,
          animationDuration: Duration(milliseconds: 280),
        ),
        child: MaterialApp(
          navigatorKey: segnoNavigatorKey,
          // Manual toggle forces high-contrast on every platform;
          // highContrastTheme also honors the OS flag (iOS).
          theme: context.watch<HighContrastCubit>().state
              ? AppTheme.highContrast
              : AppTheme.neon,
          highContrastTheme: AppTheme.highContrast,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              final Widget page = PedalFirmwareGate(
                child: LooperPage(exportDirectory: widget.exportDirectory),
              );
              if (!segnoUsesFlutterTitleBar && !segnoUsesCursorAutoHide) {
                return page;
              }
              return SegnoWindowChromeShell(
                title: context.l10n.appMenuLabel,
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                body: page,
              );
            },
          ),
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            // Console only: weston's kiosk-shell spawns no input panel and the
            // image ships no IME, so without this every TextField on the
            // appliance is dead — including this branch's own Wi-Fi password
            // field. Inside the brightness wrapper so the keys dim with
            // everything else.
            final typed = OnScreenKeyboardHost(
              child: child ?? const SizedBox.shrink(),
            );
            // Brightness wraps the route child only — never PlatformMenuBar —
            // so cubit rebuilds cannot remount the macOS menu delegate.
            final brightened = BlocBuilder<DisplayBrightnessCubit, double>(
              buildWhen: (previous, current) => previous != current,
              builder: (context, brightness) => SoftwareBrightness(
                brightness: brightness,
                child: typed,
              ),
            );
            if (defaultTargetPlatform != TargetPlatform.macOS) {
              return brightened;
            }
            return PlatformMenuBar(
              key: const ValueKey<String>('segno_platform_menu'),
              menus: _menus(context),
              child: brightened,
            );
          },
        ),
      ),
    );
  }
}
