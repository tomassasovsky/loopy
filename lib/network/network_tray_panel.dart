import 'package:flutter/material.dart';
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/bluetooth/bluetooth_tray_body.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/network/network_tab.dart';
import 'package:segno/wifi/wifi_tray_body.dart';

/// In-tray Network face: the two radios as tabs of one rail destination.
///
/// This is the first of the reorganised console's domains (#498), and the
/// shape the rest follow: **one** [HostTrayChromeBar] for the domain, a
/// [PillTabs] strip under it, and a chrome-less body per tab. The bodies are
/// the same widgets the two former rail entries used, minus the title bar each
/// carried — two panels with their own chrome under one domain would stack two
/// bars.
///
/// The trailing chrome action is per-tab rather than per-domain: rescanning is
/// a WiFi verb on the WiFi tab and a Bluetooth verb on the Bluetooth tab, so
/// the domain asks the showing tab for its action instead of owning one.
///
/// Stateless, with the tab held by the tray cubit: the radio tiles on the tray
/// home face open this panel *at a specific tab* (long-press WiFi, or switch a
/// radio on), which local state could not express.
class NetworkTrayPanel extends StatelessWidget {
  /// Creates a [NetworkTrayPanel].
  const NetworkTrayPanel({
    required this.tab,
    required this.onTabChanged,
    required this.onBack,
    super.key,
  });

  /// The showing tab.
  final NetworkTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<NetworkTab> onTabChanged;

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return KeyedSubtree(
      key: const Key('network_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('network_back'),
            title: l10n.trayNetworkLabel,
            onBack: onBack,
            trailing: switch (tab) {
              NetworkTab.wifi => const WifiScanAction(),
              NetworkTab.bluetooth => const BluetoothScanAction(),
            },
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
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
