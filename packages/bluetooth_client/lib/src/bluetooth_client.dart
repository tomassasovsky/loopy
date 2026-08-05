import 'package:bluetooth_client/src/bluetooth_models.dart';

/// I/O boundary for appliance Bluetooth (`segno-bt-ctl`). Faked in tests.
abstract class BluetoothClient {
  /// Whether the helper / bluez stack is present.
  bool get isSupported;

  /// Adapter status (powered, discoverable, advertising).
  Future<BluetoothStatus> status();

  /// Timed discovery of nearby devices.
  Future<List<BluetoothDevice>> scan();

  /// Adapter power on/off — Control Center tap toggle.
  Future<void> setPowered({required bool enabled});

  /// Classic discoverable on/off.
  Future<void> setDiscoverable({required bool enabled});

  /// LE advertise + discoverable on/off (broadcast as "Segno").
  Future<void> setAdvertising({required bool enabled});

  /// Pairs (and trusts) [address], then connects it.
  ///
  /// Long-running by nature: bluez waits on the device to confirm, which is
  /// why the console shows a cancellable banner while this is outstanding.
  Future<void> pair(String address);

  /// Connects an already-paired [address].
  Future<void> connect(String address);

  /// Drops the connection to [address], keeping the pairing.
  Future<void> disconnect(String address);

  /// Removes the pairing for [address] entirely.
  Future<void> forget(String address);
}
