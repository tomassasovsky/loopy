import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

LooperState _stateWith(List<Track> tracks) => LooperState(
  transport: const TransportState(isRunning: true, masterLengthFrames: 48000),
  tracks: tracks,
);

List<Track> _emptyTracks() => [
  for (var i = 0; i < 8; i++) Track(channel: i),
];

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

void main() {
  group('ControlIntents', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;
    late ControlOverlayCubit overlay;
    late ControlIntents intents;

    /// Publishes [tracks] as engine truth: both the pull (`looper.state`) and
    /// the push (the overlay's reducer subscription) see the same snapshot.
    void setEngine(List<Track> tracks) {
      final state = _stateWith(tracks);
      when(() => looper.state).thenReturn(state);
      looperStates.add(state);
    }

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      settings = SettingsRepository(store: FakeKeyValueStore());
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      for (final stub in [
        () => looper.record(channel: any(named: 'channel')),
        () => looper.undo(channel: any(named: 'channel')),
        () => looper.redo(channel: any(named: 'channel')),
        () => looper.clear(channel: any(named: 'channel')),
        () => looper.play(channel: any(named: 'channel')),
        () => looper.stopTrack(channel: any(named: 'channel')),
      ]) {
        when(stub).thenReturn(EngineResult.ok);
      }
      when(
        () => looper.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      ).thenReturn(EngineResult.ok);
      when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);

      overlay = ControlOverlayCubit(looper: looper);
      intents = ControlIntents(
        looper: looper,
        overlay: overlay,
        settings: settings,
      );
      setEngine(_emptyTracks());
    });

    tearDown(() async {
      await overlay.close();
      await looperStates.close();
    });

    group('mode', () {
      test('toggleMode flips between Record and Play', () {
        expect(overlay.state.mode, LooperMode.record);
        intents.toggleMode();
        expect(overlay.state.mode, LooperMode.play);
        intents.toggleMode();
        expect(overlay.state.mode, LooperMode.record);
      });

      test('entering Play previews the whole content set as parkedResume', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 2,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        intents.toggleMode();
        // Stopped and muted content is included — Rec/Play resumes it all.
        expect(overlay.state.parkedResume, {0, 2});
      });

      test('entering Play finalizes a live capture first', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        intents.toggleMode();
        verify(() => looper.record()).called(1); // finalize channel 0
        expect(overlay.state.mode, LooperMode.play);
      });

      test('setMode to the current mode is a no-op', () {
        intents.setMode(LooperMode.record);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        expect(overlay.state.mode, LooperMode.record);
      });

      test('setDefaultMode persists the token and applies the mode', () async {
        await intents.setDefaultMode(LooperMode.play);
        expect(overlay.state.defaultMode, LooperMode.play);
        expect(overlay.state.mode, LooperMode.play);
        expect(await settings.loadDefaultLooperMode(), LooperMode.play.token);
      });

      test('load boots the live mode into the persisted default', () async {
        await settings.saveDefaultLooperMode(LooperMode.play.token);
        await intents.load();
        expect(overlay.state.defaultMode, LooperMode.play);
        expect(overlay.state.mode, LooperMode.play);
      });

      test('toggleMode does not change the persisted default mode', () async {
        intents.toggleMode();
        expect(overlay.state.mode, LooperMode.play);
        expect(overlay.state.defaultMode, LooperMode.record);
        expect(await settings.loadDefaultLooperMode(), isNull);
      });
    });

    group('cursor / bank', () {
      test('selectTrack and browseBank drive the overlay', () {
        intents.selectTrack(5);
        expect(overlay.state.cursor, 5);
        expect(overlay.state.activeBank, 1);

        intents.browseBank(0);
        expect(overlay.state.activeBank, 0);
        expect(overlay.state.cursor, 5); // browse keeps the cursor
      });

      test('toggleBankWithCursor moves the cursor to the new bank base', () {
        intents.toggleBankWithCursor();
        expect(overlay.state.activeBank, 1);
        expect(overlay.state.cursor, 4);

        intents.toggleBankWithCursor();
        expect(overlay.state.activeBank, 0);
        expect(overlay.state.cursor, 0);
      });
    });

    group('recPlay in Rec mode', () {
      test('drives the cursor track record cycle', () {
        intents.recPlay();
        verify(() => looper.record()).called(1);
      });

      test('unmutes and overdubs a muted, still-running track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
          ]),
        );
        intents.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.record()).called(1);
      });

      test('resumes a muted, parked track without overdub', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, muted: true, lengthFrames: 48000),
          ]),
        );
        intents.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.play()).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });
    });

    group('recPlay in Play mode', () {
      test('parked: resumes the latched set and consumes it', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode() // -> play, parkedResume = {0, 1}
          ..recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        expect(overlay.state.parkedResume, isEmpty); // consumed
      });

      test('parked with an empty resume set falls back to ALL content', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        intents.toggleMode();
        overlay.latchParkedResume(const {}); // as after mute-last-track park
        intents.recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('nothing recorded: a no-op', () {
        intents
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
      });

      test('running: expands to the whole content set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode()
          ..recPlay();
        // ch1 (parked content) joins; ch0 is re-asserted too.
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('running with the full audible set already in: a no-op', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });
    });

    group('stop', () {
      test('Rec mode: mutes the cursor track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test('Rec mode: finalizes a capture before muting', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        intents.stop();
        verify(() => looper.record()).called(1); // finalize first
        verify(() => looper.setMute(muted: true)).called(1);
      });

      test('Rec mode: muting the sole audible track parks everything', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        verify(() => looper.stopTrack()).called(1);
      });

      test(
        'Play mode: parks every running track and latches the resume set',
        () {
          setEngine(
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
          intents
            ..toggleMode()
            ..stop();
          // Muted-but-running ch1 is frozen too (mute silences, park freezes).
          verify(() => looper.stopTrack()).called(1);
          verify(() => looper.stopTrack(channel: 1)).called(1);
          // The latch captured the running set at INTENT time.
          expect(overlay.state.parkedResume, {0, 1});
        },
      );

      test('Play mode: stop while already parked keeps the resume set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode() // parkedResume = {0}
          ..stop();
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        expect(overlay.state.parkedResume, {0});
      });
    });

    group('trackPressed in Rec mode', () {
      test('selects the track while idle', () {
        intents.trackPressed(2);
        expect(overlay.state.cursor, 2);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test('finishes the loop when the capturing track is pressed', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        intents.trackPressed(0);
        verify(() => looper.record()).called(1);
      });

      test('hands off a live recording to the pressed track', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        intents.trackPressed(2);
        verify(() => looper.record()).called(1); // finalize
        verify(() => looper.record(channel: 2)).called(1); // start pressed
        expect(overlay.state.cursor, 2);
      });
    });

    group('trackPressed in Play mode', () {
      test('an empty track is a no-op', () {
        intents
          ..toggleMode()
          ..trackPressed(3);
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        expect(overlay.state.parkedResume, isEmpty);
      });

      test('parked: toggles resume membership, unmuting a joining track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        intents
          ..toggleMode() // parkedResume = {0, 1}
          ..trackPressed(0); // leave the set
        expect(overlay.state.parkedResume, {1});
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        intents.trackPressed(0); // rejoin
        expect(overlay.state.parkedResume, {0, 1});

        // A muted non-member joining is unmuted so its LED can read green.
        overlay.latchParkedResume(const {0});
        intents.trackPressed(1);
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(overlay.state.parkedResume, {0, 1});
      });

      test('running: a live track press toggles its mute', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode()
          ..trackPressed(0);
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        // Engine reflects the mute; pressing again unmutes (out-of-mix join).
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents.trackPressed(0);
        verify(() => looper.setMute(muted: false)).called(1);
      });

      test('muting the last audible track parks with an empty latch', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        intents
          ..toggleMode()
          ..trackPressed(1); // mute the only audible track
        verify(() => looper.setMute(muted: true, channel: 1)).called(1);
        // Every running track parks (the muted one too).
        verify(() => looper.stopTrack()).called(1);
        verify(() => looper.stopTrack(channel: 1)).called(1);
        // Empty latch: the next Rec/Play falls back to ALL content.
        expect(overlay.state.parkedResume, isEmpty);
      });

      test('running: a parked content track joins the mix', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        intents
          ..toggleMode()
          ..trackPressed(1);
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });
    });

    group('clearAll', () {
      test(
        'wipes content AND redo-able tracks, unmuting and persisting',
        () async {
          setEngine(
            _tracksWith(const [
              Track(
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
              Track(channel: 1, redoDepth: 2), // undone-to-empty, resurrectable
            ]),
          );
          intents
            ..toggleMode()
            ..selectTrack(5)
            ..clearAll();

          verify(() => looper.clear()).called(1);
          verify(() => looper.clear(channel: 1)).called(1); // redo path wiped
          verifyNever(() => looper.clear(channel: 2));
          verify(() => looper.setMute(muted: false)).called(1);
          verify(() => looper.setMute(muted: false, channel: 1)).called(1);

          // The whole-rig reset: overlay home again.
          expect(overlay.state.mode, LooperMode.record);
          expect(overlay.state.cursor, 0);
          expect(overlay.state.parkedResume, isEmpty);

          // The unmute persists per lane (lane 0 default when none reported).
          await Future<void>.delayed(Duration.zero);
          expect(await settings.loadLaneMute(0, 0), isFalse);
          expect(await settings.loadLaneMute(1, 0), isFalse);
        },
      );
    });

    group('undo / redo / encoder', () {
      test('undo and redo pass straight through to the repository', () {
        intents
          ..undo(3)
          ..redo(5);
        verify(() => looper.undo(channel: 3)).called(1);
        verify(() => looper.redo(channel: 5)).called(1);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
      });

      test('encoderTurned accumulates the master gain and clamps at 0', () {
        intents.encoderTurned(-8); // 1.0 - 8/64
        final captured = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(captured.single, closeTo(1 - 8 / 64, 1e-9));

        intents.encoderTurned(-64); // clamps at 0
        final clamped = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(clamped.single, 0.0);
      });
    });
  });
}
