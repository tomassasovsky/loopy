import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

import 'helpers/fake_loopy_engine_bindings.dart';

void main() {
  group('MidiOutClient', () {
    test('throws when the native handle cannot be allocated', () {
      final bindings = FakeLoopyEngineBindings(outCreateReturnsNull: true);
      expect(
        () => MidiOutClient(bindings: bindings),
        throwsA(isA<MidiException>()),
      );
    });

    test('create allocates the native output handle', () {
      final bindings = FakeLoopyEngineBindings();
      MidiOutClient(bindings: bindings);
      expect(bindings.calls, contains('out_create'));
    });

    group('enumerate', () {
      test('maps native output ports to MidiDevices', () {
        final bindings = FakeLoopyEngineBindings(
          outDevices: const [
            MidiDevice(id: 'out-1', name: 'Pedal Out'),
            MidiDevice(id: 'out-2', name: 'Synth', isDefault: true),
          ],
        );
        final client = MidiOutClient(bindings: bindings);

        final devices = client.enumerate();

        expect(devices, hasLength(2));
        expect(devices[0], const MidiDevice(id: 'out-1', name: 'Pedal Out'));
        expect(
          devices[1],
          const MidiDevice(id: 'out-2', name: 'Synth', isDefault: true),
        );
      });

      test('returns an empty list when there are no output ports', () {
        final client = MidiOutClient(bindings: FakeLoopyEngineBindings());
        expect(client.enumerate(), isEmpty);
      });
    });

    group('open', () {
      test('passes the id through and returns the native code', () {
        final bindings = FakeLoopyEngineBindings();
        final client = MidiOutClient(bindings: bindings);

        final code = client.open('out-1');

        expect(code, 0);
        expect(bindings.calls, contains('out_open'));
        expect(bindings.lastOutOpenedId, 'out-1');
      });

      test('surfaces a non-zero native failure code', () {
        final bindings = FakeLoopyEngineBindings(outOpenResult: 2);
        final client = MidiOutClient(bindings: bindings);
        expect(client.open('missing'), 2);
      });
    });

    group('send', () {
      test('forwards the bytes verbatim and returns the native code', () {
        final bindings = FakeLoopyEngineBindings();
        final client = MidiOutClient(bindings: bindings);

        final code = client.send(Uint8List.fromList([0xF0, 0x7D, 0x01, 0xF7]));

        expect(code, 0);
        expect(bindings.sent, hasLength(1));
        expect(bindings.sent.single, [0xF0, 0x7D, 0x01, 0xF7]);
      });

      test('is a no-op for an empty payload', () {
        final bindings = FakeLoopyEngineBindings();
        final client = MidiOutClient(bindings: bindings);

        expect(client.send(Uint8List(0)), 0);
        expect(bindings.calls, isNot(contains('out_send')));
      });

      test('surfaces a non-zero native failure code', () {
        final bindings = FakeLoopyEngineBindings(sendResult: 5);
        final client = MidiOutClient(bindings: bindings);
        expect(client.send(Uint8List.fromList([0xFA])), 5);
      });
    });

    group('dispose', () {
      test('frees the native handle exactly once', () {
        final bindings = FakeLoopyEngineBindings();
        final client = MidiOutClient(bindings: bindings)
          ..dispose()
          ..dispose();

        expect(client.isDisposed, isTrue);
        expect(
          bindings.calls.where((c) => c == 'out_destroy'),
          hasLength(1),
        );
      });

      test('rejects use after dispose', () {
        final client = MidiOutClient(bindings: FakeLoopyEngineBindings())
          ..dispose();
        expect(client.enumerate, throwsA(isA<MidiException>()));
        expect(() => client.open('x'), throwsA(isA<MidiException>()));
        expect(
          () => client.send(Uint8List.fromList([0xFA])),
          throwsA(isA<MidiException>()),
        );
      });
    });
  });
}
