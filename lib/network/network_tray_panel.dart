import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/bluetooth/bluetooth_tray_body.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/network/network_tab.dart';
import 'package:segno/wifi/wifi_tray_body.dart';

/// The Network domain: a tab strip, a gap, and the body — and nothing else.
///
/// Deliberately owns no chrome. Each tab draws its own title row, because a
/// title row here carries a *per-tab* control (that radio's rescan and power
/// switch) and hoisting those into a shared bar means the bar has to know
/// which tab is showing — the mechanism this face was first built with, and
/// which the mockups then deleted.
///
/// Stateless: the selected tab lives in [SettingsTrayCubit] so a tray-home
/// shortcut can open the domain **at** a tab, and so leaving and returning
/// lands where it was left.
class NetworkTrayPanel extends StatelessWidget {
  /// Creates a [NetworkTrayPanel].
  const NetworkTrayPanel({super.key});

  /// Gap between the strip and the body.
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.networkTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('network_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<NetworkTab>(
              key: const Key('network_tabs'),
              selected: tab,
              onChanged: cubit.showNetworkTab,
              tabs: [
                PillTab(value: NetworkTab.wifi, label: l10n.trayWifiLabel),
                PillTab(
                  value: NetworkTab.bluetooth,
                  label: l10n.trayBluetoothLabel,
                ),
              ],
            ),
          ),
          const SizedBox(height: _gap),
          Expanded(
            child: switch (tab) {
              NetworkTab.wifi => const WifiTrayBody(),
              NetworkTab.bluetooth => const BluetoothTrayBody(),
            },
          ),
        ],
      ),
    );
  }
}
