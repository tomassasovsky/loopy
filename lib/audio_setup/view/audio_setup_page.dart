import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/view/audio_setup_view.dart';
import 'package:settings_repository/settings_repository.dart';

/// Entry point for the audio setup feature.
///
/// Provides an [AudioSetupCubit] backed by the shared [LooperRepository] and
/// [SettingsRepository].
class AudioSetupPage extends StatelessWidget {
  /// Creates an [AudioSetupPage].
  const AudioSetupPage({
    required this.repository,
    required this.settings,
    super.key,
  });

  /// The shared looper repository (owns the engine).
  final LooperRepository repository;

  /// The shared settings repository (persists latency calibration).
  final SettingsRepository settings;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          AudioSetupCubit(repository: repository, settings: settings),
      child: const AudioSetupView(),
    );
  }
}
