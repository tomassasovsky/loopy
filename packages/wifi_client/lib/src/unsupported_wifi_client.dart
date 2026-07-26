import 'package:wifi_client/src/wifi_client.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// No-op client used on desktop / when the helper is absent.
class UnsupportedWifiClient implements WifiClient {
  /// Creates an [UnsupportedWifiClient].
  const UnsupportedWifiClient();

  @override
  bool get isSupported => false;

  @override
  Future<WifiStatus> status() async => WifiStatus.unsupported;

  @override
  Future<List<WifiNetwork>> scan() async => const [];

  @override
  Future<void> connect(String ssid, {String? psk}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {}
}
