import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

void main() {
  group('midiDeviceNameMatches', () {
    test('matches the bare product string (CoreMIDI reports it verbatim)', () {
      expect(
        midiDeviceNameMatches('VAMP Loopstation', 'VAMP Loopstation'),
        isTrue,
      );
    });

    test('matches an ALSA-decorated port label', () {
      // The console's backend appends the port, so equality would never hit.
      expect(
        midiDeviceNameMatches('VAMP Loopstation MIDI 1', 'VAMP Loopstation'),
        isTrue,
      );
      expect(
        midiDeviceNameMatches(
          'VAMP Loopstation:VAMP Loopstation MIDI 1 20:0',
          'VAMP Loopstation',
        ),
        isTrue,
      );
    });

    test('is case-insensitive on both sides', () {
      expect(
        midiDeviceNameMatches('vamp loopstation midi 1', 'VAMP Loopstation'),
        isTrue,
      );
      expect(
        midiDeviceNameMatches('VAMP LOOPSTATION', 'vamp loopstation'),
        isTrue,
      );
    });

    test('ignores surrounding whitespace on the product string', () {
      expect(
        midiDeviceNameMatches('VAMP Loopstation', '  VAMP Loopstation  '),
        isTrue,
      );
    });

    test('does not match an unrelated device', () {
      expect(
        midiDeviceNameMatches('Arduino Leonardo', 'VAMP Loopstation'),
        isFalse,
      );
      expect(
        midiDeviceNameMatches('Launchpad Mini', 'VAMP Loopstation'),
        isFalse,
      );
    });

    test('does not match the pre-rename firmware label', () {
      // A Pro Micro flashed before build.usb_product was set enumerates as the
      // stock board name — the accepted cost of matching by name only.
      expect(
        midiDeviceNameMatches('Arduino Leonardo', 'VAMP Loopstation'),
        isFalse,
      );
    });

    test('an empty product string matches nothing, not everything', () {
      // contains('') is true for every string; auto-bind must never adopt an
      // arbitrary device because no product name was configured.
      expect(midiDeviceNameMatches('VAMP Loopstation', ''), isFalse);
      expect(midiDeviceNameMatches('anything at all', '   '), isFalse);
      expect(midiDeviceNameMatches('', ''), isFalse);
    });

    test('an empty device name matches nothing', () {
      expect(midiDeviceNameMatches('', 'VAMP Loopstation'), isFalse);
    });
  });
}
