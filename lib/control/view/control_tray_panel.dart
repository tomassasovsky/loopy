import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/midi_tray_body.dart';
import 'package:segno/control/view/pedal_tray_body.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';

/// The Control domain: the footswitch plate and the MIDI foot controller as
/// two tabs of one rail entry.
///
/// Stateless: the selected tab lives in [SettingsTrayCubit], so leaving and
/// returning lands where it was left.
class ControlTrayPanel extends StatelessWidget {
  /// Creates a [ControlTrayPanel].
  const ControlTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.controlTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('control_tray_panel'),
      child: ConsoleDomainPanel<ControlTab>(
        title: l10n.trayControlLabel,
        tabsKey: const Key('control_tabs'),
        selected: tab,
        onChanged: cubit.showControlTab,
        tabs: [
          PillTab(value: ControlTab.pedal, label: l10n.controlPedalTab),
          PillTab(value: ControlTab.midi, label: l10n.controlMidiTab),
        ],
        // Each body opens with its own leading gap: the mockups set the Pedal
        // tab on a flat 14 rhythm and the MIDI tab on a 19/9 grouping, and
        // neither is this panel's to decide.
        body: switch (tab) {
          ControlTab.pedal => const PedalTrayBody(),
          ControlTab.midi => const MidiTrayBody(),
        },
      ),
    );
  }
}
