import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine_ffi.dart';
import 'package:midi_client/midi_client.dart';

import 'helpers/fake_loopy_engine_bindings.dart';

/// A dummy native callback pointer; the fake records it but never invokes it.
final le_midi_event_cb _dummyCb =
    Pointer<NativeFunction<le_midi_event_cbFunction>>.fromAddress(0xABCD);

void main() {
  group('MidiClient', () {
    test('throws when the native handle cannot be allocated', () {
      final bindings = FakeLoopyEngineBindings(createReturnsNull: true);
      expect(
        () => MidiClient(bindings: bindings),
        throwsA(isA<MidiException>()),
      );
    });

    test('allocates a handle on construction', () {
      final bindings = FakeLoopyEngineBindings();
      final client = MidiClient(bindings: bindings)..dispose();
      expect(bindings.calls, ['create', 'destroy']);
      expect(client.isDisposed, isTrue);
    });

    group('enumerate', () {
      test('projects native ports into MidiDevices', () {
        final bindings = FakeLoopyEngineBindings(
          devices: const [
            MidiDevice(id: 'uid-1', name: 'Foot Controller', isDefault: true),
            MidiDevice(id: 'uid-2', name: 'Keystep'),
          ],
        );
        final client = MidiClient(bindings: bindings);
        addTearDown(client.dispose);

        expect(client.enumerate(), const [
          MidiDevice(id: 'uid-1', name: 'Foot Controller', isDefault: true),
          MidiDevice(id: 'uid-2', name: 'Keystep'),
        ]);
      });

      test('returns an empty list when there are no ports', () {
        final client = MidiClient(bindings: FakeLoopyEngineBindings());
        addTearDown(client.dispose);
        expect(client.enumerate(), isEmpty);
      });
    });

    group('open', () {
      test('passes the id and callback through and returns the code', () {
        final bindings = FakeLoopyEngineBindings();
        final client = MidiClient(bindings: bindings);
        addTearDown(client.dispose);

        final result = client.open('uid-2', _dummyCb);

        expect(result, 0);
        expect(bindings.lastOpenedId, 'uid-2');
        expect(bindings.lastOpenedCb, _dummyCb);
        expect(bindings.calls, ['create', 'open']);
      });

      test('surfaces a non-zero failure code (e.g. device in use)', () {
        final bindings = FakeLoopyEngineBindings(openResult: 3);
        final client = MidiClient(bindings: bindings);
        addTearDown(client.dispose);

        expect(client.open('missing', _dummyCb), 3);
      });
    });

    test('close delegates to the native handle', () {
      final bindings = FakeLoopyEngineBindings();
      final client = MidiClient(bindings: bindings);
      addTearDown(client.dispose);

      expect(client.close(), 0);
      expect(bindings.calls, ['create', 'close']);
    });

    test('dispose is idempotent', () {
      final bindings = FakeLoopyEngineBindings();
      MidiClient(bindings: bindings)
        ..dispose()
        ..dispose();
      expect(bindings.calls.where((c) => c == 'destroy').length, 1);
    });

    test('throws after dispose', () {
      final client = MidiClient(bindings: FakeLoopyEngineBindings())..dispose();
      expect(client.enumerate, throwsA(isA<MidiException>()));
      expect(client.close, throwsA(isA<MidiException>()));
    });
  });

  group('MidiException', () {
    test('toString carries the message', () {
      expect(
        const MidiException('boom').toString(),
        'MidiException: boom',
      );
    });
  });
}
