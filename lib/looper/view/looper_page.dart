import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/looper/view/big_picture_view.dart';
import 'package:loopy/session/session.dart';
import 'package:session_repository/session_repository.dart';

/// Entry point for the looper feature.
///
/// Provides a [SessionCubit] for save/load/export (backed by the shared
/// [SessionRepository]), then renders the big-picture performance view. The
/// `LooperBloc` and `BigPictureCubit` are provided app-wide (see `App`) so the
/// settings page, pushed above this page, can reach them.
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  ///
  /// [sessionDirectory] resolves the on-disk session bundle directory.
  const LooperPage({required this.sessionDirectory, super.key});

  /// Resolves the session bundle directory (e.g. the app documents folder).
  final Future<String> Function() sessionDirectory;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => SessionCubit(
        repository: context.read<SessionRepository>(),
        directory: sessionDirectory,
      ),
      child: const BigPictureView(),
    );
  }
}
