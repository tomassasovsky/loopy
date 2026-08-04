import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/session/cubit/session_cubit.dart';

/// Re-projects and re-persists a loaded session's FX rig, across all four FX
/// stages — the canonical explanation of why a session load needs a caller at
/// all; `LooperRepository.applySession` and `LooperBloc._resyncSessionChains`
/// point here rather than restating it.
///
/// A session load applies its monitors and its Loop / Track / Master chains
/// straight to the engine through the looper repository — past the
/// [MonitorCubit] (which owns the on-screen FX-dock monitor state AND persists
/// the monitor settings) and past the [LooperBloc] (the single settings writer
/// for chains). `applySession` updates the engine and its re-apply caches but
/// deliberately never touches settings, so without this bridge the dock would
/// keep showing the PREVIOUS session's monitors and re-apply them on the next
/// edit, and every persisted chain would drift from the loaded session — a
/// wrong boot restore, in which the Track and Master stages resurrect the
/// pre-load rig and the Loop stage comes back empty (the load's destructive
/// clear zeroes those keys on the way past).
///
/// **A session load OWNS the FX keys**: after loading session B, a cold boot
/// restores session B's four FX stages and its lane counts — not the rig that
/// was live before the load, and not nothing.
///
/// Scope, deliberately: the FX stages plus the lane COUNT that bounds the Loop
/// stage's key space. The sibling lane-CONFIG keys `applySession` also resets
/// (per-lane input / output / volume / mute) still keep their pre-load values,
/// so a loaded session's lane ROUTING does not yet survive a restart — the
/// same bug class as #389, tracked separately rather than widened into it.
///
/// ONE listener for both halves, not two racing the same trigger: the monitor
/// half shipped alone, and that asymmetry with the other three stages is how
/// the wrong boot restore survived review twice. The two halves still differ in
/// how they drop state — the monitor half writes the DEFAULT for an input the
/// load dropped, the chain half deletes the key — because a monitor's five
/// keys have no "absent" reading while an absent chain key already means "no
/// chain"; both leave the next boot restoring the loaded rig.
///
/// Placed in the widget tree (not as a cubit-to-cubit subscription) because
/// [SessionCubit] composes repositories, not cubits. Lives under `looper/`
/// rather than `session/` because it is mounted by (and now depends on)
/// [LooperBloc]; the session feature stays free of looper imports.
///
/// Only a [SessionOutcome.loaded] outcome rewrites persistence — save / rename
/// / delete emit other outcomes and must not re-sync. Every session action
/// first emits a `working` state that nulls `outcome`, so the guard fires once
/// per load. A load that THROWS emits no `loaded` outcome and so is not
/// repaired here: its destructive clear has already zeroed the Loop keys, and
/// the next boot comes up dry rather than on a rig the user never had.
class SessionPersistenceSyncListener extends StatelessWidget {
  /// Creates a [SessionPersistenceSyncListener] wrapping [child].
  const SessionPersistenceSyncListener({required this.child, super.key});

  /// The subtree rendered beneath the listener.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) =>
          current.status == SessionStatus.success &&
          current.outcome == SessionOutcome.loaded,
      listener: (context, _) {
        unawaited(context.read<MonitorCubit>().syncFromRepository());
        context.read<LooperBloc>().add(const LooperSessionLoaded());
      },
      child: child,
    );
  }
}
