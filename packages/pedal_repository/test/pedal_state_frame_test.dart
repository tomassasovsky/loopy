import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  PedalStateFrame sample() => PedalStateFrame(
    globalColor: GlobalColor.amber,
    trackLeds: List<PedalTrackLed>.filled(
      PedalStateFrame.trackCount,
      PedalTrackLed.green,
    ),
    activeBank: 1,
    armedTrack: 4,
    playMode: true,
    loopLengthMicros: 1000,
    clearFadeActive: true,
  );

  group('PedalStateFrame.blank', () {
    test('is fully off and not a goodbye by default', () {
      final blank = PedalStateFrame.blank();
      expect(blank.globalColor, GlobalColor.off);
      expect(blank.trackLeds, everyElement(PedalTrackLed.off));
      expect(blank.trackLeds, hasLength(PedalStateFrame.trackCount));
      expect(blank.activeBank, 0);
      expect(blank.armedTrack, 0);
      expect(blank.playMode, isFalse);
      expect(blank.loopLengthMicros, 0);
      expect(blank.clearFadeActive, isFalse);
      expect(blank.isGoodbye, isFalse);
    });

    test('sets isGoodbye when requested', () {
      expect(PedalStateFrame.blank(goodbye: true).isGoodbye, isTrue);
    });
  });

  group('equality', () {
    test('frames with equal fields are equal', () {
      expect(sample(), sample());
      expect(sample().hashCode, sample().hashCode);
    });

    test('frames differ when a field differs', () {
      expect(sample(), isNot(sample().copyWith(armedTrack: 5)));
    });

    test('toString surfaces the salient fields', () {
      final text = sample().toString();
      expect(text, contains('amber'));
      expect(text, contains('bank: 1'));
      expect(text, contains('armed: 4'));
    });
  });

  group('copyWith', () {
    test('replaces only the given fields', () {
      final updated = sample().copyWith(
        globalColor: GlobalColor.red,
        activeBank: 0,
        armedTrack: 2,
        playMode: false,
        loopLengthMicros: 50,
        clearFadeActive: false,
        isGoodbye: true,
        trackLeds: List<PedalTrackLed>.filled(
          PedalStateFrame.trackCount,
          PedalTrackLed.red,
        ),
      );
      expect(updated.globalColor, GlobalColor.red);
      expect(updated.activeBank, 0);
      expect(updated.armedTrack, 2);
      expect(updated.playMode, isFalse);
      expect(updated.loopLengthMicros, 50);
      expect(updated.clearFadeActive, isFalse);
      expect(updated.isGoodbye, isTrue);
      expect(updated.trackLeds, everyElement(PedalTrackLed.red));
    });

    test('keeps the original values when no override is given', () {
      expect(sample().copyWith(), sample());
    });
  });

  group('assertions', () {
    test('rejects the wrong number of track LEDs', () {
      expect(
        () => PedalStateFrame(
          globalColor: GlobalColor.off,
          trackLeds: const [PedalTrackLed.off],
          activeBank: 0,
          armedTrack: 0,
          playMode: false,
          loopLengthMicros: 0,
          clearFadeActive: false,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects an out-of-range bank', () {
      expect(
        () => sample().copyWith(activeBank: 2),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects an out-of-range armed track', () {
      expect(
        () => sample().copyWith(armedTrack: PedalStateFrame.trackCount),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(armedTrack: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a loop length outside the 32-bit range', () {
      expect(
        () => sample().copyWith(loopLengthMicros: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(
          loopLengthMicros: PedalStateFrame.maxLoopLengthMicros + 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts the maximum loop length', () {
      expect(
        sample()
            .copyWith(loopLengthMicros: PedalStateFrame.maxLoopLengthMicros)
            .loopLengthMicros,
        PedalStateFrame.maxLoopLengthMicros,
      );
    });
  });
}
