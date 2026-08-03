import 'package:test/test.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeClient implements WifiClient {
  bool enabled = false;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: false,
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [];

  @override
  Future<void> connect(String ssid, {String? psk}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {
    this.enabled = enabled;
  }
}

void main() {
  test('setEnabled delegates to client', () async {
    final client = _FakeClient();
    final repo = WifiRepository(client: client);
    await repo.setEnabled(enabled: true);
    expect(client.enabled, isTrue);
    expect((await repo.status()).enabled, isTrue);
    expect((await repo.status()).connected, isFalse);
  });
}
