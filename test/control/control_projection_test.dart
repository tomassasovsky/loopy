import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:pedal_repository/pedal_repository.dart';

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  int sampleRate = 48000,
}) => LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: masterLengthFrames,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

void main() {
  group('isParked', () {
    test('false with no content at all', () {
      expect(isParked(_stateWith(_tracksWith(const []))), isFalse);
    });

    test('true when content exists but nothing runs', () {
      expect(
        isParked(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.stopped, lengthFrames: 48000),
            ]),
          ),
        ),
        isTrue,
      );
    });

    test('false while any content track runs — even muted', () {
      // Mute-ignored: keyboard-muting every track does NOT park.
      expect(
        isParked(
          _stateWith(
            _tracksWith(const [
              Track(
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
            ]),
          ),
        ),
        isFalse,
      );
    });
  });

  group('isSounding', () {
    test('requires content, unmuted, and a running playhead', () {
      expect(
        isSounding(const Track(state: TrackState.playing, lengthFrames: 100)),
        isTrue,
      );
      expect(
        isSounding(
          const Track(state: TrackState.overdubbing, lengthFrames: 100),
        ),
        isTrue,
      );
      expect(
        isSounding(
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 100,
          ),
        ),
        isFalse,
      );
      expect(
        isSounding(const Track(state: TrackState.stopped, lengthFrames: 100)),
        isFalse,
      );
      expect(isSounding(const Track()), isFalse);
    });
  });

  group('armedTracks', () {
    test('while parked, the parked-resume set IS the armed set', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.stopped, lengthFrames: 48000),
          Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
        ]),
      );
      const overlay = ControlState(
        mode: LooperMode.play,
        parkedResume: {1},
      );
      expect(armedTracks(looper, overlay), {1});
    });

    test('while running, armed = sounding minus excluded — derived fresh', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          Track(
            channel: 2,
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
        ]),
      );
      const overlay = ControlState(
        mode: LooperMode.play,
        excluded: {1},
      );
      expect(armedTracks(looper, overlay), {0});
    });
  });

  group('projectTrackLed', () {
    test('Play mode: armed and audible reads green, muted reads off', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000),
          Track(
            channel: 1,
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
        ]),
      );
      const overlay = ControlState(mode: LooperMode.play);
      expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.green);
      expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.off);
      expect(projectTrackLed(looper, overlay, 2), PedalTrackLed.off);
    });

    test('Rec mode: the cursor and any capturing track read red', () {
      final looper = _stateWith(
        _tracksWith(const [
          Track(channel: 3, state: TrackState.recording),
        ]),
        masterLengthFrames: 0,
      );
      const overlay = ControlState(cursor: 1);
      expect(projectTrackLed(looper, overlay, 1), PedalTrackLed.red);
      expect(projectTrackLed(looper, overlay, 3), PedalTrackLed.red);
      expect(projectTrackLed(looper, overlay, 0), PedalTrackLed.off);
    });

    test('redo after undo-to-empty relights with NO stored set to update', () {
      // The original bug class, retired by derivation: an undone-to-empty
      // track (dark) that redo resurrects reads green off the very next
      // snapshot — nothing stored needs reconciling.
      const overlay = ControlState(mode: LooperMode.play);
      final empty = _stateWith(
        _tracksWith(const [Track(redoDepth: 2)]),
      );
      expect(projectTrackLed(empty, overlay, 0), PedalTrackLed.off);

      final resurrected = _stateWith(
        _tracksWith(const [
          Track(state: TrackState.playing, lengthFrames: 48000, redoDepth: 1),
        ]),
      );
      expect(projectTrackLed(resurrected, overlay, 0), PedalTrackLed.green);
    });
  });

  group('projectFrame', () {
    test('carries the overlay cursor / bank / mode onto the wire', () {
      final looper = _stateWith(_tracksWith(const []), masterLengthFrames: 0);
      const overlay = ControlState(cursor: 5, activeBank: 1);
      final frame = projectFrame(looper, overlay);
      expect(frame.selectedTrack, 5);
      expect(frame.activeBank, 1);
      expect(frame.mode, PedalMode.rec);
      expect(frame.clearFadeActive, isFalse);
    });

    test('global color: recording red, overdub amber, playing green', () {
      const overlay = ControlState();
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [Track(state: TrackState.recording)]),
            masterLengthFrames: 0,
          ),
          overlay,
        ).globalColor,
        GlobalColor.red,
      );
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.overdubbing, lengthFrames: 48000),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.amber,
      );
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.green,
      );
      // Recording while another loop plays: amber (the blend).
      expect(
        projectFrame(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.recording),
              Track(
                channel: 1,
                state: TrackState.playing,
                lengthFrames: 48000,
              ),
            ]),
          ),
          overlay,
        ).globalColor,
        GlobalColor.amber,
      );
    });

    test('ring length renders only while something holds a loop', () {
      const overlay = ControlState();
      // A loop: one second at 48 kHz reads one million micros.
      final playing = projectFrame(
        _stateWith(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        ),
        overlay,
      );
      expect(playing.loopLengthMicros, 1000000);

      // Undone-to-empty ghost grid: master survives engine-side, but with no
      // content anywhere the ring must go dark.
      final ghost = projectFrame(
        _stateWith(_tracksWith(const [Track(redoDepth: 1)])),
        overlay,
      );
      expect(ghost.loopLengthMicros, 0);
    });

    test('flags the held Clear footswitch', () {
      final frame = projectFrame(
        _stateWith(_tracksWith(const []), masterLengthFrames: 0),
        const ControlState(),
        clearFadeActive: true,
      );
      expect(frame.clearFadeActive, isTrue);
    });

    test('asserts the invariant spec on an inconsistent projection input', () {
      // A stored resume set referencing an empty track violates
      // stored-intent-playable — the projection-time assert catches it.
      expect(
        () => projectFrame(
          _stateWith(_tracksWith(const []), masterLengthFrames: 0),
          const ControlState(parkedResume: {3}),
        ),
        throwsA(isA<Error>()),
      );
    });
  });
}
