import 'package:bluetooth_client/bluetooth_client.dart';
import 'package:test/test.dart';

void main() {
  test('BluetoothStatus.fromJson', () {
    final status = BluetoothStatus.fromJson(const {
      'supported': true,
      'powered': true,
      'discoverable': false,
      'advertising': true,
      'alias': 'Loopy',
    });
    expect(status.powered, isTrue);
    expect(status.advertising, isTrue);
    expect(status.alias, 'Loopy');
  });

  test('allows powered without discoverable or advertising', () {
    final status = BluetoothStatus.fromJson(const {
      'supported': true,
      'powered': true,
      'discoverable': false,
      'advertising': false,
      'alias': 'Loopy',
    });
    expect(status.powered, isTrue);
    expect(status.discoverable, isFalse);
    expect(status.advertising, isFalse);
  });
}
