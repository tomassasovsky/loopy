import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

void main() {
  group('MidiDevice', () {
    test('defaults isDefault to false', () {
      const device = MidiDevice(id: 'abc', name: 'Pedal');
      expect(device.isDefault, isFalse);
    });

    test('value equality and hashCode', () {
      const a = MidiDevice(id: 'abc', name: 'Pedal', isDefault: true);
      const b = MidiDevice(id: 'abc', name: 'Pedal', isDefault: true);
      const c = MidiDevice(id: 'xyz', name: 'Pedal', isDefault: true);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('toString includes the fields', () {
      const device = MidiDevice(id: 'abc', name: 'Pedal');
      expect(
        device.toString(),
        'MidiDevice(id: abc, name: Pedal, isDefault: false)',
      );
    });
  });
}
