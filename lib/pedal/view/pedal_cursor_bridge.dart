import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';

/// Keeps the pedal's cursor and the app's tracks cursor in step — both ways.
///
/// This is bloc-to-bloc communication done at the presentation layer (per
/// https://bloclibrary.dev/architecture/#bloc-to-bloc-communication): rather
/// than [PedalCubit] holding a reference to (or a callback into)
/// [TracksCubit], two [BlocListener]s mirror the one shared cursor:
///
///  - pedal → app: a footswitch selection moves the on-screen selection (and
///    reveals that track's bank);
///  - app → pedal: an on-screen click or digit-key selection moves the pedal
///    cursor, so the pedal's UNDO / Rec-Play / STOP act on the track the user
///    is looking at — the two undo surfaces must never target different
///    tracks.
///
/// The mirrored emits settle immediately: re-selecting the already-selected
/// channel produces an equal state, which cubits do not re-emit.
class PedalCursorBridge extends StatelessWidget {
  /// Creates a [PedalCursorBridge] wrapping [child].
  const PedalCursorBridge({required this.child, super.key});

  /// The subtree that renders below the bridge.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<PedalCubit, PedalState>(
          listenWhen: (previous, current) =>
              previous.selectedTrack != current.selectedTrack,
          // select() also reveals the track's bank, so a single hop keeps the
          // app's bank + selection in step with the pedal.
          listener: (context, state) =>
              context.read<TracksCubit>().select(state.selectedTrack),
        ),
        BlocListener<TracksCubit, TracksState>(
          listenWhen: (previous, current) =>
              previous.selectedChannel != current.selectedChannel,
          listener: (context, state) =>
              context.read<PedalCubit>().selectTrack(state.selectedChannel),
        ),
      ],
      child: child,
    );
  }
}
