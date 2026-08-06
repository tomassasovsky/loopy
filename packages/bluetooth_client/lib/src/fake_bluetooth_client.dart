import 'package:bluetooth_client/src/bluetooth_client.dart';
import 'package:bluetooth_client/src/bluetooth_models.dart';

/// In-memory Bluetooth stack for driving the Network face off the appliance.
///
/// Selected by `--dart-define=SEGNO_FAKE_RADIOS=true`; off by default so a
/// shipped build can never present invented devices as real ones.
///
/// Opinionated rather than empty, because the point is to *reach* the states
/// the mockups draw: a connected device, a paired one that is out of range,
/// and a fresh one waiting to be paired. Delays are deliberate — a scan that
/// resolves between frames never shows its spinner. Failure is reachable on
/// purpose: [refusingAddress] never pairs, the way a device whose button was
/// never pressed does not.
class FakeBluetoothClient implements BluetoothClient {
  /// Creates a [FakeBluetoothClient].
  FakeBluetoothClient();

  /// The device that always refuses to pair, so the failure banner is
  /// reachable without unplugging anything.
  static const refusingAddress = 'CC:CC:CC:CC:CC:CC';

  /// A device that always pairs, so the success path is reachable too.
  static const pairableAddress = 'DD:DD:DD:DD:DD:DD';

  bool _powered = true;
  bool _discoverable = true;
  bool _advertising = false;

  final List<BluetoothDevice> _devices = [
    const BluetoothDevice(
      name: 'WH-1000XM4',
      address: 'AA:AA:AA:AA:AA:AA',
      paired: true,
      connected: true,
      kind: BluetoothDeviceKind.headphones,
    ),
    const BluetoothDevice(
      name: 'Page turner',
      address: 'BB:BB:BB:BB:BB:BB',
      paired: true,
      inRange: false,
      kind: BluetoothDeviceKind.keyboard,
    ),
    const BluetoothDevice(
      name: 'AirTurn BT-200',
      address: refusingAddress,
    ),
    // A fresh device that DOES pair. Without it the only unpaired device is
    // the one that always refuses, and a successful pairing — the state most
    // of the face is built around — would be unreachable.
    const BluetoothDevice(
      name: 'Studio monitor',
      address: 'DD:DD:DD:DD:DD:DD',
      kind: BluetoothDeviceKind.speaker,
    ),
  ];

  static const _scanDelay = Duration(milliseconds: 900);
  static const _actionDelay = Duration(milliseconds: 450);

  /// Pairing waits on a human, so it takes visibly longer than a toggle.
  static const _pairDelay = Duration(milliseconds: 1600);

  @override
  bool get isSupported => true;

  @override
  Future<BluetoothStatus> status() async => BluetoothStatus(
    supported: true,
    powered: _powered,
    discoverable: _discoverable,
    advertising: _advertising,
    alias: 'Segno',
    connected: _devices.any((d) => d.connected),
    device:
        _devices.where((d) => d.connected).map((d) => d.name).firstOrNull ?? '',
  );

  @override
  Future<List<BluetoothDevice>> scan() async {
    await Future<void>.delayed(_scanDelay);
    if (!_powered) return const [];
    return List.unmodifiable(_devices);
  }

  @override
  Future<void> setPowered({required bool enabled}) async {
    await Future<void>.delayed(_actionDelay);
    _powered = enabled;
    if (!enabled) {
      _discoverable = false;
      _advertising = false;
      _replaceAll((d) => d.connected ? _copy(d, connected: false) : d);
    }
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    await Future<void>.delayed(_actionDelay);
    _discoverable = enabled;
  }

  @override
  Future<void> setAdvertising({required bool enabled}) async {
    await Future<void>.delayed(_actionDelay);
    _advertising = enabled;
    if (enabled) _discoverable = true;
  }

  @override
  Future<void> pair(String address) async {
    await Future<void>.delayed(_pairDelay);
    if (address == refusingAddress) {
      throw StateError('Pairing timed out.');
    }
    _replaceOne(address, (d) => _copy(d, paired: true, connected: true));
  }

  @override
  Future<void> connect(String address) async {
    await Future<void>.delayed(_actionDelay);
    _replaceOne(address, (d) {
      if (!d.inRange) throw StateError('Device is not in range.');
      return _copy(d, connected: true);
    });
  }

  @override
  Future<void> disconnect(String address) async {
    await Future<void>.delayed(_actionDelay);
    _replaceOne(address, (d) => _copy(d, connected: false));
  }

  @override
  Future<void> forget(String address) async {
    await Future<void>.delayed(_actionDelay);
    _devices.removeWhere((d) => d.address == address);
  }

  void _replaceOne(
    String address,
    BluetoothDevice Function(BluetoothDevice) update,
  ) {
    final index = _devices.indexWhere((d) => d.address == address);
    if (index < 0) throw StateError('No such device.');
    _devices[index] = update(_devices[index]);
  }

  void _replaceAll(BluetoothDevice Function(BluetoothDevice) update) {
    for (var i = 0; i < _devices.length; i++) {
      _devices[i] = update(_devices[i]);
    }
  }

  static BluetoothDevice _copy(
    BluetoothDevice device, {
    bool? paired,
    bool? connected,
  }) => BluetoothDevice(
    name: device.name,
    address: device.address,
    paired: paired ?? device.paired,
    connected: connected ?? device.connected,
    inRange: device.inRange,
    kind: device.kind,
  );
}
