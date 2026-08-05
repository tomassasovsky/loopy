import 'package:test/test.dart';
import 'package:wifi_client/wifi_client.dart';

void main() {
  group('FakeWifiClient', () {
    // Zero delays: the delays exist so a human can see the spinner, and
    // waiting for them here would only make the suite slower.
    FakeWifiClient build() =>
        FakeWifiClient(scanDelay: Duration.zero, joinDelay: Duration.zero);

    test(
      'starts associated, with saved and out-of-range rows to show',
      () async {
        final client = build();

        final status = await client.status();
        expect(status.connected, isTrue);
        expect(status.ssid, 'Studio-5G');
        expect(status.ip, isNotEmpty);

        final networks = await client.scan();
        expect(networks.any((n) => n.saved && n.inRange), isTrue);
        expect(networks.any((n) => n.saved && !n.inRange), isTrue);
        expect(networks.any((n) => !n.secured), isTrue);
      },
    );

    test('a wrong passphrase fails the way the helper does', () async {
      final client = build();

      await expectLater(
        () => client.connect('Studio-Guest', psk: 'nope'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('authentication failed'),
          ),
        ),
      );
      expect((await client.status()).ssid, 'Studio-5G');
    });

    test('the right passphrase joins and saves the profile', () async {
      final client = build();

      await client.connect('Studio-Guest', psk: FakeWifiClient.passphrase);

      expect((await client.status()).ssid, 'Studio-Guest');
      final joined = (await client.scan()).firstWhere(
        (n) => n.ssid == 'Studio-Guest',
      );
      expect(joined.saved, isTrue);
    });

    test('a saved network joins without a passphrase', () async {
      final client = build();
      await client.disconnect();

      await client.connect('Studio-5G');

      expect((await client.status()).connected, isTrue);
    });

    test('an out-of-range saved network refuses to join', () async {
      final client = build();

      await expectLater(
        () => client.connect('Studio-Backline'),
        throwsA(isA<StateError>()),
      );
    });

    test('forgetting drops the profile and the association', () async {
      final client = build();

      await client.forget('Studio-5G');

      expect((await client.status()).connected, isFalse);
      final networks = await client.scan();
      expect(networks.firstWhere((n) => n.ssid == 'Studio-5G').saved, isFalse);
    });

    test('switched off, it reports nothing to show', () async {
      final client = build();

      await client.setEnabled(enabled: false);

      final status = await client.status();
      expect(status.enabled, isFalse);
      expect(status.connected, isFalse);
      expect(await client.scan(), isEmpty);
    });
  });
  group('createWifiClient', () {
    test('honours SEGNO_FAKE_RADIOS', () {
      // Asserted from both sides so the branch is covered by the ordinary CI
      // run AND by a local run with the define set — a factory that silently
      // stopped reading the flag would otherwise look fine in CI.
      final client = createWifiClient();
      if (kFakeRadios) {
        expect(client, isA<FakeWifiClient>());
      } else {
        expect(client, isNot(isA<FakeWifiClient>()));
      }
    });
  });
}
