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

  /// Pairs with [address] — discover, pair, trust, connect.
  ///
  /// Waits on a human pressing a button on the far device, so it can take as
  /// long as it takes. Reports success or failure only: the caller re-reads
  /// [scan] and [status] afterwards rather than trusting this call's account
  /// of what it changed, because bluez accepts commands it then does nothing
  /// with.
  Future<void> pair(String address);

  /// Connects an already-paired [address].
  Future<void> connect(String address);

  /// Drops the link to [address], leaving the pairing in place.
  Future<void> disconnect(String address);

  /// Removes the pairing for [address] entirely.
  Future<void> forget(String address);
}
