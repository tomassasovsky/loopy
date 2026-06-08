import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/looper_view.dart';
import 'package:loopy/session/session.dart';
import 'package:session_repository/session_repository.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository] and a
/// [SessionCubit] for save/load/export, backed by the shared
/// [SessionRepository].
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  ///
  /// [sessionDirectory] resolves the on-disk session bundle directory.
  const LooperPage({required this.sessionDirectory, super.key});

  /// Resolves the session bundle directory (e.g. the app documents folder).
  final Future<String> Function() sessionDirectory;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => LooperBloc(
            repository: context.read<LooperRepository>(),
            controller: context.read<ControllerRepository>(),
          ),
        ),
        BlocProvider(
          create: (context) => SessionCubit(
            repository: context.read<SessionRepository>(),
            directory: sessionDirectory,
          ),
        ),
      ],
      child: const LooperView(),
    );
  }
}
