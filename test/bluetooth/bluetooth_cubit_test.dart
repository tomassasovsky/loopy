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
}
