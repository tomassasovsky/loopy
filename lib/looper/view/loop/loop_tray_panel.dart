import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/view/loop/click_loop_tab.dart';
import 'package:segno/looper/view/loop/mode_loop_tab.dart';
import 'package:segno/looper/view/loop/tempo_loop_tab.dart';

/// The Loop domain: the tempo grid, the click and the looper mode as three
/// tabs of one rail entry.
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.loopTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('loop_tray_panel'),
      child: ConsoleDomainPanel<LoopTab>(
        title: l10n.trayLoopLabel,
        tabsKey: const Key('loop_tabs'),
        selected: tab,
        onChanged: cubit.showLoopTab,
        tabs: [
          PillTab(value: LoopTab.tempo, label: l10n.loopTempoTab),
          PillTab(value: LoopTab.click, label: l10n.loopClickTab),
          PillTab(value: LoopTab.mode, label: l10n.loopModeTab),
        ],
        body: switch (tab) {
          LoopTab.tempo => const TempoLoopTab(),
          LoopTab.click => const ClickLoopTab(),
          LoopTab.mode => const ModeLoopTab(),
        },
      ),
    );
  }
}
