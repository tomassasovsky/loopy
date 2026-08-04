import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';

void main() {
  test('default helperPath is the appliance segno-brightness-ctl', () {
    expect(
      const SystemBrightnessClient().helperPath,
      '/usr/bin/segno-brightness-ctl',
    );
  });
}
