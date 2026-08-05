import 'package:flutter/material.dart';
import 'package:segno/bluetooth/bluetooth_tray_body.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/network/network_tab.dart';
import 'package:segno/wifi/wifi_tray_body.dart';

/// In-tray Network face: the two radios as tabs of one rail destination.
///
/// This is the first of the reorganised console's domains (#498), and the
/// shape the rest follow: a [PillTabs] strip at the top of the pane and a
/// chrome-less body per tab. There is deliberately **no** title bar and no
/// back control — the mockups give the tray one navigation surface, the rail,
/// and a back chevron beside a rail that is always on screen would be a second
/// way to do the same thing. Each body carries its own title row instead,
/// because that row also carries the radio's power switch.
///
/// Stateless, with the tab held by the tray cubit: the radio tiles on the tray
/// home face open this panel *at a specific tab* (long-press WiFi, or switch a
/// radio on), which local state could not express.
class NetworkTrayPanel extends StatelessWidget {
  /// Creates a [NetworkTrayPanel].
  const NetworkTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final NetworkTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<NetworkTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return KeyedSubtree(
      key: const Key('network_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left-aligned rather than stretched: the strip is a control sized
          // to its own labels, and a `stretch` column would otherwise pull
          // the `Wrap` full-width and float the pills against the far edge.
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<NetworkTab>(
              key: const Key('network_tabs'),
              selected: tab,
              onChanged: onTabChanged,
              tabs: [
                PillTab(
                  value: NetworkTab.wifi,
                  label: l10n.trayWifiLabel,
                ),
                PillTab(
                  value: NetworkTab.bluetooth,
                  label: l10n.trayBluetoothLabel,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
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
