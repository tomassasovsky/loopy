import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

import 'helpers/fake_loopy_engine_bindings.dart';

/// MIDI status bytes (channel 0) used across the cases.
const int _noteOn = 0x90;
const int _noteOff = 0x80;
const int _cc = 0xB0;

void main() {
  group('MidiControllerSource', () {
    late FakeLoopyEngineBindings bindings;
    late MidiControllerSource source;

    MidiControllerSource build({
      Duration debounce = const Duration(milliseconds: 30),
      List<MidiDevice> devices = const [],
      int openResult = 0,
    }) {
      bindings = FakeLoopyEngineBindings(
        devices: devices,
        openResult: openResult,
      );
      source = MidiControllerSource(
        client: MidiClient(bindings: bindings),
        debounce: debounce,
      );
      addTearDown(source.dispose);
      return source;
    }

    group('parsing', () {
      test('Control Change -> midiCc with value', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_cc, 80, 127);
        await pumpEventQueue();

        expect(received, const [
          RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 80,
            value: 127,
          ),
        ]);
        expect(received.single.isPress, isTrue);
        await sub.cancel();
      });

      test('Note On -> midiNote with velocity', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOn, 60, 100);
        await pumpEventQueue();

        expect(received, const [
          RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            value: 100,
          ),
        ]);
        await sub.cancel();
      });

      test('Note On with velocity 0 maps to a release (value 0)', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOn, 60, 0);
        await pumpEventQueue();

        expect(received.single.value, 0);
        expect(received.single.isPress, isFalse);
        await sub.cancel();
      });

      test('Note Off maps to value 0', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOff, 60, 64);
        await pumpEventQueue();

        expect(received.single.value, 0);
        await sub.cancel();
      });

      test('ignores channel in the status low nibble', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        // CC on channel 9 (0xB9) still maps to the same trigger.
        source.pushForTest(0xB9, 80, 127);
        await pumpEventQueue();

        expect(received.single.id, 80);
        expect(received.single.kind, ControllerSourceKind.midiCc);
        await sub.cancel();
      });

      test('drops SysEx / real-time / aftertouch / pitch bend', () async {
        build();
        final received = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final inputSub = source.inputs.listen(received.add);
        final activitySub = source.activity.listen(activity.add);

        source
          ..pushForTest(0xF0, 0, 0) // SysEx start
          ..pushForTest(0xF8, 0, 0) // timing clock
          ..pushForTest(0xFE, 0, 0) // active sensing
          ..pushForTest(0xA0, 60, 10) // polyphonic aftertouch
          ..pushForTest(0xE0, 0, 64) // pitch bend
          ..pushForTest(0xC0, 5, 0); // program change
        await pumpEventQueue();

        expect(received, isEmpty);
        expect(activity, isEmpty);
        await inputSub.cancel();
        await activitySub.cancel();
      });
    });

    group('debounce', () {
      test('collapses sub-window repeats of the same trigger', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source
          ..pushForTest(_cc, 80, 127) // emit (tsUs 0)
          ..pushForTest(_cc, 80, 127, tsUs: 10000) // +10ms -> suppressed
          ..pushForTest(_cc, 80, 0, tsUs: 20000) // +20ms -> suppressed
          ..pushForTest(_cc, 80, 127, tsUs: 40000); // +40ms -> emit
        await pumpEventQueue();

        expect(received.map((e) => e.value), [127, 127]);
        await sub.cancel();
      });

      test('debounces each trigger independently', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source
          ..pushForTest(_cc, 80, 127) // CC80 emit (tsUs 0)
          ..pushForTest(_cc, 81, 127, tsUs: 5000) // CC81 emit (other trigger)
          ..pushForTest(_cc, 80, 127, tsUs: 10000); // CC80 +10ms -> suppressed
        await pumpEventQueue();

        expect(received.map((e) => e.id), [80, 81]);
        await sub.cancel();
      });

      test('leading-edge: a continuous bounce cannot keep resetting', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        // Five messages 10ms apart: the window is measured from the first
        // *emit* (t=0), so t=40ms passes despite the steady stream between.
        for (var t = 0; t <= 40000; t += 10000) {
          source.pushForTest(_cc, 80, 127, tsUs: t);
        }
        await pumpEventQueue();

        expect(received.length, 2); // t=0 and t=40000
        await sub.cancel();
      });
    });

    group('activity tap', () {
      test('blinks on every recognized message, even debounced ones', () async {
        build();
        final inputs = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final inputSub = source.inputs.listen(inputs.add);
        final activitySub = source.activity.listen(activity.add);

        source
          ..pushForTest(_cc, 80, 127) // tsUs 0
          ..pushForTest(_cc, 80, 127, tsUs: 10000); // debounced out of inputs
        await pumpEventQueue();

        expect(inputs.length, 1, reason: 'second is debounced');
        expect(activity.length, 2, reason: 'activity is the raw pre-map tap');
        await inputSub.cancel();
        await activitySub.cancel();
      });
    });

    group('device control', () {
      test('enumerate delegates to the client', () {
        build(
          devices: const [MidiDevice(id: 'uid-1', name: 'Pedal')],
        );
        expect(source.enumerate(), const [
          MidiDevice(id: 'uid-1', name: 'Pedal'),
        ]);
      });

      test('open passes the id and the listener callback to native', () {
        build();
        final result = source.open('uid-1');

        expect(result, 0);
        expect(bindings.lastOpenedId, 'uid-1');
        expect(bindings.lastOpenedCb, isNotNull);
        expect(bindings.calls, contains('open'));
      });

      test('open surfaces the native failure code', () {
        build(openResult: 3);
        expect(source.open('busy'), 3);
      });

      test('close delegates to the client', () {
        build();
        expect(source.close(), 0);
        expect(bindings.calls, contains('close'));
      });
    });

    group('dispose', () {
      test(
        'closes native before destroying, then releases the callable',
        () async {
          build();
          source.open('uid-1');
          expect(source.isDisposed, isFalse);

          await source.dispose();

          expect(source.isDisposed, isTrue);
          // le_midi_close must precede le_midi_destroy so the native side can
          // never call a freed callback (the NativeCallable is closed last).
          final closeIndex = bindings.calls.indexOf('close');
          final destroyIndex = bindings.calls.indexOf('destroy');
          expect(closeIndex, greaterThanOrEqualTo(0));
          expect(destroyIndex, greaterThan(closeIndex));
        },
      );

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
          bindings.calls.where((c) => c == 'destroy').length,
          1,
        );
      });

      test('a message after dispose emits nothing', () async {
        build();
        final received = <RawControllerInput>[];
        // Subscribe before dispose; the stream then closes.
        final sub = source.inputs.listen(received.add);
        await source.dispose();

        // Pushing post-dispose must be a safe no-op (no add to a closed sink).
        source.pushForTest(_cc, 80, 127);
        await pumpEventQueue();

        expect(received, isEmpty);
        await sub.cancel();
      });
    });
  });
}
