import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/track_rename_sheet.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';

/// The Names tab of the console's Tracks domain, drawn to `TRACKS / tracks`:
/// one row per track, its name on the left and which track it is on the
/// right.
///
/// The name is app state, not engine state — [TracksCubit] owns it and
/// persists it — but the ROSTER is the engine's: the rows follow the tracks
/// the rig actually has, so a rig with a different track count does not get a
/// list of names for tracks it hasn't got.
class NamesTracksTab extends StatelessWidget {
  /// Creates a [NamesTracksTab].
  const NamesTracksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tracks = context.watch<LooperBloc>().state.tracks;
    final names = context.watch<TracksCubit>().state;

    return KeyedSubtree(
      key: const Key('names_tracks_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleCard(
              children: [
                for (final track in tracks)
                  ConsoleRow(
                    key: Key('track_name_row_${track.channel}'),
                    divider: track != tracks.last,
                    title: l10n.trackName(names.names, track.channel),
                    value: l10n.tracksRowOrdinal(track.channel + 1),
                    onTap: () => unawaited(
                      _rename(
                        context,
                        track.channel,
                        names.nameOf(
                          track.channel,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            TracksFooter(l10n.tracksNamesFooter),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    int channel,
    String current,
  ) async {
    final cubit = context.read<TracksCubit>();
    final name = await showTrackRenameSheet(context, initial: current);
    if (name == null) return;
    await cubit.rename(channel, name);
  }
}
