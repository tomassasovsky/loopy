import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
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
  }) => PedalStateFrame(
    globalColor: GlobalColor.off,
    trackLeds:
        leds ?? List.filled(PedalStateFrame.trackCount, PedalTrackLed.off),
    activeBank: 0,
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
        pedal: const PedalState(),
        frame: frame(),
      );
      expect(violation(c, 'depths-sane'), isNotNull);
    });

    test('accepts a clean empty looper', () {
      final c = ControlContext(
        looper: looper(),
        pedal: const PedalState(),
        frame: frame(),
      );
      expect(violation(c, 'depths-sane'), isNull);
    });
  });

  group('cursor rules', () {
    test('bank must match the cursor', () {
      final c = ControlContext(
        looper: looper(),
        pedal: const PedalState(selectedTrack: 5), // bank should be 1
        frame: frame(),
      );
      expect(violation(c, 'cursor-in-range'), isNotNull);
    });

    test('cursor-mirrored flags divergent surfaces, skips a null context', () {
      final diverged = ControlContext(
        looper: looper(),
        pedal: const PedalState(selectedTrack: 4, activeBank: 1),
        tracks: const TracksState(names: [], selectedChannel: 2),
        frame: frame(),
      );
      expect(violation(diverged, 'cursor-mirrored'), isNotNull);

      final noTracks = ControlContext(
        looper: looper(),
        pedal: const PedalState(selectedTrack: 4, activeBank: 1),
        frame: frame(),
      );
      expect(violation(noTracks, 'cursor-mirrored'), isNull);
    });
  });

  group('LED rules', () {
    test('empty-track-dark: a lit EMPTY track violates (cursor excepted)', () {
      final lit = ControlContext(
        looper: looper(),
        pedal: const PedalState(),
        frame: frame(leds: ledsWith(3, PedalTrackLed.green)),
      );
      expect(violation(lit, 'empty-track-dark'), isNotNull);

      // The Rec-mode cursor LED is red on an empty track by design.
      final cursor = ControlContext(
        looper: looper(),
        pedal: const PedalState(),
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
        pedal: const PedalState(mode: LooperMode.play),
        frame: frame(
          leds: ledsWith(0, PedalTrackLed.green),
          mode: PedalMode.play,
          loopLengthMicros: 1000,
        ),
      );
      expect(violation(c, 'muted-dark-in-play'), isNotNull);
    });

    test(
      'sounding-armed-and-green: dark-but-sounding violates (fuzz-only)',
      () {
        final c = ControlContext(
          looper: looper(
            tracks: tracksWith(
              const Track(state: TrackState.playing, lengthFrames: 100),
            ),
            masterLengthFrames: 100,
          ),
          pedal: const PedalState(mode: LooperMode.play), // not armed
          frame: frame(mode: PedalMode.play, loopLengthMicros: 1000),
        );
        expect(violation(c, 'sounding-armed-and-green'), isNotNull);
        // ...but the projection-time context skips it (fuzzOnly).
        expect(
          checkControlInvariants(
            c,
            projectionContext: true,
          ).where((v) => v.startsWith('sounding-armed-and-green:')),
          isEmpty,
        );
      },
    );

    test('capturing-red-in-rec: a dark capturing track violates', () {
      final c = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(channel: 3, state: TrackState.recording),
          ),
        ),
        pedal: const PedalState(),
        frame: frame(),
      );
      expect(violation(c, 'capturing-red-in-rec'), isNotNull);
    });
  });

  group('armed set + ring', () {
    test('armed-only-playable: an armed empty channel violates', () {
      final c = ControlContext(
        looper: looper(),
        pedal: const PedalState(mode: LooperMode.play, playArmed: {2}),
        frame: frame(mode: PedalMode.play),
      );
      expect(violation(c, 'armed-only-playable'), isNotNull);
    });

    test('ring-length-iff-loops: needs BOTH content and a grid', () {
      // Content + grid but a dark ring: violation.
      final dark = ControlContext(
        looper: looper(
          tracks: tracksWith(
            const Track(state: TrackState.playing, lengthFrames: 100),
          ),
          masterLengthFrames: 100,
        ),
        pedal: const PedalState(),
        frame: frame(),
      );
      expect(violation(dark, 'ring-length-iff-loops'), isNotNull);

      // A defining recording (capturing, no grid yet) with a dark ring: fine.
      final defining = ControlContext(
        looper: looper(
          tracks: tracksWith(const Track(state: TrackState.recording)),
        ),
        pedal: const PedalState(),
        frame: frame(leds: ledsWith(0, PedalTrackLed.red)),
      );
      expect(violation(defining, 'ring-length-iff-loops'), isNull);
    });

    test('frame-mirrors-mode: a rec frame in play mode violates', () {
      final c = ControlContext(
        looper: looper(),
        pedal: const PedalState(mode: LooperMode.play),
        frame: frame(), // mode: rec
      );
      expect(violation(c, 'frame-mirrors-mode'), isNotNull);
    });
  });

  group('debugControlInvariantsHold', () {
    test('throws with every violation listed, returns true when clean', () {
      final broken = ControlContext(
        looper: looper(tracks: tracksWith(const Track(lengthFrames: 100))),
        pedal: const PedalState(),
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
        pedal: const PedalState(),
        frame: frame(),
      );
      expect(debugControlInvariantsHold(clean), isTrue);
    });
  });
}
