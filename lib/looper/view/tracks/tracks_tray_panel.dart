import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/looper/view/tracks/lengths_tracks_tab.dart';
import 'package:segno/looper/view/tracks/names_tracks_tab.dart';
import 'package:segno/looper/view/tracks/routing_tracks_tab.dart';

/// The Tracks domain: what each track is called, how long it records, and
/// where it comes from and goes, as three tabs of one rail entry.
///
/// Same construction as Control and Loop — a title above a [PillTabs] strip,
/// no chrome bar, a Flutter-free tab enum the tray cubit can hold without
/// importing a view, and the selected tab kept across navigation in
/// `SettingsTrayState`.
///
/// What differs is what a ROW means. On Control and Loop a row is a global
/// setting; on all three tabs here a row is a **track**, and the same
/// engine-reported roster ([LooperBloc]) drives all three lists.
class TracksTrayPanel extends StatelessWidget {
  /// Creates a [TracksTrayPanel].
  const TracksTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.tracksTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('tracks_tray_panel'),
      child: ConsoleDomainPanel<TracksTab>(
        title: l10n.trayTracksLabel,
        tabsKey: const Key('tracks_tabs'),
        selected: tab,
        onChanged: cubit.showTracksTab,
        tabs: [
          PillTab(value: TracksTab.names, label: l10n.tracksNamesTab),
          PillTab(value: TracksTab.lengths, label: l10n.tracksLengthsTab),
          PillTab(value: TracksTab.routing, label: l10n.tracksRoutingTab),
        ],
        body: switch (tab) {
          TracksTab.names => const NamesTracksTab(),
          TracksTab.lengths => const LengthsTracksTab(),
          TracksTab.routing => const RoutingTracksTab(),
        },
      ),
    );
  }
}
