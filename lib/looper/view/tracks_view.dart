import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/view/track_column.dart';
import 'package:loopy/looper/view/tracks_chrome.dart';
import 'package:loopy/looper/view/tracks_commands.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';

/// The full-screen Tracks view (Chewie-Monsta style): a row
/// of tall colored track columns, each a level meter with an editable name.
/// Tapping a column selects it (white highlight) and toggles record/overdub;
/// long-press stops. The master output waveform is in a separate window.
///
/// The chrome ([TracksToolbar], [AudioNotRunningBanner]) and each
/// [TrackColumn] are their own widgets; the tracks keyboard map and the
/// shared dispatch/announce helpers live in [TracksCommands]. This view is
/// just the layout that wires them together.
class TracksView extends StatefulWidget {
  /// Creates a [TracksView].
  const TracksView({super.key});

  @override
  State<TracksView> createState() => _TracksViewState();
}

class _TracksViewState extends State<TracksView> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LooperBloc>().state;
    final tracksState = context.watch<TracksCubit>().state;
    // Mode / cursor / bank are the shared control overlay — the single owner
    // every surface (keyboard, tiles, pedal) reads and writes.
    final overlay = context.watch<ControlOverlayCubit>().state;
    final mode = overlay.mode;
    final commands = TracksCommands(context);
    final tracks = [
      for (final track in state.tracks)
        if (overlay.bankContains(track.channel)) track,
    ];
    final anyActive = commands.anyActive(state);
    // Both global transport buttons are no-ops with no recorded audio or a
    // stopped engine; disabling them avoids dead-feeling controls.
    final transportEnabled = state.status.isConnected && state.hasContent;
    // The Play direction is additionally blocked when nothing would sound —
    // every loaded track is muted (or none holds a loop). Stopping stays
    // available whenever something is active.
    final playStopEnabled = anyActive
        ? transportEnabled
        : state.status.isConnected && commands.anyPlayable(state);

    // Settings are reachable from the Tracks view by right-clicking
    // anywhere or pressing `S` (and from the macOS menu bar). Kept chromeless
    // and minimal otherwise.
    return LooperScreenTheme(
      child: BlocListener<SessionCubit, SessionState>(
        // Only react to a settled action — a save/load/export that finished or
        // failed — never the transient `working` tick.
        listenWhen: (previous, current) =>
            current.status != previous.status &&
            (current.status == SessionStatus.success ||
                current.status == SessionStatus.failure),
        listener: showSessionOutcome,
        child: Focus(
          autofocus: true,
          onKeyEvent: commands.handleKey,
          child: GestureDetector(
            key: const Key('tracks_settings_secondaryTap'),
            behavior: HitTestBehavior.translucent,
            onSecondaryTapUp: (_) => unawaited(openLoopySettings()),
            child: Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TracksToolbar(
                        mode: mode,
                        activeBank: overlay.activeBank,
                        anyActive: anyActive,
                        playStopEnabled: playStopEnabled,
                        transportEnabled: transportEnabled,
                        onToggleMode: commands.toggleMode,
                        onPlayStopAll: () =>
                            commands.togglePlayAll(playing: anyActive),
                        onClearAll: commands.clearAll,
                      ),
                      const SizedBox(height: 14),
                      // With no first-run gate, a stopped engine lands here; a
                      // full-width affordance opens settings to (re)start it.
                      if (!state.status.isConnected) ...[
                        const AudioNotRunningBanner(),
                        const SizedBox(height: 14),
                      ],
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final track in tracks)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: TrackColumn(
                                      track: track,
                                      name: l10n.displayTrackName(
                                        tracksState.nameOf(track.channel),
                                        track.channel,
                                      ),
                                      selected: track.channel == overlay.cursor,
                                      mode: mode,
                                      onUndo: commands.undo,
                                      onRedo: commands.redo,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
