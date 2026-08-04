import 'package:bluetooth_client/bluetooth_client.dart';
import 'package:test/test.dart';

void main() {
  test('default helperPath is the appliance segno-bt-ctl', () {
    expect(const SystemBluetoothClient().helperPath, '/usr/bin/segno-bt-ctl');
  });
}
