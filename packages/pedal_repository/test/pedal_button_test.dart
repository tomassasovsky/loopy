import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalButtonNote', () {
    test('every button round-trips through its note number', () {
      for (final button in PedalButton.values) {
        expect(PedalButtonNote.fromNote(button.note), button);
      }
    });

    test('notes are unique and contiguous from 0', () {
      final notes = PedalButton.values.map((b) => b.note).toList();
      expect(notes, List<int>.generate(PedalButton.values.length, (i) => i));
      expect(notes.toSet().length, notes.length);
    });

    test('fromNote returns null for an unassigned note', () {
      expect(PedalButtonNote.fromNote(PedalButton.values.length), isNull);
      expect(PedalButtonNote.fromNote(127), isNull);
    });

    test('fromNote returns null for a negative note', () {
      expect(PedalButtonNote.fromNote(-1), isNull);
    });

    test('the contract numbering is stable', () {
      // Guards against an accidental reorder of the enum, which would break the
      // firmware contract.
      expect(PedalButton.recPlay.note, 0);
      expect(PedalButton.stop.note, 1);
      expect(PedalButton.undo.note, 2);
      expect(PedalButton.mode.note, 3);
      expect(PedalButton.track1.note, 4);
      expect(PedalButton.track2.note, 5);
      expect(PedalButton.track3.note, 6);
      expect(PedalButton.track4.note, 7);
      expect(PedalButton.clear.note, 8);
      expect(PedalButton.bank.note, 9);
    });
  });
}
