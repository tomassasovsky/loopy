import 'package:flutter/material.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/view/loop/click_loop_tab.dart';
import 'package:segno/looper/view/loop/mode_loop_tab.dart';
import 'package:segno/looper/view/loop/tempo_loop_tab.dart';
import 'package:segno/theme/theme.dart';

/// In-tray Loop face: everything that governs the loop grid, as three tabs of
/// one rail destination, drawn to `LOOP / loop`, `loop-click` and `loop-mode`.
///
/// Named above its tab strip like the Control face, and for the same reason:
/// neither carries a per-tab control that would need a title row of its own.
class LoopTrayPanel extends StatelessWidget {
  /// Creates a [LoopTrayPanel].
  const LoopTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final LoopTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<LoopTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return KeyedSubtree(
      key: const Key('loop_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.trayLoopLabel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<LoopTab>(
              key: const Key('loop_tabs'),
              selected: tab,
              onChanged: onTabChanged,
              tabs: [
                PillTab(value: LoopTab.tempo, label: l10n.loopTempoTab),
                PillTab(value: LoopTab.click, label: l10n.loopClickTab),
                PillTab(value: LoopTab.mode, label: l10n.loopModeTab),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (tab) {
              LoopTab.tempo => const TempoLoopTab(),
              LoopTab.click => const ClickLoopTab(),
              LoopTab.mode => const ModeLoopTab(),
            },
          ),
        ],
      ),
    );
  }
}
