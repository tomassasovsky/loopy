import 'package:wifi_client/wifi_client.dart';

/// App-facing WiFi API. Thin facade over [WifiClient] so presentation/cubits
/// never depend on the data package directly.
class WifiRepository {
  /// Creates a [WifiRepository] over [client].
  const WifiRepository({required WifiClient client}) : _client = client;

  final WifiClient _client;

  /// Whether the helper / radio stack is present.
  bool get isSupported => _client.isSupported;

  /// Current association + addressing.
  Future<WifiStatus> status() => _client.status();

  /// Nearby networks from a scan.
  Future<List<WifiNetwork>> scan() => _client.scan();

  /// Join [ssid]; [psk] null/empty for open networks.
  Future<void> connect(String ssid, {String? psk}) =>
      _client.connect(ssid, psk: psk);

  /// Drop the current association.
  Future<void> disconnect() => _client.disconnect();

  /// Remove a saved network by [ssid].
  Future<void> forget(String ssid) => _client.forget(ssid);

  /// Radio on/off — Control Center tap toggle.
  Future<void> setEnabled({required bool enabled}) =>
      _client.setEnabled(enabled: enabled);
}
