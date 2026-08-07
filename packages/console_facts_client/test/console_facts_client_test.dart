import 'dart:async';

import 'package:console_facts_client/console_facts_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('StorageUsage', () {
    test('a known reading is known', () {
      const usage = StorageUsage(
        sessionBytes: 1,
        captureBytes: 2,
        pluginBytes: 3,
        systemBytes: 4,
        freeBytes: 5,
      );
      expect(usage.known, isTrue);
    });

    test('the unknown reading is not known, and its zeroes are not facts', () {
      const usage = StorageUsage.unknown();
      expect(usage.known, isFalse);
      expect(usage.freeBytes, 0);
    });
  });

  group('ConsoleFacts', () {
    test('an empty serial means this build is not a console', () {
      expect(ConsoleFacts.unknown.isConsole, isFalse);
      expect(const ConsoleFacts(name: 'VAMP 16').isConsole, isFalse);
      expect(const ConsoleFacts(serial: 'VMP-16-0042').isConsole, isTrue);
    });
  });

  group('UnsupportedConsoleFactsClient', () {
    const client = UnsupportedConsoleFactsClient();

    test('answers "I do not know" to everything', () async {
      expect(client.isSupported, isFalse);
      expect((await client.storage()).known, isFalse);
      expect(await client.facts(), ConsoleFacts.unknown);
      expect(await client.exportDestination(), isEmpty);
      expect(await client.deleteCapturesOlderThan(30), 0);
    });
  });

  group('FakeConsoleFactsClient', () {
    test('at zero latency it schedules NO timer', () {
      // The whole point of the zero case: even `Future.delayed(Duration.zero)`
      // schedules a timer, and a `testWidgets` body that awaits one without
      // pumping waits for it forever. A fake that is configurable but still
      // schedules is not fixed — so this asserts the absence of the timer, not
      // just that the call is quick.
      fakeAsync((async) {
        var settled = false;
        unawaited(
          FakeConsoleFactsClient(
            latency: Duration.zero,
          ).storage().then((_) => settled = true),
        );
        async.flushMicrotasks();
        expect(settled, isTrue);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('with a latency it DOES schedule one — the case tests must avoid', () {
      fakeAsync((async) {
        var settled = false;
        unawaited(
          FakeConsoleFactsClient(
            latency: const Duration(milliseconds: 50),
          ).storage().then((_) => settled = true),
        );
        async.flushMicrotasks();
        expect(settled, isFalse);
        expect(async.pendingTimers, isNotEmpty);
        async.elapse(const Duration(milliseconds: 50));
        expect(settled, isTrue);
      });
    });

    test(
      'deleting captures changes the figures the next read reports',
      () async {
        final client = FakeConsoleFactsClient(latency: Duration.zero);
        final before = await client.storage();

        final removed = await client.deleteCapturesOlderThan(30);
        expect(removed, greaterThan(0));

        final after = await client.storage();
        expect(after.captureBytes, lessThan(before.captureBytes));
        expect(after.freeBytes, greaterThan(before.freeBytes));
      },
    );

    test('a second delete has nothing left to take', () async {
      final client = FakeConsoleFactsClient(latency: Duration.zero);
      await client.deleteCapturesOlderThan(30);
      expect(await client.deleteCapturesOlderThan(30), 0);
    });

    test('an unmounted export volume reports nowhere to export', () async {
      final client = FakeConsoleFactsClient(
        latency: Duration.zero,
        exportVolumeMounted: false,
      );
      expect(await client.exportDestination(), isEmpty);
    });

    test('it answers with the rig the mockups draw', () async {
      final facts = await FakeConsoleFactsClient(
        latency: Duration.zero,
      ).facts();
      expect(facts.serial, 'VMP-16-0042');
      expect(facts.isConsole, isTrue);
    });
  });

  group('createConsoleFactsClient', () {
    test('without the define, the app gets the honest "unknown" client', () {
      // No `--dart-define=SEGNO_FAKE_RADIOS` under `dart test`, which is also
      // what a shipped build gets.
      expect(kFakeConsoleFacts, isFalse);
      expect(createConsoleFactsClient(), isA<UnsupportedConsoleFactsClient>());
    });
  });
}
