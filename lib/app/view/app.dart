import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
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
  /// second OS window.
  const App({
    required this.repository,
    required this.controllerRepository,
    required this.settings,
    required this.waveformWindow,
    super.key,
  });

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI/GPIO → looper actions).
  final ControllerRepository controllerRepository;

  /// The shared settings repository (persists latency calibration).
  final SettingsRepository settings;

  /// Manages the secondary output-waveform window.
  final WaveformWindowService waveformWindow;

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: repository),
        RepositoryProvider.value(value: controllerRepository),
        RepositoryProvider.value(value: settings),
      ],
      child: BlocProvider(
        create: (context) {
          final cubit = UiModeCubit(
            settings: context.read<SettingsRepository>(),
          );
          unawaited(cubit.load());
          return cubit;
        },
        child: _AppView(waveformWindow: waveformWindow),
      ),
    );
  }
}

/// Builds the themed [MaterialApp] and, in big-picture mode, opens the
/// secondary waveform window and streams output frames to it.
class _AppView extends StatefulWidget {
  const _AppView({required this.waveformWindow});

  final WaveformWindowService waveformWindow;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  Timer? _pushTimer;

  @override
  void dispose() {
    _pushTimer?.cancel();
    unawaited(widget.waveformWindow.close());
    super.dispose();
  }

  Future<void> _applyMode(UiMode mode) async {
    if (mode == UiMode.bigPicture) {
      await widget.waveformWindow.open();
      _pushTimer ??= Timer.periodic(_waveformFrame, (_) {
        if (!mounted) return;
        widget.waveformWindow.pushWaveform(
          context.read<LooperRepository>().readWaveform(),
        );
      });
    } else {
      _pushTimer?.cancel();
      _pushTimer = null;
      await widget.waveformWindow.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<UiModeCubit, UiMode>(
      listenWhen: (previous, current) => previous != current,
      listener: (_, mode) => unawaited(_applyMode(mode)),
      child: BlocBuilder<UiModeCubit, UiMode>(
        builder: (context, mode) => MaterialApp(
          theme: mode == UiMode.bigPicture
              ? AppTheme.bigPicture
              : AppTheme.desktop,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LooperPage(),
        ),
      ),
    );
  }
}
