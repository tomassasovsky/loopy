import 'package:bloc_test/bloc_test.dart';
import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';

class _FakeBluetoothClient implements BluetoothClient {
  _FakeBluetoothClient({
    this.supported = true,
    BluetoothStatus? status,
    List<BluetoothDevice>? devices,
  }) : statusValue =
           status ??
           const BluetoothStatus(
             supported: true,
             powered: true,
             discoverable: false,
             advertising: false,
             alias: 'Segno',
           ),
       devices = List.of(devices ?? const []);

  bool supported;
  BluetoothStatus statusValue;
  List<BluetoothDevice> devices;

  @override
  bool get isSupported => supported;

  @override
  Future<BluetoothStatus> status() async => statusValue;

  @override
  Future<List<BluetoothDevice>> scan() async => devices;

  @override
  Future<void> setPowered({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: enabled,
      discoverable: enabled && statusValue.discoverable,
      advertising: enabled && statusValue.advertising,
      alias: statusValue.alias,
    );
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: true,
      discoverable: enabled,
      advertising: statusValue.advertising,
      alias: statusValue.alias,
    );
  }

  @override
  Future<void> setAdvertising({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: true,
      discoverable: enabled || statusValue.discoverable,
      advertising: enabled,
      alias: statusValue.alias,
    );
  }

  /// Recorded device verbs, so a test can assert what the cubit asked for.
  final List<String> calls = [];

  /// When set, the next [pair] throws with this message.
  String? pairFailure;

  @override
  Future<void> pair(String address) async {
    calls.add('pair $address');
    final failure = pairFailure;
    if (failure != null) {
      pairFailure = null;
      throw StateError(failure);
    }
    devices = [
      for (final d in devices)
        if (d.address == address)
          BluetoothDevice(
            name: d.name,
            address: d.address,
            paired: true,
            connected: true,
            kind: d.kind,
          )
        else
          d,
    ];
  }

  @override
  Future<void> connect(String address) async => calls.add('connect $address');

  @override
  Future<void> disconnect(String address) async =>
      calls.add('disconnect $address');

  @override
  Future<void> forget(String address) async {
    calls.add('forget $address');
    devices = [
      for (final d in devices)
        if (d.address != address) d,
    ];
  }
}

BluetoothRepository _repo(_FakeBluetoothClient client) =>
    BluetoothRepository(client: client);

void main() {
  group('BluetoothCubit', () {
    blocTest<BluetoothCubit, BluetoothState>(
      'load marks unsupported when helper missing',
      build: () => BluetoothCubit(
        repository: _repo(
          _FakeBluetoothClient(
            supported: false,
            status: BluetoothStatus.unsupported,
          ),
        ),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [
        const BluetoothState(busy: true),
        const BluetoothState(),
      ],
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'setDiscoverable updates status',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.setDiscoverable(enabled: true);
      },
      verify: (cubit) {
        expect(cubit.state.status.discoverable, isTrue);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'scan populates devices',
      build: () => BluetoothCubit(
        repository: _repo(
          _FakeBluetoothClient(
            devices: const [
              BluetoothDevice(name: 'Phone', address: 'AA:BB:CC:DD:EE:FF'),
            ],
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.devices, hasLength(1));
        expect(cubit.state.devices.first.name, 'Phone');
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'setAdvertising updates advertising flag',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.setAdvertising(enabled: true);
      },
      verify: (cubit) {
        expect(cubit.state.status.advertising, isTrue);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'togglePowered flips adapter power',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.togglePowered();
      },
      verify: (cubit) {
        expect(cubit.state.status.powered, isFalse);
      },
    );
  });

  group('device actions', () {
    const address = 'AA:BB:CC:DD:EE:FF';
    BluetoothDevice fresh() => const BluetoothDevice(
      name: 'Cans',
      address: address,
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'pair re-reads scan and status rather than trusting the verb — bluez '
      'accepts a command and leaves the device as it was',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()]);
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
      },
      verify: (cubit) {
        expect(cubit.state.devices.single.paired, isTrue);
        expect(cubit.state.pairingAddress, isNull);
        expect(cubit.state.errorMessage, isNull);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'pairing marks pairingAddress and NOT busy — the list stays live '
      'behind the banner while a human is at the far device',
      build: () =>
          BluetoothCubit(repository: _repo(_FakeBluetoothClient(
            devices: [fresh()],
          ))),
      act: (cubit) async {
        await cubit.load();
        final pairing = cubit.pair(address);
        expect(cubit.state.pairingAddress, address);
        expect(cubit.state.busy, isFalse);
        await pairing;
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'a refusal ties the message to the device it was about',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()])
          ..pairFailure = 'Pairing timed out.';
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
      },
      verify: (cubit) {
        expect(cubit.state.failedAddress, address);
        expect(cubit.state.errorMessage, contains('Pairing timed out'));
        expect(cubit.state.pairingAddress, isNull);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'cancelPairing drops the marker and claims nothing more — the helper '
      'call cannot be recalled once issued',
      build: () =>
          BluetoothCubit(repository: _repo(_FakeBluetoothClient(
            devices: [fresh()],
          ))),
      act: (cubit) async {
        await cubit.load();
        final pairing = cubit.pair(address);
        cubit.cancelPairing();
        expect(cubit.state.pairingAddress, isNull);
        await pairing;
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'forget removes the pairing and the row',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()]);
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.forget(address);
      },
      verify: (cubit) {
        expect(cubit.state.devices, isEmpty);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'device verbs are inert when the stack is unsupported',
      build: () => BluetoothCubit(
        repository: _repo(_FakeBluetoothClient(supported: false)),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
        await cubit.connect(address);
        await cubit.disconnect(address);
        await cubit.forget(address);
      },
      verify: (cubit) {
        expect(cubit.state.errorMessage, isNull);
        expect(cubit.state.pairingAddress, isNull);
      },
    );
  });
}
