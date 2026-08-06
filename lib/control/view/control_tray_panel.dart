import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/midi_tray_body.dart';
import 'package:segno/control/view/pedal_tray_body.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The Control domain: the footswitch plate and the MIDI foot controller as
/// two tabs of one rail entry.
///
/// **The title sits above the strip here**, where the Network face puts the
/// tabs first. That is the mockups' own distinction and it survives being
/// questioned: a Network tab carries a power switch and needs a title row to
/// hang it on, so its name arrives per tab. Neither Control tab carries a
/// per-tab control, so the domain says its name once, at the top.
///
/// Stateless: the selected tab lives in [SettingsTrayCubit], so leaving and
/// returning lands where it was left.
class ControlTrayPanel extends StatelessWidget {
  /// Creates a [ControlTrayPanel].
  const ControlTrayPanel({super.key});

  /// Gap under the title, and the gap the mockups put between the title row
  /// and the strip.
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tab = context.watch<SettingsTrayCubit>().state.controlTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('control_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.trayControlLabel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: _gap),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<ControlTab>(
              key: const Key('control_tabs'),
              selected: tab,
              onChanged: cubit.showControlTab,
              tabs: [
                PillTab(value: ControlTab.pedal, label: l10n.controlPedalTab),
                PillTab(value: ControlTab.midi, label: l10n.controlMidiTab),
              ],
            ),
          ),
          Expanded(
            child: switch (tab) {
              // Each body opens with its own leading gap: the mockups set the
              // Pedal tab on a flat 14 rhythm and the MIDI tab on a 19/9
              // grouping, and neither is this panel's to decide.
              ControlTab.pedal => const PedalTrayBody(),
              ControlTab.midi => const MidiTrayBody(),
            },
          ),
        ],
      ),
    );
  }
}
