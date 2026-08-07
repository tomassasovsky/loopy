import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/view/loop/click_loop_tab.dart';
import 'package:segno/looper/view/loop/mode_loop_tab.dart';
import 'package:segno/looper/view/loop/tempo_loop_tab.dart';
import 'package:segno/theme/theme.dart';

/// The Loop domain: the tempo grid, the click and the looper mode as three
/// tabs of one rail entry.
///
/// **The title sits above the strip**, as it does on Control and for the same
/// reason: no Loop tab carries a per-tab control that a title row would have
/// to hang on, so the domain says its name once, at the top.
///
/// **Presentation, not new state.** Every value on these faces is already
/// owned by something — [LooperBloc]'s `TransportState` for what the rig is
/// running, `TempoCubit` / `RecordOptionsCubit` / `ControlCubit` for writing
/// it. Nothing below the view layer changes for this domain to exist.
///
/// Stateless: the selected tab lives in [SettingsTrayCubit], so leaving and
/// returning lands where it was left.
class LoopTrayPanel extends StatelessWidget {
  /// Creates a [LoopTrayPanel].
  const LoopTrayPanel({super.key});

  /// Gap between the title and the strip, as the mockups set it.
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tab = context.watch<SettingsTrayCubit>().state.loopTab;
    final cubit = context.read<SettingsTrayCubit>();

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
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: _gap),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<LoopTab>(
              key: const Key('loop_tabs'),
              selected: tab,
              onChanged: cubit.showLoopTab,
              tabs: [
                PillTab(value: LoopTab.tempo, label: l10n.loopTempoTab),
                PillTab(value: LoopTab.click, label: l10n.loopClickTab),
                PillTab(value: LoopTab.mode, label: l10n.loopModeTab),
              ],
            ),
          ),
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
