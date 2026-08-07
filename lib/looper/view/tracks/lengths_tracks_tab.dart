import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/tracks_face.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// The Lengths tab: each track's defining-recording length — `auto`, or a
/// fixed number of bars.
///
/// The choice set is [SetupTrackLengthPresetRow.presets], the same list the
/// Settings page offers, and **not a second copy of the same numbers**: two
/// surfaces disagreeing about which lengths exist is a bug nobody finds until
/// a rig is set up on one surface and played from the other.
class LengthsTracksTab extends StatefulWidget {
  /// Creates a [LengthsTracksTab].
  const LengthsTracksTab({super.key});

  @override
  State<LengthsTracksTab> createState() => _LengthsTracksTabState();
}

class _LengthsTracksTabState extends State<LengthsTracksTab> {
  /// The channel whose chooser is open, or null. At most one, like every other
  /// console list.
  int? _open;

  void _toggle(int channel) =>
      setState(() => _open = _open == channel ? null : channel);

  /// What the row reads, and what its chosen chip reads: one function, so the
  /// readout and the grid can never disagree about what `0` is called.
  String _label(AppLocalizations l10n, int bars) =>
      bars <= 0 ? l10n.tracksLengthAuto : l10n.lengthPresetBars(bars);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;

    return KeyedSubtree(
      key: const Key('tracks_lengths_tab'),
      child: BlocBuilder<LooperBloc, LooperState>(
        buildWhen: (previous, current) =>
            !sameLengths(previous.tracks, current.tracks),
        builder: (context, state) {
          final tracks = state.tracks;
          return TracksFace(
            footnote: l10n.tracksLengthsFootnote,
            rows: [
              for (final (channel, track) in tracks.indexed)
                ..._row(context, l10n, names, channel, track, tracks.length),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _row(
    BuildContext context,
    AppLocalizations l10n,
    List<String> names,
    int channel,
    Track track,
    int count,
  ) {
    final open = _open == channel;
    return [
      ConsoleRow(
        key: Key('tracks_lengths_row_$channel'),
        title: l10n.trackName(names, channel),
        state: _label(l10n, track.lengthPresetBars),
        expanded: open,
        fill: open ? context.surface.control : null,
        // The open row hands its hairline to the drawer's own top rule; two
        // lines where the list has one reads as a gap in the card.
        showDivider: !open && channel < count - 1,
        onTap: () => _toggle(channel),
      ),
      ConsoleChooser.grid(
        key: Key('tracks_lengths_slot_$channel'),
        open: open,
        grid: ConsoleChipGrid<int>(
          selected: {track.lengthPresetBars},
          options: [
            for (final preset in SetupTrackLengthPresetRow.presets)
              ConsoleSegment(
                value: preset,
                label: _label(l10n, preset),
                optionKey: Key('tracks_lengths_${channel}_$preset'),
              ),
          ],
          // Pick-one: the tap answers the question, so it closes the chooser.
          onTap: (preset) {
            setState(() => _open = null);
            context.read<LooperBloc>().add(
              LooperTrackLengthPresetChanged(channel, preset),
            );
          },
        ),
      ),
    ];
  }
}
