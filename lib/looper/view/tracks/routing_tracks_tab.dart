import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/track_routing_dialog.dart';
import 'package:segno/looper/view/tracks/tracks_face.dart';
import 'package:segno/theme/theme.dart';

/// The Routing tab: every track's inputs, outputs and quantize override at a
/// glance, each row opening that track's own panel.
///
/// The readouts speak in **lanes**, never in "the track's input". A track
/// records any set of inputs — one dry lane each, sharing the track's
/// transport and loop — so the subtitle lists what all its lanes record and
/// the trailing readout is the **union** of what they reach. A track whose
/// second lane goes somewhere else must not read as if only the first existed.
class RoutingTracksTab extends StatefulWidget {
  /// Creates a [RoutingTracksTab].
  const RoutingTracksTab({super.key});

  @override
  State<RoutingTracksTab> createState() => _RoutingTracksTabState();
}

class _RoutingTracksTabState extends State<RoutingTracksTab> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final repository = context.read<LooperRepository>();

    return KeyedSubtree(
      key: const Key('tracks_routing_tab'),
      child: BlocBuilder<LooperBloc, LooperState>(
        buildWhen: (previous, current) =>
            !sameRouting(previous.tracks, current.tracks),
        builder: (context, state) {
          final tracks = state.tracks;
          return TracksFace(
            footnote: l10n.tracksRoutingFootnote,
            rows: [
              for (final (channel, track) in tracks.indexed)
                _row(context, l10n, names, repository, channel, track, tracks),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    List<String> names,
    LooperRepository repository,
    int channel,
    Track track,
    List<Track> tracks,
  ) {
    final surface = context.surface;
    final outputs = trackOutputMask(track);
    final routed = outputs != 0;
    return ConsoleRow(
      key: Key('tracks_routing_row_$channel'),
      title: l10n.trackName(names, channel),
      subtitle: _subtitle(l10n, repository, channel, track),
      state: routed
          ? outputMaskLabel(l10n, outputs)
          // A track no lane of which reaches an output records and is never
          // heard. Said in the warning tone, because the muted grey of a
          // normal readout would state a different and wrong fact.
          : l10n.tracksNotRouted,
      valueColor: routed ? null : surface.warning,
      expanded: false,
      showDivider: channel < tracks.length - 1,
      onTap: () async {
        await showTrackRoutingDialog(context, channel: channel);
        // The quantize override is not in the engine snapshot, so no bloc
        // state change announces it — the summary has to be asked again once
        // the panel that could have changed it is gone.
        if (mounted) setState(() {});
      },
    );
  }

  /// `In 1 · In 2 · quantize on` — what the track records, then its override
  /// on the global quantize setting when it has one.
  String _subtitle(
    AppLocalizations l10n,
    LooperRepository repository,
    int channel,
    Track track,
  ) {
    final inputs = recordedInputs(track);
    final override = repository.trackQuantize(channel);
    return [
      if (inputs.isEmpty)
        l10n.tracksNoInputs
      else
        for (final input in inputs) l10n.inputChannelLabel(input + 1),
      if (override != null)
        override ? l10n.tracksQuantizeOn : l10n.tracksQuantizeOff,
    ].join(' · ');
  }
}

/// Which hardware inputs [track] records, ascending and de-duplicated.
///
/// Ascending rather than in lane order: this is a summary of the SET of
/// inputs, and lane order is an implementation fact the panel itself shows.
List<int> recordedInputs(Track track) => {
  for (final lane in track.lanes)
    if (lane.inputChannel >= 0) lane.inputChannel,
}.toList()..sort();

/// Every output any lane of [track] reaches.
int trackOutputMask(Track track) =>
    track.lanes.fold(0, (mask, lane) => mask | lane.outputMask);

/// `Out 1 · Out 2` for [mask].
String outputMaskLabel(AppLocalizations l10n, int mask) => [
  for (var out = 0; out < 32; out++)
    if (mask & (1 << out) != 0) l10n.outputChannelLabel(out + 1),
].join(' · ');
