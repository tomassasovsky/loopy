import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:settings_repository/settings_repository.dart';

/// The root application widget.
class App extends StatelessWidget {
  /// Creates an [App] driven by the injected repositories.
  ///
  /// The repositories are injected so tests can supply ones backed by fakes
  /// instead of the native device / hardware controllers.
  const App({
    required this.repository,
    required this.controllerRepository,
    required this.settings,
    super.key,
  });

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI/GPIO → looper actions).
  final ControllerRepository controllerRepository;

  /// The shared settings repository (persists latency calibration).
  final SettingsRepository settings;

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
      ),
    );
  }
}
