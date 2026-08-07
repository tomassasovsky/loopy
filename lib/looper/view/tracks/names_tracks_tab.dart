import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/tracks_face.dart';

/// The Names tab: what each track is called.
///
/// **The roster is the engine's, the names are the app's.** The rows come from
/// `LooperBloc.state.tracks` rather than a fixed count, so a rig with a
/// different track count does not get rows for tracks it has not got, while
/// [TracksCubit] owns and persists the names on top of that roster.
///
/// Every track, not the showing bank: naming is setup, not performance, and a
/// list that followed the pedal's A/B bank would hide half the rig from the
/// one face whose job is to name all of it.
class NamesTracksTab extends StatelessWidget {
  /// Creates a [NamesTracksTab].
  const NamesTracksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = context.select<LooperBloc, int>(
      (bloc) => bloc.state.tracks.length,
    );
    final names = context.watch<TracksCubit>().state.names;
    final cubit = context.read<TracksCubit>();

    return KeyedSubtree(
      key: const Key('tracks_names_tab'),
      child: TracksFace(
        footnote: l10n.tracksNamesFootnote,
        rows: [
          for (var channel = 0; channel < count; channel++)
            ConsoleRow(
              key: Key('tracks_names_row_$channel'),
              title: l10n.trackName(names, channel),
              state: l10n.tracksOrdinal(channel + 1),
              expanded: false,
              showDivider: channel < count - 1,
              onTap: () async {
                final name = await showConsoleRenameSheet(
                  context,
                  title: l10n.tracksRenameSheetTitle,
                  subtitle: l10n.tracksOrdinal(channel + 1),
                  current: l10n.trackName(names, channel),
                  fieldLabel: l10n.a11yTracksRenameField,
                );
                if (name != null) await cubit.rename(channel, name);
              },
            ),
        ],
      ),
    );
  }
}
