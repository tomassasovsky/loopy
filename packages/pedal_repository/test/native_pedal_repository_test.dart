import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/fake_pedal_transport.dart';

class _MockMidiSource extends Mock implements MidiControllerSource {}

void main() {
  group('createNativePedalRepository', () {
    test('returns null when there is no MIDI source', () {
      expect(createNativePedalRepository(null), isNull);
    });

    test('builds a repository over the injected transport', () {
      final source = _MockMidiSource();
      when(() => source.activity).thenAnswer(
        (_) => const Stream<RawControllerInput>.empty(),
      );
      final transport = FakePedalTransport();

      final repository = createNativePedalRepository(
        source,
        transportFactory: (_) => transport,
      );

      expect(repository, isNotNull);
    });

    test('adapts MIDI source activity into raw pedal messages', () async {
      final source = _MockMidiSource();
      final activity = StreamController<RawControllerInput>.broadcast();
      when(() => source.activity).thenAnswer((_) => activity.stream);

      late Stream<PedalRawMessage> captured;
      createNativePedalRepository(
        source,
        transportFactory: (input) {
          captured = input;
          return FakePedalTransport();
        },
      );

      final received = <PedalRawMessage>[];
      final sub = captured.listen(received.add);
      addTearDown(sub.cancel);
      addTearDown(activity.close);

      activity
        ..add(
          const RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            value: 100,
          ),
        )
        ..add(
          const RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            value: 0,
          ),
        )
        ..add(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 7,
            value: 64,
          ),
        );
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        (status: 0x90, data1: 60, data2: 100),
        (status: 0x80, data1: 60, data2: 0),
        (status: 0xB0, data1: 7, data2: 64),
      ]);
    });
  });
}
