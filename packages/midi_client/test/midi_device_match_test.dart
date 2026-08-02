import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

void main() {
  group('midiDeviceNameMatches', () {
    const names = ['VAMP Loopstation'];

    test('matches the bare product string (CoreMIDI reports it verbatim)', () {
      expect(midiDeviceNameMatches('VAMP Loopstation', names), isTrue);
    });

    test('matches an ALSA-decorated port label', () {
      // The console's backend appends the port, so equality would never hit.
      expect(midiDeviceNameMatches('VAMP Loopstation MIDI 1', names), isTrue);
      expect(
        midiDeviceNameMatches(
          'VAMP Loopstation:VAMP Loopstation MIDI 1 20:0',
          names,
        ),
        isTrue,
      );
    });

    test('is case-insensitive on both sides', () {
      expect(midiDeviceNameMatches('vamp loopstation midi 1', names), isTrue);
      expect(
        midiDeviceNameMatches('VAMP LOOPSTATION', const ['vamp loopstation']),
        isTrue,
      );
    });

    test('ignores surrounding whitespace on the product string', () {
      expect(
        midiDeviceNameMatches('VAMP Loopstation', const [
          '  VAMP Loopstation  ',
        ]),
        isTrue,
      );
    });

    test('does not match an unrelated device', () {
      expect(midiDeviceNameMatches('Launchpad Mini', names), isFalse);
    });

    test('does not match the pre-rename firmware label', () {
      // A Pro Micro flashed before build.usb_product was set enumerates as the
      // stock board name — the accepted cost of matching by name only.
      expect(midiDeviceNameMatches('Arduino Leonardo', names), isFalse);
    });

    group('multiple names', () {
      // A product rename ships new firmware, but pedals already in the field
      // keep advertising the old string until someone reflashes them.
      const both = ['Segno', 'VAMP Loopstation'];

      test('matches a device advertising any name in the list', () {
        expect(midiDeviceNameMatches('Segno MIDI 1', both), isTrue);
        expect(midiDeviceNameMatches('VAMP Loopstation MIDI 1', both), isTrue);
      });

      test('still rejects a device matching none of them', () {
        expect(midiDeviceNameMatches('Launchpad Mini', both), isFalse);
      });

      test('a blank entry does not turn into a match-everything', () {
        // contains('') is true for every string, so one stray empty entry
        // would otherwise adopt an arbitrary device off the bus.
        expect(
          midiDeviceNameMatches('Launchpad Mini', const [
            '',
            'VAMP Loopstation',
          ]),
          isFalse,
        );
        expect(
          midiDeviceNameMatches('Launchpad Mini', const ['   ']),
          isFalse,
        );
      });
    });

    test('an empty list matches nothing', () {
      expect(midiDeviceNameMatches('VAMP Loopstation', const []), isFalse);
    });

    test('an empty device name matches nothing', () {
      expect(midiDeviceNameMatches('', names), isFalse);
    });
  });
}
