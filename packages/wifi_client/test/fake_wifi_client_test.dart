import 'package:test/test.dart';
import 'package:wifi_client/wifi_client.dart';

void main() {
  group('FakeWifiClient', () {
    test('starts associated to a saved network in range', () async {
      final client = FakeWifiClient();
      final status = await client.status();

      expect(status.supported, isTrue);
      expect(status.enabled, isTrue);
      expect(status.connected, isTrue);
      expect(status.ssid, isNotEmpty);
      expect(status.ip, isNotEmpty);
    });

    test('offers the four row states the mockups draw', () async {
      final networks = await FakeWifiClient().scan();

      expect(networks.where((n) => n.saved && n.inRange), isNotEmpty);
      expect(networks.where((n) => n.saved && !n.inRange), isNotEmpty);
      expect(networks.where((n) => n.secured && !n.saved), isNotEmpty);
      expect(networks.where((n) => !n.secured), isNotEmpty);
    });

    test('a wrong passphrase fails the way the supplicant does', () async {
      final client = FakeWifiClient();

      // Failure is reachable on purpose: a fake that always succeeds cannot
      // drive the failure banner the mockups specify.
      await expectLater(
        client.connect('Studio 5G', psk: 'nope'),
        throwsA(isA<StateError>()),
      );
      await client.connect(
        'Studio 5G',
        psk: FakeWifiClient.workingPassphrase,
      );
      expect((await client.status()).ssid, 'Studio 5G');
    });

    test(
      'an out-of-range saved network refuses rather than pretending',
      () async {
        final client = FakeWifiClient();
        final absent = (await client.scan()).firstWhere((n) => !n.inRange);

        await expectLater(
          client.connect(absent.ssid),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('forget drops the credential and the association', () async {
      final client = FakeWifiClient();
      final ssid = (await client.status()).ssid;

      await client.forget(ssid);

      expect((await client.status()).connected, isFalse);
      final network = (await client.scan()).where((n) => n.ssid == ssid);
      expect(network.isEmpty || !network.first.saved, isTrue);
    });

    test('powering off empties the scan and drops the association', () async {
      final client = FakeWifiClient();

      await client.setEnabled(enabled: false);

      expect((await client.status()).enabled, isFalse);
      expect((await client.status()).connected, isFalse);
      expect(await client.scan(), isEmpty);
    });

    test('delays are real, so a spinner has time to be seen', () async {
      final client = FakeWifiClient();
      final watch = Stopwatch()..start();
      await client.scan();
      watch.stop();

      // A scan that resolves between frames never shows its spinner, which
      // makes the in-flight states unreachable — the point of the fake.
      expect(watch.elapsedMilliseconds, greaterThan(100));
    });
  });

  group('createWifiClient', () {
    test('is off by default, so a shipped build invents no networks', () {
      // Asserted from both sides so the flag is covered by the ordinary CI
      // run, which does not set it.
      expect(kFakeRadios, isFalse);
      expect(createWifiClient(), isNot(isA<FakeWifiClient>()));
    });
  });
}
