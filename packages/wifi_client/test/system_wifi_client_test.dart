import 'package:test/test.dart';
import 'package:wifi_client/wifi_client.dart';

void main() {
  test('default helperPath is the appliance segno-wifi-ctl', () {
    expect(const SystemWifiClient().helperPath, '/usr/bin/segno-wifi-ctl');
  });
}
