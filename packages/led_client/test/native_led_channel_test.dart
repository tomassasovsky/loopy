import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:led_client/led_client.dart';

import 'helpers/fake_led_transport.dart';

void main() {
  group('createNativeLedChannel', () {
    test('returns null off-Pi (no serial device) without building', () {
      var built = false;
      final repo = createNativeLedChannel(
        hasSerialDevice: () => false,
        factory: () {
          built = true;
          return LedRepository(FakeLedTransport());
        },
      );

      expect(repo, isNull);
      expect(built, isFalse);
    });

    test('builds the repository when a serial device is present', () {
      final built = LedRepository(FakeLedTransport());
      final repo = createNativeLedChannel(
        hasSerialDevice: () => true,
        factory: () => built,
      );
      expect(repo, same(built));
    });

    test('returns null and reports when construction throws', () {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);

      final repo = createNativeLedChannel(
        hasSerialDevice: () => true,
        factory: () => throw StateError('no serial'),
      );

      expect(repo, isNull);
      expect(errors, hasLength(1));
      expect(errors.single.library, 'led_client');
    });
  });
}
