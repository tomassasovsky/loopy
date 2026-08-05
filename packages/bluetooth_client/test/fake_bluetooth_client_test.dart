import 'package:bluetooth_client/bluetooth_client.dart';
import 'package:test/test.dart';

void main() {
  group('FakeBluetoothClient', () {
    FakeBluetoothClient build() =>
        FakeBluetoothClient(scanDelay: Duration.zero, pairDelay: Duration.zero);

    test('starts with a connected, a stale and a fresh device', () async {
      final client = build();

      final devices = await client.scan();
      expect(devices.any((d) => d.connected && d.paired), isTrue);
      expect(devices.any((d) => d.paired && !d.inRange), isTrue);
      expect(devices.any((d) => !d.paired), isTrue);

      final status = await client.status();
      expect(status.connected, isTrue);
      expect(status.device, 'WH-1000XM4');
    });

    test('pairing an in-range device connects it too', () async {
      final client = build();

      await client.pair('11:22:33:44:55:66');

      final device = (await client.scan()).firstWhere(
        (d) => d.address == '11:22:33:44:55:66',
      );
      expect(device.paired, isTrue);
      expect(device.connected, isTrue);
    });

    test(
      'one device always refuses, so the failure path is reachable',
      () async {
        final client = build();

        await expectLater(
          () => client.pair(FakeBluetoothClient.refusingAddress),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('disconnect keeps the pairing; forget removes the device', () async {
      final client = build();
      const address = 'AA:BB:CC:11:22:33';

      await client.disconnect(address);
      final device = (await client.scan()).firstWhere(
        (d) => d.address == address,
      );
      expect(device.connected, isFalse);
      expect(device.paired, isTrue);

      await client.forget(address);
      expect(
        (await client.scan()).where((d) => d.address == address),
        isEmpty,
      );
    });

    test('powering off drops connections and empties the list', () async {
      final client = build();

      await client.setPowered(enabled: false);

      final status = await client.status();
      expect(status.powered, isFalse);
      expect(status.connected, isFalse);
      expect(await client.scan(), isEmpty);
    });

    test('visibility switches are reported back', () async {
      final client = build();

      await client.setAdvertising(enabled: true);
      await client.setDiscoverable(enabled: false);

      final status = await client.status();
      expect(status.advertising, isTrue);
      expect(status.discoverable, isFalse);
    });
  });
  group('createBluetoothClient', () {
    test('honours SEGNO_FAKE_RADIOS', () {
      final client = createBluetoothClient();
      if (const bool.fromEnvironment('SEGNO_FAKE_RADIOS')) {
        expect(client, isA<FakeBluetoothClient>());
      } else {
        expect(client, isNot(isA<FakeBluetoothClient>()));
      }
    });
  });
}
