import 'package:bluetooth_client/bluetooth_client.dart';

/// App-facing Bluetooth API. Thin facade over [BluetoothClient].
class BluetoothRepository {
  /// Creates a [BluetoothRepository] over [client].
  const BluetoothRepository({required BluetoothClient client})
    : _client = client;

  final BluetoothClient _client;

  /// Whether the helper / bluez stack is present.
  bool get isSupported => _client.isSupported;

  /// Adapter status.
  Future<BluetoothStatus> status() => _client.status();

  /// Timed discovery of nearby devices.
  Future<List<BluetoothDevice>> scan() => _client.scan();

  /// Adapter power on/off — Control Center tap toggle.
  Future<void> setPowered({required bool enabled}) =>
      _client.setPowered(enabled: enabled);

  /// Classic discoverable on/off.
  Future<void> setDiscoverable({required bool enabled}) =>
      _client.setDiscoverable(enabled: enabled);

  /// LE advertise + discoverable on/off.
  Future<void> setAdvertising({required bool enabled}) =>
      _client.setAdvertising(enabled: enabled);

  /// Pairs, trusts and connects a device.
  Future<void> pair(String address) => _client.pair(address);

  /// Connects an already-paired device.
  Future<void> connect(String address) => _client.connect(address);

  /// Drops a connection, keeping the pairing.
  Future<void> disconnect(String address) => _client.disconnect(address);

  /// Removes a pairing.
  Future<void> forget(String address) => _client.forget(address);
}
