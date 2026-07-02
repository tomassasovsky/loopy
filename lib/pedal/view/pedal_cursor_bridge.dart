import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';

/// Mirrors the pedal's cursor onto the app's tracks cursor.
///
/// This is bloc-to-bloc communication done at the presentation layer (per
/// https://bloclibrary.dev/architecture/#bloc-to-bloc-communication): rather
/// than [PedalCubit] holding a reference to (or a callback into)
/// [TracksCubit], a [BlocListener] watches the pedal's [PedalState] and,
/// when its selected track moves, tells the shared [TracksCubit] to select
/// it — which also reveals that track's bank. The two cubits stay decoupled;
/// neither knows about the other.
class PedalCursorBridge extends StatelessWidget {
  /// Creates a [PedalCursorBridge] wrapping [child].
  const PedalCursorBridge({required this.child, super.key});

  /// The subtree that renders below the bridge.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<PedalCubit, PedalState>(
      listenWhen: (previous, current) =>
          previous.selectedTrack != current.selectedTrack,
      // select() also reveals the track's bank, so a single hop keeps the
      // app's bank + selection in step with the pedal.
      listener: (context, state) =>
          context.read<TracksCubit>().select(state.selectedTrack),
      child: child,
    );
  }
}
