import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The learn-hygiene predicate (B8), stated against the real wire tables so it
/// cannot drift from the protocol the firmware speaks.
void main() {
  RawControllerInput note(int id, {int channel = 0}) => RawControllerInput(
    kind: ControllerSourceKind.midiNote,
    id: id,
    value: 127,
    midiChannel: channel,
  );
  RawControllerInput cc(int id, {int channel = 0}) => RawControllerInput(
    kind: ControllerSourceKind.midiCc,
    id: id,
    value: 64,
    midiChannel: channel,
  );

  group('isPedalProtocolInput', () {
    test('claims every footswitch note the pedal transmits', () {
      for (final button in PedalButton.values) {
        expect(
          isPedalProtocolInput(note(button.note)),
          isTrue,
          reason: '${button.name} (note ${button.note}) is pedal traffic',
        );
      }
    });

    test('claims the relative encoder CC', () {
      expect(isPedalProtocolInput(cc(PedalCodec.encoderCc)), isTrue);
    });

    test('leaves a third-party controller alone', () {
      expect(isPedalProtocolInput(note(PedalButton.values.length)), isFalse);
      expect(isPedalProtocolInput(note(60)), isFalse);
      expect(isPedalProtocolInput(cc(PedalCodec.encoderCc + 1)), isFalse);
      expect(isPedalProtocolInput(cc(11)), isFalse);
    });

    test('is channel-agnostic — wrong on one channel is wrong on all', () {
      expect(
        isPedalProtocolInput(cc(PedalCodec.encoderCc, channel: 9)),
        isTrue,
      );
      expect(
        isPedalProtocolInput(note(PedalButton.stop.note, channel: 15)),
        isTrue,
      );
    });
  });
}
