import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:test/test.dart';

class _FakeClient implements BluetoothClient {
  bool powered = false;

  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => BluetoothStatus(
    supported: true,
    powered: powered,
    discoverable: false,
    advertising: false,
  );

  @override
  Future<List<BluetoothDevice>> scan() async => const [];

  @override
  Future<void> setPowered({required bool enabled}) async {
    powered = enabled;
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}
}

void main() {
  test('setPowered delegates to client', () async {
    final client = _FakeClient();
    final repo = BluetoothRepository(client: client);
    await repo.setPowered(enabled: true);
    expect(client.powered, isTrue);
    final status = await repo.status();
    expect(status.powered, isTrue);
    expect(status.discoverable, isFalse);
  });
}
