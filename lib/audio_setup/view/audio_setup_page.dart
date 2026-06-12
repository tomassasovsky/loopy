import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/audio_bootstrap.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/view/audio_setup_view.dart';
import 'package:settings_repository/settings_repository.dart';

/// Entry point for the audio setup feature.
///
/// Provides an [AudioSetupCubit] backed by the shared [LooperRepository] and
/// [SettingsRepository] read from context, so callers can push it without
/// threading the repositories through.
class AudioSetupPage extends StatelessWidget {
  /// Creates an [AudioSetupPage].
  const AudioSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AudioSetupCubit(
        repository: context.read<LooperRepository>(),
        settings: context.read<SettingsRepository>(),
        defaultExclusive: platformDefaultExclusive,
        asioSelectable: platformAsioSelectable,
      ),
      child: const AudioSetupView(),
    );
  }
}
