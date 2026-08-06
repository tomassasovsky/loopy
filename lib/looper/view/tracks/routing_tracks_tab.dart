import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/track_routing_sheet.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/theme/theme.dart';

/// Fallbacks for the channel counts while the engine is stopped, matching what
/// the Signal page assumes: a rig is at least a stereo pair out, and the four
/// inputs the console's own interface has.
const int kFallbackInputCount = 4;

/// See [kFallbackInputCount].
const int kFallbackOutputCount = 2;

/// The Routing tab of the console's Tracks domain, drawn to
/// `TRACKS / tracks-routing`: every track's input, outputs and quantize
/// override at a glance, each row opening the track's own sheet.
class RoutingTracksTab extends StatelessWidget {
  /// Creates a [RoutingTracksTab].
  const RoutingTracksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<LooperBloc>().state;
    final names = context.watch<TracksCubit>().state;
    final repository = context.read<LooperRepository>();
    final tracks = state.tracks;

    return KeyedSubtree(
      key: const Key('routing_tracks_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A stopped engine has no tracks to name, time or route, and an
            // empty card is a 2px sliver — say so instead.
            if (tracks.isEmpty)
              ConsoleEmptyCard(message: l10n.tracksEmptyMessage)
            else
              ConsoleCard(
              children: [
                for (final track in tracks)
                  ConsoleRow(
                    key: Key('track_routing_row_${track.channel}'),
                    divider: track != tracks.last,
                    title: l10n.trackName(names.names, track.channel),
                    subtitle: _sourceLine(
                      l10n,
                      track,
                      repository.trackQuantize(track.channel),
                    ),
                    value: _outputLine(l10n, _outputsOf(track)),
                    // An unrouted track is silent, which the muted tone of an
                    // ordinary value would not say.
                    valueColor: _outputsOf(track) == 0 ? surface.warning : null,
                    onTap: () => unawaited(_open(context, track.channel)),
                  ),
              ],
            ),
            TracksFooter(l10n.tracksRoutingFooter),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, int channel) =>
      showTrackRoutingSheet(context, channel: channel);

  /// `In 1 · In 2 · quantize on` — every input the track records (one lane
  /// each), plus its quantize override when it has one. A track following the
  /// global setting says nothing about quantize: the line is for what makes
  /// this track different.
  static String _sourceLine(
    AppLocalizations l10n,
    Track track,
    bool? quantize,
  ) {
    // The lanes, falling back to the lane-0 mirror for a stopped engine.
    final inputs = track.lanes.isEmpty
        ? [
            if (maskToInputChannel(track.inputMask) >= 0)
              maskToInputChannel(track.inputMask),
          ]
        : [
            for (final lane in track.lanes)
              if (lane.inputChannel >= 0) lane.inputChannel,
          ];
    final source = inputs.isEmpty
        ? l10n.signalInputNone
        : inputs.map((i) => l10n.inputChannelLabel(i + 1)).join(' · ');
    return switch (quantize) {
      null => source,
      true => '$source · ${l10n.trackQuantizeOn}',
      false => '$source · ${l10n.trackQuantizeOff}',
    };
  }

  /// Everywhere the track can be heard: the union of its lanes' outputs, so
  /// a track whose second lane goes to the desk does not read as if only the
  /// first lane's routing existed.
  static int _outputsOf(Track track) {
    if (track.lanes.isEmpty) return track.outputMask;
    return track.lanes.fold(0, (mask, lane) => mask | lane.outputMask);
  }

  /// `Out 1 · Out 2`, or the warning word when the track goes nowhere.
  static String _outputLine(AppLocalizations l10n, int mask) {
    final outputs = [
      for (var i = 0; i < 32; i++)
        if (mask & (1 << i) != 0) l10n.outputChannelLabel(i + 1),
    ];
    return outputs.isEmpty ? l10n.trackRoutingSummaryNone : outputs.join(' · ');
  }
}
