import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/setup/setup_surface.dart' show SetupTrackLengthPresetRow;

/// The Lengths tab of the console's Tracks domain, drawn to
/// `TRACKS / tracks-lengths`: each track's loop length, as `Auto` or a bar
/// count.
///
/// The choice set is [SetupTrackLengthPresetRow.presets] rather than a second
/// list of the same numbers — Settings offers this control too, and two
/// surfaces disagreeing about which lengths exist would be a bug nobody sees
/// until a rig is set up on one and played from the other.
class LengthsTracksTab extends StatelessWidget {
  /// Creates a [LengthsTracksTab].
  const LengthsTracksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tracks = context.watch<LooperBloc>().state.tracks;
    final names = context.watch<TracksCubit>().state;

    return KeyedSubtree(
      key: const Key('lengths_tracks_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleCard(
              children: [
                for (final track in tracks)
                  ConsoleRow(
                    key: Key('track_length_row_${track.channel}'),
                    divider: track != tracks.last,
                    title: l10n.trackName(names.names, track.channel),
                    value: _label(l10n, track.lengthPresetBars),
                    onTap: () => unawaited(
                      _pick(context, track.channel, track.lengthPresetBars),
                    ),
                  ),
              ],
            ),
            TracksFooter(l10n.tracksLengthsFooter),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, int channel, int current) async {
    final l10n = context.l10n;
    final bloc = context.read<LooperBloc>();
    final chosen = await showConsolePickerSheet<int>(
      context,
      title: l10n.loopLength,
      selected: current,
      options: [
        for (final bars in SetupTrackLengthPresetRow.presets)
          ConsolePickerOption(value: bars, label: _label(l10n, bars)),
      ],
    );
    if (chosen == null || chosen == current) return;
    bloc.add(LooperTrackLengthPresetChanged(channel, chosen));
  }

  String _label(AppLocalizations l10n, int bars) =>
      bars == 0 ? l10n.auto : l10n.loopBarsValue(bars);
}
