import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Direct unit tests for the control-surface invariant spec: each rule is
/// exercised with a satisfied and a violated synthetic context. The sequence
/// fuzzer (test/fuzz/) checks the same predicates against the real engine;
/// these pin the predicates themselves.
void main() {
  PedalStateFrame frame({
    List<PedalTrackLed>? leds,
    PedalMode mode = PedalMode.rec,
    int loopLengthMicros = 0,
    int selectedTrack = 0,
    int activeBank = 0,
  }) => PedalStateFrame(
    globalColor: GlobalColor.off,
    trackLeds:
        leds ?? List.filled(PedalStateFrame.trackCount, PedalTrackLed.off),
    activeBank: activeBank,
    selectedTrack: selectedTrack,
    mode: mode,
    loopLengthMicros: loopLengthMicros,
    clearFadeActive: false,
  );

  List<PedalTrackLed> ledsWith(int channel, PedalTrackLed led) => [
    for (var i = 0; i < PedalStateFrame.trackCount; i++)
      if (i == channel) led else PedalTrackLed.off,
  ];

  LooperState looper({
    List<Track>? tracks,
    int masterLengthFrames = 0,
  }) => LooperState(
    transport: TransportState(
      isRunning: true,
      masterLengthFrames: masterLengthFrames,
    ),
    tracks: tracks ?? [for (var i = 0; i < 8; i++) Track(channel: i)],
  );

  List<Track> tracksWith(Track track) => [
    for (var i = 0; i < 8; i++)
      if (i == track.channel) track else Track(channel: i),
  ];

  String? violation(ControlContext c, String name) {
    final hits = checkControlInvariants(
      c,
    ).where((v) => v.startsWith('$name:')).toList();
    return hits.isEmpty ? null : hits.first;
  }

  group('depths-sane', () {
    test('rejects an EMPTY track with residual length', () {
      final c = ControlContext(
        looper: looper(tracks: tracksWith(const Track(lengthFrames: 100))),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(violation(c, 'depths-sane'), isNotNull);
    });

    test('accepts a clean empty looper', () {
      final c = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(violation(c, 'depths-sane'), isNull);
    });
  });

  group('cursor-and-bank-in-range', () {
    test('rejects an out-of-range cursor and bank', () {
      // The wire frame asserts its own ranges, so an out-of-range OVERLAY is
      // paired with an in-range frame (frame-mirrors-overlay flags that too,
      // but this rule must fire on the overlay itself).
      final badCursor = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(cursor: 9),
        frame: frame(),
      );
      expect(violation(badCursor, 'cursor-and-bank-in-range'), isNotNull);

      final badBank = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(activeBank: 2),
        frame: frame(),
      );
      expect(violation(badBank, 'cursor-and-bank-in-range'), isNotNull);
    });

    test('accepts a bank-B cursor', () {
      final c = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(cursor: 5, activeBank: 1),
        frame: frame(selectedTrack: 5, activeBank: 1),
      );
      expect(violation(c, 'cursor-and-bank-in-range'), isNull);
    });
  });

  group('frame-mirrors-overlay', () {
    test('rejects a frame whose cursor / bank / mode diverge', () {
      final cursor = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(cursor: 2),
        frame: frame(), // selectedTrack: 0
      );
      expect(violation(cursor, 'frame-mirrors-overlay'), isNotNull);

      final bank = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(activeBank: 1),
        frame: frame(), // activeBank: 0
      );
      expect(violation(bank, 'frame-mirrors-overlay'), isNotNull);

      final mode = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(mode: LooperMode.play),
        frame: frame(), // mode: rec
      );
      expect(violation(mode, 'frame-mirrors-overlay'), isNotNull);
    });

    test('accepts a mirrored frame', () {
      final c = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(mode: LooperMode.play, cursor: 4),
        frame: frame(mode: PedalMode.play, selectedTrack: 4, activeBank: 1),
      );
      // The overlay's activeBank defaults to 0 while its cursor is 4 — set it.
      final aligned = ControlContext(
        looper: c.looper,
        overlay: const ControlOverlayState(
          mode: LooperMode.play,
          cursor: 4,
          activeBank: 1,
        ),
        frame: c.frame,
      );
      expect(violation(aligned, 'frame-mirrors-overlay'), isNull);
    });
  });

  group('stored-intent-playable', () {
    test('rejects stored sets referencing an empty track', () {
      final excluded = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(excluded: {2}),
        frame: frame(),
      );
      expect(violation(excluded, 'stored-intent-playable'), isNotNull);

      final resume = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(parkedResume: {5}),
        frame: frame(),
      );
      expect(violation(resume, 'stored-intent-playable'), isNotNull);
    });

    test('accepts sets over content tracks', () {
      final c = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(
              channel: 2,
              state: TrackState.stopped,
              lengthFrames: 100,
            ),
          ),
          masterLengthFrames: 100,
        ),
        overlay: const ControlOverlayState(parkedResume: {2}),
        frame: frame(loopLengthMicros: 1000),
      );
      expect(violation(c, 'stored-intent-playable'), isNull);
    });
  });

  group('LED rules', () {
    test('empty-track-dark: a lit EMPTY track violates (cursor excepted)', () {
      final lit = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(),
        frame: frame(leds: ledsWith(3, PedalTrackLed.green)),
      );
      expect(violation(lit, 'empty-track-dark'), isNotNull);

      // The Rec-mode cursor LED is red on an empty track by design.
      final cursor = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(),
        frame: frame(leds: ledsWith(0, PedalTrackLed.red)),
      );
      expect(violation(cursor, 'empty-track-dark'), isNull);
    });

    test('muted-dark-in-play: a lit muted track violates', () {
      final c = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(
              state: TrackState.playing,
              lengthFrames: 100,
              muted: true,
            ),
          ),
          masterLengthFrames: 100,
        ),
        overlay: const ControlOverlayState(mode: LooperMode.play),
        frame: frame(
          leds: ledsWith(0, PedalTrackLed.green),
          mode: PedalMode.play,
          loopLengthMicros: 1000,
        ),
      );
      expect(violation(c, 'muted-dark-in-play'), isNotNull);
    });

    test('sounding-unexcluded-green: dark-but-sounding violates', () {
      final c = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(state: TrackState.playing, lengthFrames: 100),
          ),
          masterLengthFrames: 100,
        ),
        overlay: const ControlOverlayState(mode: LooperMode.play),
        frame: frame(mode: PedalMode.play, loopLengthMicros: 1000),
      );
      expect(violation(c, 'sounding-unexcluded-green'), isNotNull);
    });

    test(
      'sounding-unexcluded-green: an excluded sounding track may be dark',
      () {
        final c = ControlContext(
          looper: looper(
            tracks: tracksWith(
              const Track(state: TrackState.playing, lengthFrames: 100),
            ),
            masterLengthFrames: 100,
          ),
          overlay: const ControlOverlayState(
            mode: LooperMode.play,
            excluded: {0},
          ),
          frame: frame(mode: PedalMode.play, loopLengthMicros: 1000),
        );
        expect(violation(c, 'sounding-unexcluded-green'), isNull);
      },
    );

    test('parked-preview-matches-resume: LEDs must preview the resume set', () {
      LooperState parked() => looper(
        tracks: tracksWith(
          const Track(state: TrackState.stopped, lengthFrames: 100),
        ),
        masterLengthFrames: 100,
      );
      // Resume member dark: violation.
      final dark = ControlContext(
        looper: parked(),
        overlay: const ControlOverlayState(
          mode: LooperMode.play,
          parkedResume: {0},
        ),
        frame: frame(mode: PedalMode.play, loopLengthMicros: 1000),
      );
      expect(violation(dark, 'parked-preview-matches-resume'), isNotNull);

      // Non-member lit: violation.
      final lit = ControlContext(
        looper: parked(),
        overlay: const ControlOverlayState(mode: LooperMode.play),
        frame: frame(
          leds: ledsWith(0, PedalTrackLed.green),
          mode: PedalMode.play,
          loopLengthMicros: 1000,
        ),
      );
      expect(violation(lit, 'parked-preview-matches-resume'), isNotNull);

      // Member lit green: holds.
      final ok = ControlContext(
        looper: parked(),
        overlay: const ControlOverlayState(
          mode: LooperMode.play,
          parkedResume: {0},
        ),
        frame: frame(
          leds: ledsWith(0, PedalTrackLed.green),
          mode: PedalMode.play,
          loopLengthMicros: 1000,
        ),
      );
      expect(violation(ok, 'parked-preview-matches-resume'), isNull);
    });

    test('capturing-red-in-rec: a dark capturing track violates', () {
      final c = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(channel: 3, state: TrackState.recording),
          ),
        ),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(violation(c, 'capturing-red-in-rec'), isNotNull);
    });
  });

  group('ring-length-iff-loops', () {
    test('needs BOTH content and a grid', () {
      // Content + grid but a dark ring: violation.
      final dark = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(state: TrackState.playing, lengthFrames: 100),
          ),
          masterLengthFrames: 100,
        ),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(violation(dark, 'ring-length-iff-loops'), isNotNull);

      // A defining recording (capturing, no grid yet) with a dark ring: fine.
      final defining = ControlContext(
        looper: looper(
          tracks: tracksWith(const Track(state: TrackState.recording)),
        ),
        overlay: const ControlOverlayState(),
        frame: frame(leds: ledsWith(0, PedalTrackLed.red)),
      );
      expect(violation(defining, 'ring-length-iff-loops'), isNull);

      // An undone-to-empty ghost grid (master kept, zero content) must not
      // render a ring either.
      final ghost = ControlContext(
        looper: looper(masterLengthFrames: 100),
        overlay: const ControlOverlayState(),
        frame: frame(loopLengthMicros: 1000),
      );
      expect(violation(ghost, 'ring-length-iff-loops'), isNotNull);
    });
  });

  group('debugControlInvariantsHold', () {
    test('throws with every violation listed, returns true when clean', () {
      final broken = ControlContext(
        looper: looper(tracks: tracksWith(const Track(lengthFrames: 100))),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(
        () => debugControlInvariantsHold(broken),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('depths-sane'),
          ),
        ),
      );

      final clean = ControlContext(
        looper: looper(),
        overlay: const ControlOverlayState(),
        frame: frame(),
      );
      expect(debugControlInvariantsHold(clean), isTrue);
    });
  });
}
