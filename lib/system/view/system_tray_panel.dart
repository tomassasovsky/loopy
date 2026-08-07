import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/system/system_tab.dart';
import 'package:segno/system/view/about_system_tab.dart';
import 'package:segno/system/view/display_system_tab.dart';
import 'package:segno/system/view/storage_system_tab.dart';
import 'package:segno/system/view/updates_system_tab.dart';

/// The System domain: the console talking about itself, as four tabs of one
/// rail entry.
///
/// Same construction as Control, Loop, Tracks and Audio — a title above a
/// [PillTabs] strip, no chrome bar, a Flutter-free tab enum the tray cubit can
/// hold without importing a view, and the selected tab kept across navigation
/// in `SettingsTrayState`.
class SystemTrayPanel extends StatelessWidget {
  /// Creates a [SystemTrayPanel].
  const SystemTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.systemTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('system_tray_panel'),
      child: ConsoleDomainPanel<SystemTab>(
        title: l10n.traySystemLabel,
        tabsKey: const Key('system_tabs'),
        selected: tab,
        onChanged: cubit.showSystemTab,
        tabs: [
          PillTab(value: SystemTab.display, label: l10n.systemDisplayTab),
          PillTab(value: SystemTab.updates, label: l10n.systemUpdatesTab),
          PillTab(value: SystemTab.storage, label: l10n.systemStorageTab),
          PillTab(value: SystemTab.about, label: l10n.systemAboutTab),
        ],
        body: switch (tab) {
          SystemTab.display => const DisplaySystemTab(),
          SystemTab.updates => const UpdatesSystemTab(),
          SystemTab.storage => const StorageSystemTab(),
          SystemTab.about => const AboutSystemTab(),
        },
      ),
    );
  }
}
