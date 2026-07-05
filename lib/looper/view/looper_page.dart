import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository] and a
/// [SessionCubit] for save/load/export (backed by the shared
/// [SessionRepository]), then renders the Tracks view. The
/// `TracksCubit` is provided app-wide so the settings page can reach it.
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  ///
  /// [exportDirectory] resolves the directory a mixdown / stems export is
  /// written to. Named sessions live under the repository's own catalog root.
  const LooperPage({required this.exportDirectory, super.key});

  /// Resolves the mixdown / stems export directory (a sibling of the named
  /// sessions catalog under the app documents folder).
  final Future<String> Function() exportDirectory;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => LooperBloc(
            repository: context.read<LooperRepository>(),
            controller: context.read<ControllerRepository>(),
            settings: context.read<SettingsRepository>(),
          ),
        ),
        BlocProvider(
          create: (context) => SessionCubit(
            repository: context.read<SessionRepository>(),
            looper: context.read<LooperRepository>(),
            exportDirectory: exportDirectory,
          ),
        ),
      ],
      // While the on-screen pedal is the bound output, the Tracks view is
      // reframed as the pedal top plate (with the TracksView embedded in
      // its main screen); otherwise the faceplate renders the TracksView
      // full-screen as usual. The gate lives in [PedalFaceplate].
      child: const PedalFaceplate(),
    );
  }
}
