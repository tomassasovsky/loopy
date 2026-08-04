import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

void main() {
  const studio = WifiNetwork(ssid: 'Studio', signal: 80, secured: true);
  const guest = WifiNetwork(ssid: 'Guest', signal: 40, secured: false);

  test('keeps the joining SSID in the list while connect is in flight', () {
    final visible = visibleWifiNetworks(
      const WifiState(
        networks: [studio, guest],
        connectingSsid: 'Studio',
      ),
    );
    expect(visible, [studio, guest]);
  });

  test('hides the associated SSID once connected', () {
    final visible = visibleWifiNetworks(
      const WifiState(
        networks: [studio, guest],
        status: WifiStatus(
          supported: true,
          enabled: true,
          connected: true,
          ssid: 'Studio',
          ip: '192.168.1.2',
          signal: 80,
        ),
      ),
    );
    expect(visible, [guest]);
  });
}
