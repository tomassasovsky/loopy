import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpio_client/gpio_client.dart';

import 'helpers/fake_gpio_bindings.dart';

void main() {
  const encoder = GpioEncoderConfig(pinA: 5, pinB: 6);
  const footswitch = 17;

  late FakeGpioBindings bindings;
  late GpioControllerSource source;

  GpioControllerSource build({
    Duration sanityFloor = const Duration(milliseconds: 1),
  }) {
    bindings = FakeGpioBindings();
    source = GpioControllerSource(
      lines: const [footswitch],
      bindings: bindings,
      encoder: encoder,
      sanityFloor: sanityFloor,
    );
    addTearDown(source.dispose);
    return source;
  }

  /// Pushes the four single-bit edges of one detent, spaced past the sanity
  /// floor. [cw] selects the clockwise gray-code cycle 3→1→0→2→3, else the
  /// reverse.
  void turnOneDetent({required bool cw, required int startUs}) {
    // From idle (A=1,B=1): CW falls A first; CCW falls B first.
    final steps = cw
        ? const [
            [encoderA, 0],
            [encoderB, 0],
            [encoderA, 1],
            [encoderB, 1],
          ]
        : const [
            [encoderB, 0],
            [encoderA, 0],
            [encoderB, 1],
            [encoderA, 1],
          ];
    for (var i = 0; i < steps.length; i++) {
      source.pushForTest(steps[i][0], steps[i][1], tsUs: startUs + i * 5000);
    }
  }

  group('GpioControllerSource encoder', () {
    test('requests the encoder A/B pins alongside the press lines', () {
      build();
      expect(bindings.requestedLines, const [footswitch, 5, 6]);
    });

    group('quadrature', () {
      test('a clockwise detent emits +1 on rotation', () async {
        build();
        final detents = <int>[];
        final sub = source.rotation.listen(detents.add);

        turnOneDetent(cw: true, startUs: 0);
        await pumpEventQueue();

        expect(detents, [1]);
        await sub.cancel();
      });

      test('a counter-clockwise detent emits -1 on rotation', () async {
        build();
        final detents = <int>[];
        final sub = source.rotation.listen(detents.add);

        turnOneDetent(cw: false, startUs: 0);
        await pumpEventQueue();

        expect(detents, [-1]);
        await sub.cancel();
      });

      test('successive detents accumulate in the turned direction', () async {
        build();
        final detents = <int>[];
        final sub = source.rotation.listen(detents.add);

        turnOneDetent(cw: true, startUs: 0);
        turnOneDetent(cw: true, startUs: 100000);
        turnOneDetent(cw: false, startUs: 200000);
        turnOneDetent(cw: false, startUs: 300000);
        await pumpEventQueue();

        expect(detents, [1, 1, -1, -1]);
        await sub.cancel();
      });

      test(
        'a partial detent reversed before completing emits nothing',
        () async {
          build();
          final detents = <int>[];
          final sub = source.rotation.listen(detents.add);

          // Two CW sub-steps, then two CCW sub-steps back to idle: never four in
          // one direction, so no detent.
          source
            ..pushForTest(encoderA, 0) // CW +1
            ..pushForTest(encoderB, 0, tsUs: 5000) // CW +1
            ..pushForTest(encoderB, 1, tsUs: 10000) // CCW -1
            ..pushForTest(encoderA, 1, tsUs: 15000); // CCW -1
          await pumpEventQueue();

          expect(detents, isEmpty);
          await sub.cancel();
        },
      );

      test(
        'a redundant same-level edge is an invalid no-op transition',
        () async {
          build();
          final detents = <int>[];
          final sub = source.rotation.listen(detents.add);

          // Only the first edge is a real sub-step; the repeats land on a zero
          // entry of the transition table, so they never build toward a detent.
          for (var t = 0; t <= 15000; t += 5000) {
            source.pushForTest(encoderA, 0, tsUs: t);
          }
          await pumpEventQueue();

          expect(detents, isEmpty);
          await sub.cancel();
        },
      );
    });

    group('rotation is reserved (not a press)', () {
      test('encoder A/B edges never reach inputs or activity', () async {
        build();
        final inputs = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final inputSub = source.inputs.listen(inputs.add);
        final activitySub = source.activity.listen(activity.add);

        turnOneDetent(cw: true, startUs: 0);
        await pumpEventQueue();

        expect(inputs, isEmpty);
        expect(activity, isEmpty);
        await inputSub.cancel();
        await activitySub.cancel();
      });

      test(
        'a normal press line still emits while the encoder decodes',
        () async {
          build();
          final inputs = <RawControllerInput>[];
          final sub = source.inputs.listen(inputs.add);

          source.pushForTest(footswitch, 0);
          turnOneDetent(cw: true, startUs: 10000);
          await pumpEventQueue();

          expect(inputs, const [
            RawControllerInput(
              kind: ControllerSourceKind.gpio,
              id: footswitch,
              value: 1,
            ),
          ]);
          await sub.cancel();
        },
      );
    });

    group('sanity gate', () {
      test(
        'a sub-floor edge storm on a pin collapses to at most one input',
        () async {
          build();
          final inputs = <RawControllerInput>[];
          final sub = source.inputs.listen(inputs.add);

          // 200 edges 200µs apart (all under the 1 ms floor): a floating-pin
          // storm never settles, so only the first edge passes — the rest are
          // noise. Exactly one (not zero: the first is always valid).
          for (var i = 0; i < 200; i++) {
            source.pushForTest(footswitch, i.isEven ? 0 : 1, tsUs: i * 200);
          }
          await pumpEventQueue();

          expect(inputs.length, 1);
          await sub.cancel();
        },
      );

      test('a mixed A/B sub-floor storm fabricates no detent', () async {
        build();
        final detents = <int>[];
        final inputs = <RawControllerInput>[];
        final rotationSub = source.rotation.listen(detents.add);
        final inputSub = source.inputs.listen(inputs.add);

        // Alternating A/B noise 100µs apart — the realistic floating-encoder
        // failure. Per-pin keying must gate each pin independently.
        for (var i = 0; i < 100; i++) {
          source.pushForTest(
            i.isEven ? encoderA : encoderB,
            i.isEven ? 0 : 1,
            tsUs: i * 100,
          );
        }
        await pumpEventQueue();

        expect(detents, isEmpty);
        expect(inputs, isEmpty, reason: 'encoder pins are never presses');
        await rotationSub.cancel();
        await inputSub.cancel();
      });

      test('edges spaced past the floor are accepted', () async {
        build();
        final activity = <RawControllerInput>[];
        final sub = source.activity.listen(activity.add);

        // Two edges 2 ms apart (above the 1 ms floor) both pass the gate; the
        // activity tap reflects raw accepted edges (pre-debounce).
        source
          ..pushForTest(footswitch, 0)
          ..pushForTest(footswitch, 1, tsUs: 2000);
        await pumpEventQueue();

        expect(activity.length, 2);
        await sub.cancel();
      });

      test('the gate also protects the quadrature decode', () async {
        build();
        final detents = <int>[];
        final sub = source.rotation.listen(detents.add);

        // A burst of sub-floor A-pin noise must not advance the decoder enough
        // to fabricate a detent.
        for (var i = 0; i < 50; i++) {
          source.pushForTest(encoderA, i.isEven ? 0 : 1, tsUs: i * 100);
        }
        await pumpEventQueue();

        expect(detents, isEmpty);
        await sub.cancel();
      });
    });

    group('dispose', () {
      test('closes the rotation stream', () async {
        build();
        await source.dispose();
        await expectLater(source.rotation, emitsDone);
      });

      test('an encoder edge after dispose emits no detent', () async {
        build();
        final detents = <int>[];
        final sub = source.rotation.listen(detents.add);
        await source.dispose();

        turnOneDetent(cw: true, startUs: 0);
        await pumpEventQueue();

        expect(detents, isEmpty);
        await sub.cancel();
      });
    });
  });
}

const int encoderA = 5;
const int encoderB = 6;
