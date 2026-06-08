import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/big_picture_view.dart';
import 'package:loopy/looper/view/looper_view.dart';
import 'package:loopy/ui_mode/ui_mode.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository] and renders
/// the desktop layout or the big-picture grid depending on the [UiModeCubit].
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  const LooperPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => LooperBloc(
        repository: context.read<LooperRepository>(),
        controller: context.read<ControllerRepository>(),
      ),
      child: BlocBuilder<UiModeCubit, UiMode>(
        builder: (context, mode) => mode == UiMode.bigPicture
            ? const BigPictureView()
            : const LooperView(),
      ),
    );
  }
}
