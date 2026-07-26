import 'package:bluetooth_client/src/bluetooth_models.dart';

/// I/O boundary for appliance Bluetooth (`loopy-bt-ctl`). Faked in tests.
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

  /// LE advertise + discoverable on/off (broadcast as "Loopy").
  Future<void> setAdvertising({required bool enabled});
}
