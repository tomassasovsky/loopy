import 'package:bloc/bloc.dart';
import 'package:loopy/control/control_overlay.dart';

/// The presentation MIRROR of the [ControlOverlay] domain store: re-emits the
/// store's state so widgets can `watch` mode / cursor / bank rebuilds the
/// bloc way.
///
/// Deliberately read-only — it has NO mutation methods. All writes go through
/// `ControlIntents` (or the store it wraps), so the mirror can never become a
/// second command path, and no cubit ever depends on another cubit
/// (bloc-to-bloc communication): `PedalCubit` and `ControlIntents` share the
/// overlay through the domain layer, exactly like a repository.
class ControlOverlayCubit extends Cubit<ControlOverlayState> {
  /// Creates a [ControlOverlayCubit] mirroring [overlay].
  ControlOverlayCubit({required ControlOverlay overlay})
    : _overlay = overlay,
      super(overlay.state) {
    _overlay.addListener(_onChange);
  }

  final ControlOverlay _overlay;

  void _onChange(ControlOverlayState state) {
    if (!isClosed) emit(state);
  }

  @override
  Future<void> close() async {
    _overlay.removeListener(_onChange);
    return super.close();
  }
}
