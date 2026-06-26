import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpio_client/gpio_client.dart';

import 'helpers/fake_gpio_bindings.dart';

void main() {
  group('createNativeGpioSource', () {
    test('returns null off-Pi (no gpiochip) without building', () {
      var built = false;
      final source = createNativeGpioSource(
        hasGpioChip: () => false,
        factory: () {
          built = true;
          return GpioControllerSource(
            lines: const [17],
            bindings: FakeGpioBindings(),
          );
        },
      );

      expect(source, isNull);
      expect(built, isFalse, reason: 'factory must not run off-Pi');
    });

    test('builds the source when a gpiochip is present', () {
      final built = GpioControllerSource(
        lines: const [17],
        bindings: FakeGpioBindings(),
      );
      addTearDown(built.dispose);

      final source = createNativeGpioSource(
        hasGpioChip: () => true,
        factory: () => built,
      );

      expect(source, same(built));
    });

    test('returns null and reports when construction throws', () {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);

      final source = createNativeGpioSource(
        hasGpioChip: () => true,
        factory: () => throw const GpioException('no libgpiod'),
      );

      expect(source, isNull);
      expect(errors, hasLength(1));
      expect(errors.single.library, 'gpio_client');
    });
  });

  group('gpioDefaultLines', () {
    test('mirrors the GPIO entries of ControllerMapping.gpioDefaults', () {
      final expected = [
        for (final entry in ControllerMapping.gpioDefaults().entries)
          entry.trigger.id,
      ];
      expect(gpioDefaultLines(), expected);
      expect(gpioDefaultLines(), isNotEmpty);
    });
  });
}
