import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// Scan rows shown in the found-networks list.
///
/// Keeps the SSID being joined in the list (so the spinner lives there), and
/// hides the currently associated SSID once [WifiStatus.connected] is true so
/// it only appears in the connected slot.
List<WifiNetwork> visibleWifiNetworks(WifiState state) {
  final connectedSsid = state.status.connected && state.status.ssid.isNotEmpty
      ? state.status.ssid
      : null;
  if (connectedSsid == null) return state.networks;
  return [
    for (final network in state.networks)
      if (network.ssid != connectedSsid) network,
  ];
}
