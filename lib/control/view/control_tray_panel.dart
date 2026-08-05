import 'package:flutter/material.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/midi_control_tab.dart';
import 'package:segno/control/view/pedal_control_tab.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// In-tray Control face: the footswitches and external MIDI as two tabs of one
/// rail destination, drawn to `CONTROL / control` and `control-midi`.
///
/// Unlike the Network face, this one names itself above the tab strip. That is
/// the mockups' own distinction and it holds up: a Network tab carries a power
/// switch and so needs a title row of its own to hang it on, while these two
/// carry no per-tab control — so the domain says its name once, at the top,
/// and the tabs sit under it.
class ControlTrayPanel extends StatelessWidget {
  /// Creates a [ControlTrayPanel].
  const ControlTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final ControlTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<ControlTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

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
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<ControlTab>(
              key: const Key('control_tabs'),
              selected: tab,
              onChanged: onTabChanged,
              tabs: [
                PillTab(value: ControlTab.pedal, label: l10n.controlPedalTab),
                PillTab(value: ControlTab.midi, label: l10n.controlMidiTab),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (tab) {
              ControlTab.pedal => const PedalControlTab(),
              ControlTab.midi => const MidiControlTab(),
            },
          ),
        ],
      ),
    );
  }
}
