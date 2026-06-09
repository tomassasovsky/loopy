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

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: repository),
        RepositoryProvider.value(value: controllerRepository),
        RepositoryProvider.value(value: settings),
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
        ],
        child: _AppView(
          waveformWindow: waveformWindow,
          needsSetup: needsSetup,
        ),
      ),
    );
  }
}

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for big-picture mode.
class _AppView extends StatefulWidget {
  const _AppView({required this.waveformWindow, required this.needsSetup});

  final WaveformWindowService waveformWindow;
  final bool needsSetup;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  Timer? _pushTimer;

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
      await widget.waveformWindow.open();
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

  List<PlatformMenuItem> _menus() => const [
    PlatformMenu(
      label: 'Loopy',
      menus: [
        PlatformMenuItem(
          label: 'Settings…',
          shortcut: SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: openLoopySettings,
        ),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
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
      ],
      child: BlocBuilder<UiModeCubit, UiMode>(
        builder: (context, mode) {
          Widget app = MaterialApp(
            navigatorKey: loopyNavigatorKey,
            theme: mode == UiMode.bigPicture
                ? AppTheme.bigPicture
                : AppTheme.desktop,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _RootView(needsSetup: widget.needsSetup),
            debugShowCheckedModeBanner: false,
          );
          if (defaultTargetPlatform == TargetPlatform.macOS) {
            app = PlatformMenuBar(menus: _menus(), child: app);
          }
          return app;
        },
      ),
    );
  }
}

/// On a first run, shows the audio setup as the start screen until the engine
/// connects, then hands off to the looper. Otherwise shows the looper directly.
class _RootView extends StatefulWidget {
  const _RootView({required this.needsSetup});

  final bool needsSetup;

  @override
  State<_RootView> createState() => _RootViewState();
}

class _RootViewState extends State<_RootView> {
  late bool _inSetup = widget.needsSetup;

  @override
  Widget build(BuildContext context) {
    if (!_inSetup) return const LooperPage();
    return BlocProvider(
      create: (context) => AudioSetupCubit(
        repository: context.read<LooperRepository>(),
        settings: context.read<SettingsRepository>(),
      ),
      child: BlocListener<AudioSetupCubit, AudioSetupState>(
        listenWhen: (previous, current) =>
            !previous.engineStatus.isConnected &&
            current.engineStatus.isConnected,
        listener: (_, _) => setState(() => _inSetup = false),
        child: const AudioSetupView(),
      ),
    );
  }
}
