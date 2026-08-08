import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/tuner/pitch.dart';

void main() {
  group('pitchFromHz', () {
    test('reproduces the design mockup, which is what pins A=440', () {
      // `TUNER / tuner-mic` reads "E · −9 cents · 163.9 Hz", and that pair is
      // self-consistent only at A=440 — which is how the reference is knowable
      // with no control drawn on either screen. E3 is 164.81 Hz here, and the
      // band of frequencies that both PRINT as 163.9 and ROUND to −9 cents is
      // real but narrow (the two roundings only just overlap), so the check is
      // that a reading inside it produces exactly what the mockup shows.
      const reading = 163.94;
      expect(reading.toStringAsFixed(1), '163.9');

      final e = pitchFromHz(reading);
      expect(e, isNotNull);
      expect(e!.note, 'E');
      expect(e.octave, 3);
      expect(e.cents.round(), -9);
    });

    test('the reference itself reads dead-on', () {
      final a = pitchFromHz(440);
      expect(a!.note, 'A');
      expect(a.octave, 4);
      expect(a.cents, closeTo(0, 1e-9));
      expect(a.isInTune, isTrue);
    });

    test('+4 cents of A4 is 441.0 Hz, not the 442.1 the mockup prints', () {
      // The guitar screen reads "A · +4 cents · 442.1 Hz", which cannot both be
      // true: 442.1 Hz is +8 cents. Pinned here so the defect is caught by the
      // suite rather than only by eye, and so fixing the pen does not silently
      // change what the app computes.
      expect(pitchFromHz(441)!.cents, closeTo(4, 0.2));
      expect(pitchFromHz(442.1)!.cents, closeTo(8, 0.3));
    });

    test('spans the instrument range the engine detects', () {
      // Bass low B through a guitar's high E — the same band the native
      // detector is tested over.
      final lowB = pitchFromHz(30.87);
      expect(lowB!.note, 'B');
      expect(lowB.octave, 0);
      expect(lowB.cents, closeTo(0, 1));

      final lowE = pitchFromHz(41.20);
      expect(lowE!.note, 'E');
      expect(lowE.octave, 1);

      final highE = pitchFromHz(329.63);
      expect(highE!.note, 'E');
      expect(highE.octave, 4);
      expect(highE.cents, closeTo(0, 1));
    });

    test('names accidentals with a real sharp, never an ASCII hash', () {
      final fSharp = pitchFromHz(369.99); // F♯4
      expect(fSharp!.note, 'F♯');
      expect(fSharp.note.contains('#'), isFalse);
    });

    test('cents stay within half a semitone either side', () {
      // Every frequency across two octaves lands on SOME note no more than 50
      // cents away — the rounding never leaves a gap or double-counts an edge.
      for (var hz = 80.0; hz < 320.0; hz += 0.37) {
        final p = pitchFromHz(hz);
        expect(p, isNotNull);
        expect(p!.cents.abs(), lessThanOrEqualTo(50));
      }
    });

    test('a note exactly between two reads as half a semitone from one', () {
      // The quarter-tone above A4: 50 cents. Whichever neighbour it rounds to,
      // the magnitude is 50 — what must not happen is a wrapped or zero value.
      final quarter = pitchFromHz(440 * 1.0293022366); // +50 cents
      expect(quarter!.cents.abs(), closeTo(50, 0.5));
    });

    test('no pitch is null, not a note at zero cents', () {
      expect(pitchFromHz(0), isNull);
      expect(pitchFromHz(-1), isNull);
    });

    test('is exact against its own inverse across the range', () {
      // Round-tripping catches a sign slip or an off-by-one octave that a
      // hand-picked table would miss.
      for (var midi = 24; midi <= 84; midi++) {
        final hz = 440 * math.pow(2, (midi - 69) / 12).toDouble();
        final p = pitchFromHz(hz);
        expect(p!.cents, closeTo(0, 1e-6), reason: 'midi $midi');
        expect(p.octave, (midi ~/ 12) - 1, reason: 'midi $midi');
      }
    });
  });
}
