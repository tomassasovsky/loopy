import 'package:bluetooth_client/bluetooth_client.dart';
import 'package:test/test.dart';

void main() {
  group('FakeBluetoothClient', () {
    test(
      'offers a connected, a paired-but-absent and a fresh device',
      () async {
        final devices = await FakeBluetoothClient().scan();

        expect(devices.where((d) => d.connected), isNotEmpty);
        expect(devices.where((d) => d.paired && !d.inRange), isNotEmpty);
        expect(devices.where((d) => !d.paired), isNotEmpty);
      },
    );

    test('reports a kind for the devices bluez would name', () async {
      final devices = await FakeBluetoothClient().scan();

      expect(
        devices.where((d) => d.kind == BluetoothDeviceKind.headphones),
        isNotEmpty,
      );
    });

    test('pairing succeeds and leaves the device connected', () async {
      final client = FakeBluetoothClient();
      const address = FakeBluetoothClient.pairableAddress;

      await client.pair(address);

      final after = (await client.scan()).firstWhere(
        (d) => d.address == address,
      );
      expect(after.paired, isTrue);
      expect(after.connected, isTrue);
    });

    test(
      'one device always refuses, so the failure banner is reachable',
      () async {
        final client = FakeBluetoothClient();

        await expectLater(
          client.pair(FakeBluetoothClient.refusingAddress),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('an out-of-range device cannot be connected to', () async {
      final client = FakeBluetoothClient();
      final absent = (await client.scan()).firstWhere((d) => !d.inRange);

      await expectLater(
        client.connect(absent.address),
        throwsA(isA<StateError>()),
      );
    });

    test('disconnect keeps the pairing; forget removes it', () async {
      final client = FakeBluetoothClient();
      final linked = (await client.scan()).firstWhere((d) => d.connected);

      await client.disconnect(linked.address);
      var after = (await client.scan()).firstWhere(
        (d) => d.address == linked.address,
      );
      expect(after.connected, isFalse);
      expect(after.paired, isTrue, reason: 'disconnect is not forget');

      await client.forget(linked.address);
      after = (await client.scan()).firstWhere(
        (d) => d.address == linked.address,
        orElse: () => const BluetoothDevice(name: '', address: ''),
      );
      expect(after.address, isEmpty);
    });

    test('powering off empties the scan and drops every link', () async {
      final client = FakeBluetoothClient();

      await client.setPowered(enabled: false);

      final status = await client.status();
      expect(status.powered, isFalse);
      expect(status.connected, isFalse);
      expect(await client.scan(), isEmpty);
    });

    test('pairing takes visibly longer than a toggle', () async {
      final client = FakeBluetoothClient();
      final watch = Stopwatch()..start();
      await client.pair(FakeBluetoothClient.pairableAddress);
      watch.stop();

      // Pairing waits on a human pressing a button; a fake that resolves
      // instantly cannot show the banner that exists because of it.
      expect(watch.elapsedMilliseconds, greaterThan(500));
    });
  });

  group('createBluetoothClient', () {
    test('is off by default, so a shipped build invents no devices', () {
      expect(createBluetoothClient(), isNot(isA<FakeBluetoothClient>()));
    });
  });

  group('bluetoothDeviceKindFromIcon', () {
    test('maps the bluez icons the helper passes through', () {
      expect(
        bluetoothDeviceKindFromIcon('audio-headset'),
        BluetoothDeviceKind.headphones,
      );
      expect(
        bluetoothDeviceKindFromIcon('input-keyboard'),
        BluetoothDeviceKind.keyboard,
      );
      expect(
        bluetoothDeviceKindFromIcon('phone'),
        BluetoothDeviceKind.phone,
      );
    });

    test('an icon bluez adds later reads as unknown, not as a crash', () {
      expect(
        bluetoothDeviceKindFromIcon('multimedia-player'),
        BluetoothDeviceKind.unknown,
      );
      expect(bluetoothDeviceKindFromIcon(''), BluetoothDeviceKind.unknown);
    });
  });
}
