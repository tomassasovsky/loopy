import 'package:flutter_test/flutter_test.dart';
import 'package:led_client/led_client.dart';

import 'helpers/fake_led_transport.dart';

void main() {
  group('LedRepository', () {
    test('starts unknown', () {
      expect(LedRepository(FakeLedTransport()).health, LedHealth.unknown);
    });

    group('start', () {
      test('opens, pings, and resolves ok on ack', () async {
        final transport = FakeLedTransport();
        final repo = LedRepository(transport);

        final health = await repo.start();

        expect(health, LedHealth.ok);
        expect(repo.health, LedHealth.ok);
        expect(transport.calls, ['open', 'ping']);
      });

      test('resolves missing when the driver does not ack', () async {
        final repo = LedRepository(FakeLedTransport(pingAck: false));
        expect(await repo.start(), LedHealth.missing);
      });

      test('is idempotent (pings once)', () async {
        final transport = FakeLedTransport();
        final repo = LedRepository(transport);

        await repo.start();
        await repo.start();

        expect(transport.calls.where((c) => c == 'ping').length, 1);
      });
    });

    group('pushFrame', () {
      test('sends a serialised frame', () {
        final transport = FakeLedTransport();
        final repo = LedRepository(transport)
          ..pushFrame(const LedFrame(running: true));

        expect(transport.sent, hasLength(1));
        expect(transport.sent.single, const LedFrame(running: true).toBytes());
        expect(repo.lastFrame, const LedFrame(running: true));
      });

      test('skips an unchanged frame (diffed)', () {
        final transport = FakeLedTransport();
        LedRepository(transport)
          ..pushFrame(const LedFrame(running: true))
          ..pushFrame(const LedFrame(running: true));

        expect(transport.sent, hasLength(1));
      });

      test('sends again when the frame changes', () {
        final transport = FakeLedTransport();
        LedRepository(transport)
          ..pushFrame(const LedFrame(running: true))
          ..pushFrame(const LedFrame());

        expect(transport.sent, hasLength(2));
      });
    });

    test('dispose closes the transport', () {
      final transport = FakeLedTransport();
      LedRepository(transport).dispose();
      expect(transport.calls, contains('close'));
    });

    test('the default transport is a no-op (reports healthy)', () async {
      final repo = LedRepository();
      expect(await repo.start(), LedHealth.ok);
      // Exercise the no-op send/close paths — must not throw.
      expect(
        () => repo.pushFrame(const LedFrame(running: true)),
        returnsNormally,
      );
      expect(repo.dispose, returnsNormally);
    });
  });
}
