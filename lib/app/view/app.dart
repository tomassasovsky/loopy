import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
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
  /// second OS window. [needsSetup] is `true` on a first run (no saved audio
  /// config), routing to the audio setup flow before the looper.
  const App({
    required this.repository,
    required this.controllerRepository,
    required this.settings,
    required this.waveformWindow,
    required this.sessionRepository,
    required this.sessionDirectory,
    this.needsSetup = false,
    super.key,
  });

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI/GPIO → looper actions).
  final ControllerRepository controllerRepository;

  /// The shared settings repository (persists latency calibration + config).
  final SettingsRepository settings;

  /// Manages the secondary output-waveform window.
  final WaveformWindowService waveformWindow;

  /// Whether to show the audio setup flow before the looper (first run).
  final bool needsSetup;

  /// The shared session repository (save/load + export), sharing the engine.
  final SessionRepository sessionRepository;

  /// Resolves the on-disk session bundle directory.
  final Future<String> Function() sessionDirectory;

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: repository),
        RepositoryProvider.value(value: controllerRepository),
        RepositoryProvider.value(value: settings),
        RepositoryProvider.value(value: sessionRepository),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (context) {
              final cubit = UiModeCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = BigPictureCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = BankCubit(
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
            ),
          ),
        ],
        child: _AppView(
          waveformWindow: waveformWindow,
          needsSetup: needsSetup,
          sessionDirectory: sessionDirectory,
        ),
      ),
    );
  }
}

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for big-picture mode.
class _AppView extends StatefulWidget {
  const _AppView({
    required this.waveformWindow,
    required this.needsSetup,
    required this.sessionDirectory,
  });

  final WaveformWindowService waveformWindow;
  final bool needsSetup;
  final Future<String> Function() sessionDirectory;

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

  /// Waits for persisted UI preferences before opening the waveform window so
  /// a disabled preference does not flash a second OS window on launch.
  Future<void> _bootstrapWindow() async {
    await Future.wait([
      context.read<WaveformWindowCubit>().load(),
      context.read<UiModeCubit>().load(),
    ]);
    if (!mounted) return;
    await _syncWindow();
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    unawaited(widget.waveformWindow.close());
    super.dispose();
  }

  /// Opens the secondary waveform window when big-picture mode is active and
  /// the window is enabled; closes it otherwise.
  Future<void> _syncWindow() async {
    if (!mounted) return;
    final mode = context.read<UiModeCubit>().state;
    final enabled = context.read<WaveformWindowCubit>().state;
    final shouldOpen = mode == UiMode.bigPicture && enabled;
    if (shouldOpen) {
      await widget.waveformWindow.open(
        title: _l10n.outputWaveformWindowTitle,
      );
      _pushTimer ??= Timer.periodic(_waveformFrame, (_) {
        if (!mounted) return;
        final looper = context.read<LooperRepository>();
        widget.waveformWindow.pushWaveform(
          looper.readWaveform(),
          looper.state.transport.progress,
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
        BlocListener<UiModeCubit, UiMode>(
          listenWhen: (previous, current) => previous != current,
          listener: (_, _) => unawaited(_syncWindow()),
        ),
        BlocListener<WaveformWindowCubit, bool>(
          listenWhen: (previous, current) => previous != current,
          listener: (_, _) => unawaited(_syncWindow()),
        ),
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.deviceConnectivity != current.deviceConnectivity,
          listener: (_, state) => _showConnectivityBanner(state),
        ),
      ],
      child: BlocBuilder<UiModeCubit, UiMode>(
        builder: (context, mode) {
          return MaterialApp(
            scaffoldMessengerKey: _messengerKey,
            navigatorKey: loopyNavigatorKey,
            theme: mode == UiMode.bigPicture
                ? AppTheme.bigPicture
                : AppTheme.desktop,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _RootView(
              needsSetup: widget.needsSetup,
              sessionDirectory: widget.sessionDirectory,
            ),
            debugShowCheckedModeBanner: false,
            builder: (context, child) {
              var app = child ?? const SizedBox.shrink();
              if (defaultTargetPlatform == TargetPlatform.macOS) {
                app = PlatformMenuBar(menus: _menus(context), child: app);
              }
              return app;
            },
          );
        },
      ),
    );
  }
}

/// On a first run, shows the audio setup as the start screen until the engine
/// connects, then hands off to the looper. Otherwise shows the looper directly.
class _RootView extends StatefulWidget {
  const _RootView({required this.needsSetup, required this.sessionDirectory});

  final bool needsSetup;
  final Future<String> Function() sessionDirectory;

  @override
  State<_RootView> createState() => _RootViewState();
}

class _RootViewState extends State<_RootView> {
  late bool _inSetup = widget.needsSetup;

  @override
  Widget build(BuildContext context) {
    if (!_inSetup) {
      return LooperPage(sessionDirectory: widget.sessionDirectory);
    }
    // The AudioSetupCubit is provided at the app shell, so the setup screen
    // listens to the shared instance for the connect → hand-off to the looper.
    return BlocListener<AudioSetupCubit, AudioSetupState>(
      listenWhen: (previous, current) =>
          !previous.engineStatus.isConnected &&
          current.engineStatus.isConnected,
      listener: (_, _) => setState(() => _inSetup = false),
      child: const AudioSetupView(),
    );
  }
}
