import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpio_client/gpio_client.dart';

import 'helpers/fake_gpio_bindings.dart';

void main() {
  group('GpioControllerSource', () {
    late FakeGpioBindings bindings;
    late GpioControllerSource source;

    GpioControllerSource build({
      List<int> lines = const [17, 27],
      Duration debounce = const Duration(milliseconds: 20),
    }) {
      bindings = FakeGpioBindings();
      source = GpioControllerSource(
        lines: lines,
        bindings: bindings,
        debounce: debounce,
      );
      addTearDown(source.dispose);
      return source;
    }

    group('setup', () {
      test('requests the given lines on construction', () {
        build(lines: const [17, 27, 22, 23]);
        expect(bindings.requestedLines, const [17, 27, 22, 23]);
        expect(bindings.calls, contains('open'));
      });
    });

    group('edge -> input (active-low)', () {
      test('a falling edge (level 0) is a press (value 1)', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(17, 0);
        await pumpEventQueue();

        expect(received, const [
          RawControllerInput(
            kind: ControllerSourceKind.gpio,
            id: 17,
            value: 1,
          ),
        ]);
        expect(received.single.isPress, isTrue);
        await sub.cancel();
      });

      test('a rising edge (level 1) is a release (value 0)', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(17, 1);
        await pumpEventQueue();

        expect(received.single.value, 0);
        expect(received.single.isPress, isFalse);
        await sub.cancel();
      });

      test('edges arrive through the bindings callback too', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        bindings.emit(27, 0);
        await pumpEventQueue();

        expect(received.single.id, 27);
        expect(received.single.value, 1);
        await sub.cancel();
      });
    });

    group('debounce', () {
      test('collapses sub-window repeats of the same pin', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source
          ..pushForTest(17, 0) // press, emit (tsUs 0)
          ..pushForTest(17, 1, tsUs: 5000) // +5ms bounce -> suppressed
          ..pushForTest(17, 0, tsUs: 10000) // +10ms bounce -> suppressed
          ..pushForTest(17, 1, tsUs: 30000); // +30ms -> emit (release)
        await pumpEventQueue();

        expect(received.map((e) => e.value), [1, 0]);
        await sub.cancel();
      });

      test('debounces each pin independently', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source
          ..pushForTest(17, 0) // pin 17 emit (tsUs 0)
          ..pushForTest(27, 0, tsUs: 5000) // pin 27 emit (other pin)
          ..pushForTest(17, 1, tsUs: 10000); // pin 17 +10ms -> suppressed
        await pumpEventQueue();

        expect(received.map((e) => e.id), [17, 27]);
        await sub.cancel();
      });

      test('leading-edge: a continuous bounce cannot keep resetting', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        // Edges 5ms apart: the window is measured from the first emit (t=0), so
        // t=20ms passes despite the steady stream between.
        var level = 0;
        for (var t = 0; t <= 20000; t += 5000) {
          source.pushForTest(17, level, tsUs: t);
          level = level == 0 ? 1 : 0;
        }
        await pumpEventQueue();

        expect(received.length, 2); // t=0 and t=20000
        await sub.cancel();
      });
    });

    group('activity tap', () {
      test('blinks on every edge, even debounced ones', () async {
        build();
        final inputs = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final inputSub = source.inputs.listen(inputs.add);
        final activitySub = source.activity.listen(activity.add);

        source
          ..pushForTest(17, 0) // tsUs 0
          ..pushForTest(17, 1, tsUs: 5000); // debounced out of inputs
        await pumpEventQueue();

        expect(inputs.length, 1, reason: 'second is debounced');
        expect(activity.length, 2, reason: 'activity is the raw pre-map edge');
        await inputSub.cancel();
        await activitySub.cancel();
      });
    });

    group('dispose', () {
      test('closes then disposes the bindings', () async {
        build();
        expect(source.isDisposed, isFalse);

        await source.dispose();

        expect(source.isDisposed, isTrue);
        final closeIndex = bindings.calls.indexOf('close');
        final disposeIndex = bindings.calls.indexOf('dispose');
        expect(closeIndex, greaterThanOrEqualTo(0));
        expect(disposeIndex, greaterThan(closeIndex));
      });

      test('closes both streams', () async {
        build();
        await source.dispose();
        await expectLater(source.inputs, emitsDone);
        await expectLater(source.activity, emitsDone);
      });

      test('is idempotent', () async {
        build();
        await source.dispose();
        await source.dispose();
        expect(
          bindings.calls.where((c) => c == 'dispose').length,
          1,
        );
      });

      test('an edge after dispose emits nothing on either stream', () async {
        build();
        final received = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);
        final activitySub = source.activity.listen(activity.add);
        await source.dispose();

        source.pushForTest(17, 0);
        await pumpEventQueue();

        expect(received, isEmpty);
        expect(activity, isEmpty, reason: 'activity sink is closed too');
        await sub.cancel();
        await activitySub.cancel();
      });
    });
  });
}
