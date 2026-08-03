import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';

void main() {
  test('unsupported client reports false', () async {
    const client = UnsupportedBrightnessClient();
    expect(await client.isSupported(), isFalse);
    expect(await client.get(), 0.8);
    await client.set(0.5);
  });
}
