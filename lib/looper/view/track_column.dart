import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/looper/view/track_meters.dart';
import 'package:loopy/theme/theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// One tall track column in the Tracks view: a header (channel number,
/// loop-multiple badge, and undo/redo on the selected column), a tappable level
/// meter (record/overdub in record mode, mute/unmute in play mode; long-press
/// stops), an editable name, and an optional readiness indicator strip.
class TrackColumn extends StatelessWidget {
  /// Creates a [TrackColumn].
  const TrackColumn({
    required this.track,
    required this.name,
    required this.selected,
    required this.mode,
    required this.onUndo,
    required this.onRedo,
    super.key,
  });

  /// The track this column renders.
  final Track track;

  /// The track's resolved display name.
  final String name;

  /// Whether this column is the selected one (a heavier white border).
  final bool selected;

  /// The active system mode (Record vs Play).
  final LooperMode mode;

  /// Dispatches an undo for the given channel (shares the keyboard path's
  /// dispatch+announce, wired in the host view).
  final void Function(int channel) onUndo;

  /// Dispatches a redo for the given channel.
  final void Function(int channel) onRedo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final bloc = context.read<LooperBloc>();

    // The border is always white; selection only changes its weight. The meter
    // bar color is one table lookup on the track's meter state (muted included;
    // see LooperTheme.meterColors).
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final playMode = mode == LooperMode.play;
    final barColor = looper.meterColor(meterState, mode: mode);
    // Undo/Redo shortcut hints adapt to the host platform — Loopy targets
    // Windows/Linux too, so this must not hardcode the macOS modifier.
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final undoShortcut = isMac ? '⌘Z' : 'Ctrl+Z';
    final redoShortcut = isMac ? '⌘⇧Z' : 'Ctrl+Y';
    // The meter conveys state through colour only (WCAG 1.4.1); name the state
    // in words so it reaches the tile's accessible label.
    final stateWord = switch (meterState) {
      LooperMeterState.empty => l10n.trackStateEmpty,
      LooperMeterState.recording => l10n.trackStateRecording,
      LooperMeterState.overdubbing => l10n.trackStateOverdubbing,
      LooperMeterState.playing => l10n.trackStatePlaying,
      LooperMeterState.stopped => l10n.trackStateStopped,
      LooperMeterState.muted => l10n.trackStateMuted,
    };

    return Container(
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: 3,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${track.channel + 1}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const Spacer(),
              if (track.isMultiple)
                Text(
                  l10n.loopMultipleLabel(track.multiple),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              // Undo/Redo surface only on the selected column; the keyboard
              // shortcut hint in each tooltip adapts to the host platform.
              if (selected) ...[
                IconButton(
                  key: Key('tracks_undo_${track.channel}'),
                  tooltip: l10n.undoTooltip(undoShortcut),
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: Colors.white70,
                  icon: const Icon(Icons.undo),
                  // Mirrors the `U` key: enabled whenever the track holds
                  // content, since undo also clears a lone base loop.
                  onPressed: track.hasContent
                      ? () => onUndo(track.channel)
                      : null,
                ),
                IconButton(
                  key: Key('tracks_redo_${track.channel}'),
                  tooltip: l10n.redoTooltip(redoShortcut),
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: Colors.white70,
                  icon: const Icon(Icons.redo),
                  onPressed: track.canRedo ? () => onRedo(track.channel) : null,
                ),
              ],
            ],
          ),
          Expanded(
            child: FocusableTapTarget(
              key: Key('tracks_tile_${track.channel}'),
              // The tap action follows the mode (mirroring the 1–8 number
              // keys): record/overdub in record mode, mute/unmute in play mode.
              semanticLabel: playMode
                  ? l10n.a11yTrackTilePlay(name, stateWord)
                  : l10n.a11yTrackTile(name, stateWord),
              selected: selected,
              borderRadius: 8,
              onTap: () {
                context.read<TracksCubit>().select(track.channel);
                bloc.add(
                  playMode
                      ? LooperMuteToggled(track.channel)
                      : LooperRecordPressed(track.channel),
                );
              },
              child: GestureDetector(
                key: Key('tracks_tileStop_${track.channel}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
                child: PeakMeterBar(
                  peak: track.peak,
                  color: barColor,
                  hasContent: track.hasContent,
                  // A stopped track reports no live peak; hold the last fill so
                  // a loaded-but-paused loop keeps a visible bar after a stop.
                  frozen: track.state == TrackState.stopped,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          FocusableTapTarget(
            key: Key('tracks_name_${track.channel}'),
            semanticLabel: l10n.a11yRenameTrack(name),
            onTap: () => showRenameTrackDialog(
              context: context,
              cubit: context.read<TracksCubit>(),
              channel: track.channel,
              current: name,
            ),
            child: Text(
              name,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
          // A discrete arm/readiness strip, shown only when the view preference
          // is on. When off the widget is absent and the tile reflows.
          if (context.select<TracksCubit, bool>(
            (c) => c.state.showIndicators,
          )) ...[
            const SizedBox(height: 6),
            _TrackIndicator(
              key: Key('tracks_indicator_${track.channel}'),
              status: TrackIndicator.of(
                track.state,
                muted: track.muted,
                hasContent: track.hasContent,
                selected: selected,
                mode: mode,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A static, full-width status strip below a track name. Its colour is the
/// track's [TrackIndicator] state. Carries no semantics of its own
/// ([ExcludeSemantics]): the tile already names its state for screen readers,
/// so a second label here would double-announce. Static colour ⇒ no motion.
class _TrackIndicator extends StatelessWidget {
  const _TrackIndicator({required this.status, super.key});

  final TrackIndicator status;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: looper.indicatorColor(status),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const SizedBox(height: 5, width: double.infinity),
      ),
    );
  }
}
