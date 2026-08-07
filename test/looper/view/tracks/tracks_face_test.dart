import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/tracks/tracks_face.dart';

/// The three comparators the Tracks faces gate their `buildWhen` on.
///
/// Unit-tested directly rather than only through the faces: they are the whole
/// defence against rebuilding at the meter rate, and a widget test that seeds
/// one state and never emits a second never runs them at all.
void main() {
  /// Two tracks that differ ONLY in their live meters — the change that
  /// arrives many times a second and must NOT rebuild a face.
  const quiet = Track(lanes: [Lane(inputChannel: 0)]);
  const loud = Track(
    rms: 0.8,
    peak: 0.9,
    playheadFrames: 4096,
    lanes: [Lane(inputChannel: 0, rms: 0.8, peak: 0.9)],
  );

  group('sameRouting', () {
    test('ignores meters, playheads and lane levels', () {
      expect(sameRouting(const [quiet], const [loud]), isTrue);
    });

    test('catches a lane changing what it records', () {
      expect(
        sameRouting(
          const [quiet],
          const [
            Track(lanes: [Lane(inputChannel: 1)]),
          ],
        ),
        isFalse,
      );
    });

    test('catches a lane changing where it goes', () {
      expect(
        sameRouting(
          const [quiet],
          const [
            Track(lanes: [Lane(inputChannel: 0, outputMask: 0x7)]),
          ],
        ),
        isFalse,
      );
    });

    test('catches a track gaining a lane', () {
      expect(
        sameRouting(
          const [quiet],
          const [
            Track(lanes: [Lane(inputChannel: 0), Lane()]),
          ],
        ),
        isFalse,
      );
    });

    test('catches the roster growing or shrinking', () {
      expect(sameRouting(const [quiet], const [quiet, quiet]), isFalse);
      expect(sameRouting(const [], const [quiet]), isFalse);
    });
  });

  group('sameLengths', () {
    test('ignores meters', () {
      expect(sameLengths(const [quiet], const [loud]), isTrue);
    });

    test('catches a preset change', () {
      expect(
        sameLengths(const [quiet], const [Track(lengthPresetBars: 8)]),
        isFalse,
      );
    });

    test('catches the roster changing', () {
      expect(sameLengths(const [quiet], const [quiet, quiet]), isFalse);
    });
  });

  group('sameQuantize', () {
    test('ignores meters', () {
      expect(sameQuantize(const [quiet], const [loud]), isTrue);
    });

    test('tells all three states apart', () {
      const follow = Track();
      const always = Track(quantizeOverride: true);
      const never = Track(quantizeOverride: false);
      expect(sameQuantize(const [follow], const [always]), isFalse);
      expect(sameQuantize(const [always], const [never]), isFalse);
      expect(sameQuantize(const [never], const [follow]), isFalse);
      expect(sameQuantize(const [always], const [always]), isTrue);
    });

    test('catches the roster changing', () {
      expect(sameQuantize(const [quiet], const [quiet, quiet]), isFalse);
    });
  });
}
