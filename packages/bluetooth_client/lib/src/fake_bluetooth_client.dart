import 'package:bluetooth_client/src/bluetooth_client.dart';
import 'package:bluetooth_client/src/bluetooth_models.dart';

/// The same `--dart-define=SEGNO_FAKE_RADIOS=true` switch `wifi_client`
/// reads, declared again here because the two client packages are
/// independent and neither should depend on the other to learn what kind of
/// build this is. Not exported: the app-facing constant is `wifi_client`'s.
const kFakeRadios = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// An in-memory Bluetooth stack for desktop development, the sibling of
/// `FakeWifiClient`.
///
/// Starts with one connected device, one pairing that is out of range, and one
/// device that is merely discoverable — the three row states the mockups draw.
/// Pairing is slow on purpose: bluez waits on a human pressing a button on the
/// device, and the pairing banner exists to cover exactly that wait.
class FakeBluetoothClient implements BluetoothClient {
  /// Creates a [FakeBluetoothClient].
  FakeBluetoothClient({
    this.scanDelay = const Duration(milliseconds: 900),
    this.pairDelay = const Duration(milliseconds: 2500),
  });

  /// How long a scan takes.
  final Duration scanDelay;

  /// How long a pairing waits on the device before it resolves.
  final Duration pairDelay;

  /// Address of the device that always refuses to pair, so the failure path is
  /// reachable without hunting for a real device that will not co-operate.
  static const String refusingAddress = 'DD:EE:FF:44:55:66';

  bool _powered = true;
  bool _discoverable = true;
  bool _advertising = false;

  final Map<String, _FakeDevice> _devices = {
    'AA:BB:CC:11:22:33': _FakeDevice(
      name: 'WH-1000XM4',
      kind: 'headphones',
      paired: true,
      connected: true,
    ),
    // Paired but out of range: it cannot be connected, only forgotten.
    'DD:EE:FF:44:55:66': _FakeDevice(
      name: 'Page turner',
      kind: 'keyboard',
      paired: true,
      inRange: false,
    ),
    '11:22:33:44:55:66': _FakeDevice(name: 'AirTurn BT-200', kind: 'keyboard'),
  };

  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async {
    final connected = _devices.values.where((d) => d.connected).firstOrNull;
    return BluetoothStatus(
      supported: true,
      powered: _powered,
      discoverable: _powered && _discoverable,
      advertising: _powered && _advertising,
      alias: 'Segno',
      connected: _powered && connected != null,
      device: _powered ? (connected?.name ?? '') : '',
    );
  }

  @override
  Future<List<BluetoothDevice>> scan() async {
    await Future<void>.delayed(scanDelay);
    if (!_powered) return const [];
    return [
      for (final entry in _devices.entries)
        BluetoothDevice(
          name: entry.value.name,
          address: entry.key,
          paired: entry.value.paired,
          connected: entry.value.connected,
          inRange: entry.value.inRange,
          kind: entry.value.kind,
        ),
    ];
  }

  @override
  Future<void> setPowered({required bool enabled}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _powered = enabled;
    if (!enabled) {
      for (final device in _devices.values) {
        device.connected = false;
      }
    }
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _discoverable = enabled;
  }

  @override
  Future<void> setAdvertising({required bool enabled}) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _advertising = enabled;
  }

  @override
  Future<void> pair(String address) async {
    await Future<void>.delayed(pairDelay);
    final device = _devices[address];
    if (device == null) throw StateError('segno-bt-ctl: no such device');
    if (address == refusingAddress || !device.inRange) {
      throw StateError('segno-bt-ctl: pair failed for $address');
    }
    device
      ..paired = true
      ..connected = true;
  }

  @override
  Future<void> connect(String address) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final device = _devices[address];
    if (device == null) throw StateError('segno-bt-ctl: no such device');
    if (!device.inRange) {
      throw StateError('segno-bt-ctl: connect failed for $address');
    }
    device.connected = true;
  }

  @override
  Future<void> disconnect(String address) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _devices[address]?.connected = false;
  }

  @override
  Future<void> forget(String address) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _devices.remove(address);
  }
}

class _FakeDevice {
  _FakeDevice({
    required this.name,
    required this.kind,
    this.paired = false,
    this.connected = false,
    this.inRange = true,
  });

  final String name;
  final String kind;
  bool paired;
  bool connected;
  final bool inRange;
}
