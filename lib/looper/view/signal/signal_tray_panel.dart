import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart' show FxStage;
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/signal/signal_cards.dart';

/// The Signal domain: the four FX stages of the signal path as four tabs of
/// one rail entry.
///
/// **The tabs are [FxStage] itself.** `fx_address.dart` has declared
/// `input · loop · track · master` since the v3 FX model landed, and the
/// mockups draw four tabs with those four labels in that order. They are the
/// same four things, so this domain is the only one of the seven with no tab
/// enum of its own — a parallel enum would be a second name for one concept,
/// and the one free to drift.
///
/// **This face replaces a full-screen route, not a settings group.** Signal
/// was the last surface the rail deliberately did not carry: a tile on the
/// home face that pushed `lib/looper/view/signal_graph/`'s three-pane layout
/// away from the stage. The tile is gone as of this PR and the surface itself
/// goes with the last of the slice, which is why the rail no longer documents
/// a route-pushing exception.
///
/// Stateless: the selected stage lives in [SettingsTrayCubit], so leaving and
/// returning to the domain lands where it was left.
class SignalTrayPanel extends StatelessWidget {
  /// Creates a [SignalTrayPanel].
  const SignalTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.signalTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('signal_tray_panel'),
      child: ConsoleDomainPanel<FxStage>(
        title: l10n.traySignalLabel,
        tabsKey: const Key('signal_tabs'),
        selected: tab,
        onChanged: cubit.showSignalTab,
        // Lower case, as the mockups set the whole strip — these are stages of
        // a path rather than names of things, and the rail above already says
        // the domain's name in title case.
        tabs: [
          PillTab(value: FxStage.input, label: l10n.signalStageInput),
          PillTab(value: FxStage.loop, label: l10n.signalStageLoop),
          PillTab(value: FxStage.track, label: l10n.signalStageTrack),
          PillTab(value: FxStage.master, label: l10n.signalStageMaster),
        ],
        // One body for four tabs, keyed by stage: what a card *is* changes
        // with the stage, and the six questions it answers do not.
        body: SignalStageBody(key: ValueKey(tab), stage: tab),
      ),
    );
  }
}
