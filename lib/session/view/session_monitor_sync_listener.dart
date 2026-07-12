import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/session/cubit/session_cubit.dart';

/// Bridges a session load back to the [MonitorCubit].
///
/// A session load applies its per-input monitors straight to the engine through
/// the looper repository, past the [MonitorCubit] — which owns the on-screen
/// FX-dock monitor state AND persists the monitor settings. Without this bridge
/// the dock would keep showing the PREVIOUS session's monitors and re-apply
/// them on the next edit, and the persisted settings would drift from the
/// loaded session (a wrong boot restore).
///
/// Placed in the widget tree (not as a cubit-to-cubit subscription) because
/// [SessionCubit] composes repositories, not cubits. Only a
/// [SessionOutcome.loaded] outcome touches monitors — save / rename / delete
/// emit other outcomes and must not re-sync. Every session action first emits a
/// `working` state that nulls `outcome`, so the guard fires once per load.
class SessionMonitorSyncListener extends StatelessWidget {
  /// Creates a [SessionMonitorSyncListener] wrapping [child].
  const SessionMonitorSyncListener({required this.child, super.key});

  /// The subtree rendered beneath the listener.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) =>
          current.status == SessionStatus.success &&
          current.outcome == SessionOutcome.loaded,
      listener: (context, _) =>
          unawaited(context.read<MonitorCubit>().syncFromRepository()),
      child: child,
    );
  }
}
