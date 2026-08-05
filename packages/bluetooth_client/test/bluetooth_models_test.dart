import 'package:bluetooth_client/bluetooth_client.dart';
import 'package:test/test.dart';

void main() {
  test('BluetoothStatus.fromJson', () {
    final status = BluetoothStatus.fromJson(const {
      'supported': true,
      'powered': true,
      'discoverable': false,
      'advertising': true,
      'alias': 'Segno',
      'connected': true,
      'device': 'AirPods Pro',
    });
    expect(status.powered, isTrue);
    expect(status.advertising, isTrue);
    expect(status.alias, 'Segno');
    expect(status.connected, isTrue);
    expect(status.device, 'AirPods Pro');
  });

  test('allows powered without discoverable or advertising', () {
    final status = BluetoothStatus.fromJson(const {
      'supported': true,
      'powered': true,
      'discoverable': false,
      'advertising': false,
      'alias': 'Segno',
    });
    expect(status.powered, isTrue);
    expect(status.discoverable, isFalse);
    expect(status.advertising, isFalse);
    expect(status.connected, isFalse);
    expect(status.device, isEmpty);
  });
}
