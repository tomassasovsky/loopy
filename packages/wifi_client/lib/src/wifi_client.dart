import 'package:wifi_client/src/wifi_models.dart';

/// I/O boundary for appliance WiFi (`segno-wifi-ctl`). Faked in tests.
abstract class WifiClient {
  /// Whether the helper / radio stack is present.
  bool get isSupported;

  /// Current association + addressing.
  Future<WifiStatus> status();

  /// Nearby networks from a scan.
  Future<List<WifiNetwork>> scan();

  /// Join [ssid]; [psk] null/empty for open networks.
  Future<void> connect(String ssid, {String? psk});

  /// Drop the current association.
  Future<void> disconnect();

  /// Remove a saved network by [ssid].
  Future<void> forget(String ssid);

  /// Radio on/off (`segno-wifi-ctl radio`) — Control Center tap toggle.
  Future<void> setEnabled({required bool enabled});
}
