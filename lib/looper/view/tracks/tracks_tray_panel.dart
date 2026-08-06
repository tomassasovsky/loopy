import 'package:flutter/material.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/tracks/lengths_tracks_tab.dart';
import 'package:segno/looper/view/tracks/names_tracks_tab.dart';
import 'package:segno/looper/view/tracks/routing_tracks_tab.dart';
import 'package:segno/theme/theme.dart';

/// In-tray Tracks face: what the tracks are called, how long they run and
/// where their audio comes from and goes, as three tabs of one rail
/// destination — drawn to `TRACKS / tracks`, `tracks-lengths` and
/// `tracks-routing`.
///
/// Named above its tab strip like the Control and Loop faces: none of the
/// three tabs carries a control of its own that would need a title row.
class TracksTrayPanel extends StatelessWidget {
  /// Creates a [TracksTrayPanel].
  const TracksTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final TracksTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<TracksTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return KeyedSubtree(
      key: const Key('tracks_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.trayTracksLabel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<TracksTab>(
              key: const Key('tracks_tabs'),
              selected: tab,
              onChanged: onTabChanged,
              tabs: [
                PillTab(value: TracksTab.names, label: l10n.tracksNamesTab),
                PillTab(value: TracksTab.lengths, label: l10n.tracksLengthsTab),
                PillTab(value: TracksTab.routing, label: l10n.tracksRoutingTab),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (tab) {
              TracksTab.names => const NamesTracksTab(),
              TracksTab.lengths => const LengthsTracksTab(),
              TracksTab.routing => const RoutingTracksTab(),
            },
          ),
        ],
      ),
    );
  }
}

/// The footnote under a Tracks list, in the mockups' muted tone.
///
/// Every Tracks tab carries one: these settings all reach beyond the tray
/// (a name shows on the stage, a length only takes effect on the next
/// defining take), and the list rows have nowhere to say so.
class TracksFooter extends StatelessWidget {
  /// Creates a [TracksFooter].
  const TracksFooter(this.text, {super.key});

  /// The note.
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Text(
      text,
      style: TextStyle(color: context.surface.textMuted, fontSize: 14),
    ),
  );
}
