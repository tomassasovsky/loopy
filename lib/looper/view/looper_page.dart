import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/big_picture_view.dart';
import 'package:loopy/looper/view/looper_view.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:settings_repository/settings_repository.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository], then
/// renders the desktop layout or big-picture grid per the [UiModeCubit]. The
/// `BigPictureCubit` is provided app-wide so the settings page can reach it.
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  const LooperPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => LooperBloc(
        repository: context.read<LooperRepository>(),
        controller: context.read<ControllerRepository>(),
        settings: context.read<SettingsRepository>(),
      ),
      child: BlocBuilder<UiModeCubit, UiMode>(
        builder: (context, mode) => mode == UiMode.bigPicture
            ? const BigPictureView()
            : const LooperView(),
      ),
    );
  }
}
