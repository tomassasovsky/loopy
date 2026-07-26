import 'package:bluetooth_client/src/bluetooth_client.dart';
import 'package:bluetooth_client/src/bluetooth_models.dart';

/// No-op client used on desktop / when the helper is absent.
class UnsupportedBluetoothClient implements BluetoothClient {
  /// Creates an [UnsupportedBluetoothClient].
  const UnsupportedBluetoothClient();

  @override
  bool get isSupported => false;

  @override
  Future<BluetoothStatus> status() async => BluetoothStatus.unsupported;

  @override
  Future<List<BluetoothDevice>> scan() async => const [];

  @override
  Future<void> setPowered({required bool enabled}) async {}

  @override
  Future<void> setDiscoverable({required bool enabled}) async {}

  @override
  Future<void> setAdvertising({required bool enabled}) async {}
}
