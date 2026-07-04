import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/theme/theme.dart';

/// A chromeless row of the active-bank track level meters — the bars-only
/// tracks surface embedded in the on-screen pedal's screen.
///
/// Read-only: it shows the four meters (colour = track state, height = level,
/// white border = the selected track) with no controls, since the pedal
/// supplies every action. Watches the same blocs as the full `TracksView`.
class TrackMeterRow extends StatelessWidget {
  /// Creates a [TrackMeterRow].
  const TrackMeterRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = Theme.of(context).extension<LooperTheme>()!;

    final tracks = context.watch<LooperBloc>().state.tracks;
    final names = context.watch<TracksCubit>().state;
    // Mode / cursor / bank are the shared control overlay — this row sits on
    // the pedal's own screen, so it follows exactly what the footswitch sets.
    final overlay = context.watch<ControlOverlayCubit>().state;
    final mode = overlay.mode;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final track in tracks)
          if (overlay.bankContains(track.channel))
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _TrackMeter(
                  track: track,
                  looper: looper,
                  mode: mode,
                  selected: track.channel == overlay.cursor,
                  name: l10n.displayTrackName(
                    names.nameOf(track.channel),
                    track.channel,
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// One track's meter tile: a state-coloured [PeakMeterBar] in a rounded panel,
/// its border white while the track is the selected one.
class _TrackMeter extends StatelessWidget {
  const _TrackMeter({
    required this.track,
    required this.looper,
    required this.mode,
    required this.selected,
    required this.name,
  });

  final Track track;
  final LooperTheme looper;
  final LooperMode mode;
  final bool selected;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meterState = LooperMeterState.of(track.state, muted: track.muted);

    return Container(
      key: Key('pedalScreen_bar_${track.channel}'),
      decoration: BoxDecoration(
        color: looper.tileBackground,
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${track.channel + 1}',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: PeakMeterBar(
              peak: track.peak,
              color: looper.meterColor(meterState, mode: mode),
              hasContent: track.hasContent,
              // A stopped track reports no live peak; hold the last fill so a
              // loaded-but-paused loop keeps a visible bar after a stop.
              frozen: track.state == TrackState.stopped,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            key: Key('pedalScreen_name_${track.channel}'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A bottom-anchored level meter driven by the track's current [peak]. Updates
/// with the watched looper state — no own timer.
///
/// When [frozen] (the track is stopped), the bar holds the last live fill
/// instead of collapsing to the stopped track's zero peak, so a loaded-but-
/// paused loop keeps a visible level after a stop.
class PeakMeterBar extends StatefulWidget {
  /// Creates a [PeakMeterBar].
  const PeakMeterBar({
    required this.peak,
    required this.color,
    required this.hasContent,
    required this.frozen,
    super.key,
  });

  /// The track's current peak level (`0..1`).
  final double peak;

  /// The bar fill colour (the track's meter-state colour).
  final Color color;

  /// Whether the track holds recorded audio (an empty track shows no bar).
  final bool hasContent;

  /// Whether the track is stopped, so the last live fill is held.
  final bool frozen;

  @override
  State<PeakMeterBar> createState() => _PeakMeterBarState();
}

class _PeakMeterBarState extends State<PeakMeterBar> {
  /// The last fill rendered while the track had a live level, held across the
  /// stopped (frozen) phase. Recomputed every live tick; reset when emptied.
  double _fill = 0;

  @override
  Widget build(BuildContext context) {
    // A track with nothing recorded has no bar; a live track tracks its peak;
    // a frozen (stopped) track keeps the last live fill.
    if (!widget.hasContent) {
      _fill = 0;
    } else if (!widget.frozen) {
      _fill = peakMeterFill(widget.peak);
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: _fill,
        child: Container(color: widget.color),
      ),
    );
  }
}
