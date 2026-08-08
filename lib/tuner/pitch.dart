import 'dart:math' as math;

/// A frequency expressed the way a tuner shows it: the nearest chromatic note,
/// and how far off it is.
class TunedPitch {
  /// Creates a [TunedPitch].
  const TunedPitch({
    required this.note,
    required this.octave,
    required this.cents,
  });

  /// The nearest note's name, sharps only — `C`, `C♯`, `D`, …
  ///
  /// Sharps rather than flats because a chromatic tuner has no key to decide
  /// between them, and a display that guessed would be wrong half the time.
  final String note;

  /// Scientific pitch octave, where A4 is 440 Hz. Not drawn on the face — a
  /// tuner shows the letter alone — but carried so a caller can tell E2 from
  /// E4 without re-deriving it.
  final int octave;

  /// Cents from the nearest note, in `(-50, 50]`. Negative is flat.
  final double cents;

  /// Whether this reads as in tune. Three cents is about the limit of what a
  /// player can hear on a sustained note, and a tighter window makes the
  /// needle impossible to satisfy on a real instrument.
  bool get isInTune => cents.abs() <= 3;
}

/// Note names, index 0 = C, sharps only. U+266F, not an ASCII `#`.
const List<String> _names = [
  'C',
  'C♯',
  'D',
  'D♯',
  'E',
  'F',
  'F♯',
  'G',
  'G♯',
  'A',
  'A♯',
  'B',
];

/// Concert A. Fixed: neither `TUNER / tuner` nor `TUNER / tuner-mic` draws a
/// reference-pitch control, and `tuner-mic`'s own numbers only resolve at 440
/// (E3 = 164.81 Hz, and −9 cents of it is the 163.9 Hz the screen shows).
const double kReferenceHz = 440;

/// MIDI note number of A4, the anchor the semitone count is measured from.
const int _a4Midi = 69;

/// Converts [hz] to its nearest chromatic note and the cents away from it.
///
/// Returns `null` for a non-positive frequency — "no pitch" is a state the
/// caller has to render differently, not a note at zero cents.
///
/// The maths is the standard equal-tempered pair: the nearest semitone is
/// `round(12·log2(f / 440))` from A4, and the error is
/// `1200·log2(f / f_nearest)` cents. Both are exact inverses of each other, so
/// a note dead on pitch reads zero rather than a rounding crumb.
TunedPitch? pitchFromHz(double hz, {double reference = kReferenceHz}) {
  if (hz <= 0 || reference <= 0) return null;

  final semitones = 12 * (math.log(hz / reference) / math.ln2);
  final nearest = semitones.roundToDouble();
  final midi = _a4Midi + nearest.toInt();

  final exactHz = reference * math.pow(2, nearest / 12);
  final cents = 1200 * (math.log(hz / exactHz) / math.ln2);

  // Floor division, so notes below C0 still index the table from the correct
  // end rather than wrapping negative.
  final index = midi % 12;
  final octave = (midi ~/ 12) - 1;

  return TunedPitch(note: _names[index], octave: octave, cents: cents);
}
