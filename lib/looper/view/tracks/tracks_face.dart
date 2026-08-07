import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';

/// The shape all three Tracks tabs share: one card of per-track rows, or the
/// empty card in their place, and the tab's footnote under it.
///
/// The footnote is not decoration. Every setting on this domain reaches beyond
/// the tray — a name shows on the stage and in the pedal targets, a length
/// only takes effect on the next defining take, a lane is what the Signal page
/// hangs its effects off — and a 70px list row has nowhere to say so.
///
/// The empty card is here rather than in each tab because the reason is the
/// same on all three: on Control and Loop a row is a global setting and there
/// is always one to draw, while here every row is a **track**, and a stopped
/// engine reports none. Without this, all three tabs rendered a 2px sliver.
class TracksFace extends StatelessWidget {
  /// Creates a [TracksFace].
  const TracksFace({required this.footnote, required this.rows, super.key});

  /// The sentence under the list.
  final String footnote;

  /// One entry per track, in channel order. Empty when the engine has no
  /// tracks — the empty card then takes the list's place.
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: kConsoleBlockGap),
          if (rows.isEmpty)
            ConsoleEmptyCard(
              key: const Key('tracks_empty_card'),
              message: l10n.tracksEmpty,
            )
          else
            ConsoleCard(children: rows),
          const SizedBox(height: kConsoleBlockGap),
          ConsoleProse(footnote),
        ],
      ),
    );
  }
}

/// Whether [a] and [b] route identically — same tracks, same lanes, same
/// input and output on each.
///
/// The Tracks faces cannot `context.select` the roster: a [Track] carries live
/// meters, so `state.tracks` changes at the meter rate, and a `List` compares
/// by identity anyway, so a projected list would never test equal either. Each
/// face therefore drives a `buildWhen` off an explicit comparison of the facts
/// it actually draws.
bool sameRouting(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final lanesA = a[i].lanes;
    final lanesB = b[i].lanes;
    if (lanesA.length != lanesB.length) return false;
    for (var lane = 0; lane < lanesA.length; lane++) {
      if (lanesA[lane].inputChannel != lanesB[lane].inputChannel) return false;
      if (lanesA[lane].outputMask != lanesB[lane].outputMask) return false;
    }
  }
  return true;
}

/// Whether [a] and [b] carry the same quantize overrides, track for track.
bool sameQuantize(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].quantizeOverride != b[i].quantizeOverride) return false;
  }
  return true;
}

/// Whether [a] and [b] carry the same length presets, track for track.
bool sameLengths(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].lengthPresetBars != b[i].lengthPresetBars) return false;
  }
  return true;
}
