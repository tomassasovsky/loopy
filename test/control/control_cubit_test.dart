import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  int masterPositionFrames = 0,
  int sampleRate = 48000,
}) => LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: masterLengthFrames,
    masterPositionFrames: masterPositionFrames,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _emptyTracks([int count = 8]) => [
  for (var i = 0; i < count; i++) Track(channel: i),
];

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

/// The ONE control-surface interpreter, tested over mocked engine truth: the
/// intent methods (shared by keyboard / on-screen surfaces), the stored-
/// intent invalidation reducer, and the pedal I/O it owns through
/// [PedalRepository] — footswitch decode in, projected LED frames out.
void main() {
  group('ControlCubit', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;
    late FakePedalTransport transport;
    late PedalRepository pedal;
    late ControlCubit cubit;

    /// Publishes [tracks] as engine truth: both the pull (`looper.state`) and
    /// the push (the cubit's reducer subscription) see the same snapshot.
    void setEngine(
      List<Track> tracks, {
      int masterPositionFrames = 0,
    }) {
      final state = _stateWith(
        tracks,
        masterPositionFrames: masterPositionFrames,
      );
      when(() => looper.state).thenReturn(state);
      looperStates.add(state);
    }

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      settings = SettingsRepository(store: FakeKeyValueStore());
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
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

      cubit = ControlCubit(looper: looper, pedal: pedal, settings: settings);
      setEngine(_emptyTracks());
    });

    tearDown(() async {
      await cubit.close();
      await pedal.dispose();
      await looperStates.close();
    });

    group('mode', () {
      test('toggleMode flips between Record and Play', () {
        expect(cubit.state.mode, LooperMode.record);
        cubit.toggleMode();
        expect(cubit.state.mode, LooperMode.play);
        cubit.toggleMode();
        expect(cubit.state.mode, LooperMode.record);
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
        cubit.toggleMode();
        // Stopped and muted content is included — Rec/Play resumes it all.
        expect(cubit.state.parkedResume, {0, 2});
      });

      test('entering Play finalizes a live capture first', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode();
        verify(() => looper.record()).called(1); // finalize channel 0
        expect(cubit.state.mode, LooperMode.play);
      });

      test('setMode to the current mode is a no-op', () {
        cubit.setMode(LooperMode.record);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        expect(cubit.state.mode, LooperMode.record);
      });

      test('setDefaultMode persists the token and applies the mode', () async {
        await cubit.setDefaultMode(LooperMode.play);
        expect(cubit.state.defaultMode, LooperMode.play);
        expect(cubit.state.mode, LooperMode.play);
        expect(await settings.loadDefaultLooperMode(), LooperMode.play.token);
      });

      test('load boots the live mode into the persisted default', () async {
        await settings.saveDefaultLooperMode(LooperMode.play.token);
        await cubit.load();
        expect(cubit.state.defaultMode, LooperMode.play);
        expect(cubit.state.mode, LooperMode.play);
      });

      test('toggleMode does not change the persisted default mode', () async {
        cubit.toggleMode();
        expect(cubit.state.mode, LooperMode.play);
        expect(cubit.state.defaultMode, LooperMode.record);
        expect(await settings.loadDefaultLooperMode(), isNull);
      });
    });

    group('cursor / bank', () {
      test('selectTrack moves the cursor into its bank', () {
        cubit.selectTrack(5);
        expect(cubit.state.cursor, 5);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.bankBaseChannel, 4);
        expect(cubit.state.bankContains(5), isTrue);
        expect(cubit.state.bankContains(2), isFalse);
      });

      test('selectTrack ignores out-of-range channels', () {
        cubit
          ..selectTrack(-1)
          ..selectTrack(8);
        expect(cubit.state.cursor, 0);
      });

      test('browseBank reveals the bank WITHOUT moving the cursor', () {
        cubit.browseBank(1);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 0); // browse only

        cubit
          ..browseBank(-1)
          ..browseBank(2);
        expect(cubit.state.activeBank, 1); // out-of-range ignored
      });

      test('toggleBankWithCursor moves the cursor to the new bank base', () {
        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);

        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 0);
        expect(cubit.state.cursor, 0);
      });
    });

    group('recPlay in Rec mode', () {
      test('drives the cursor track record cycle', () {
        cubit.recPlay();
        verify(() => looper.record()).called(1);
      });

      test('unmutes and overdubs a muted, still-running track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.record()).called(1);
      });

      test('resumes a muted, parked track without overdub', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
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
        cubit
          ..toggleMode() // -> play, parkedResume = {0, 1}
          ..recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        expect(cubit.state.parkedResume, isEmpty); // consumed
      });

      test('parked with an empty resume set falls back to ALL content', () {
        // Enter Play with nothing recorded: the latch is empty. Content
        // appearing afterwards (e.g. a session load while parked) never
        // re-latches — the reducer only prunes — so Rec/Play falls back.
        cubit.toggleMode();
        expect(cubit.state.parkedResume, isEmpty);
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('nothing recorded: a no-op', () {
        cubit
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
        cubit
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
        cubit
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
        cubit.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test('Rec mode: finalizes a capture before muting', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.stop();
        verify(() => looper.record()).called(1); // finalize first
        verify(() => looper.setMute(muted: true)).called(1);
      });

      test('Rec mode: muting the sole audible track parks everything', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.stop();
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
          cubit
            ..toggleMode()
            ..stop();
          // Muted-but-running ch1 is frozen too (mute silences, park
          // freezes).
          verify(() => looper.stopTrack()).called(1);
          verify(() => looper.stopTrack(channel: 1)).called(1);
          // The latch captured the running set at INTENT time.
          expect(cubit.state.parkedResume, {0, 1});
        },
      );

      test('Play mode: stop while already parked keeps the resume set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0}
          ..stop();
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, {0});
      });
    });

    group('trackPressed in Rec mode', () {
      test('selects the track while idle', () {
        cubit.trackPressed(2);
        expect(cubit.state.cursor, 2);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test('finishes the loop when the capturing track is pressed', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(0);
        verify(() => looper.record()).called(1);
      });

      test('hands off a live recording to the pressed track', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(2);
        verify(() => looper.record()).called(1); // finalize
        verify(() => looper.record(channel: 2)).called(1); // start pressed
        expect(cubit.state.cursor, 2);
      });
    });

    group('trackPressed in Play mode', () {
      test('an empty track is a no-op', () {
        cubit
          ..toggleMode()
          ..trackPressed(3);
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, isEmpty);
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
        cubit
          ..toggleMode() // parkedResume = {0, 1}
          ..trackPressed(0); // leave the set
        expect(cubit.state.parkedResume, {1});
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        cubit.trackPressed(0); // rejoin
        expect(cubit.state.parkedResume, {0, 1});

        // A muted member leaving then rejoining: the rejoin is a muted
        // NON-member arming, so it unmutes to read green.
        cubit.trackPressed(1); // leave -> {0}
        expect(cubit.state.parkedResume, {0});
        cubit.trackPressed(1); // rejoin: muted non-member -> unmute
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.parkedResume, {0, 1});
      });

      test('running: a live track press toggles its mute', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
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
        cubit.trackPressed(0);
        verify(() => looper.setMute(muted: false)).called(1);
      });

      test('muting the last audible track parks with an empty latch', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1); // mute the only audible track
        verify(() => looper.setMute(muted: true, channel: 1)).called(1);
        // Every running track parks (the muted one too).
        verify(() => looper.stopTrack()).called(1);
        verify(() => looper.stopTrack(channel: 1)).called(1);
        // Empty latch: the next Rec/Play falls back to ALL content.
        expect(cubit.state.parkedResume, isEmpty);
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
        cubit
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
              Track(channel: 1, redoDepth: 2), // undone-to-empty
            ]),
          );
          cubit
            ..toggleMode()
            ..selectTrack(5)
            ..clearAll();

          verify(() => looper.clear()).called(1);
          verify(() => looper.clear(channel: 1)).called(1); // redo path wiped
          verifyNever(() => looper.clear(channel: 2));
          verify(() => looper.setMute(muted: false)).called(1);
          verify(() => looper.setMute(muted: false, channel: 1)).called(1);

          // The whole-rig reset: overlay home again.
          expect(cubit.state.mode, LooperMode.record);
          expect(cubit.state.cursor, 0);
          expect(cubit.state.parkedResume, isEmpty);

          // The unmute persists per lane (lane 0 default when none reported).
          await Future<void>.delayed(Duration.zero);
          expect(await settings.loadLaneMute(0, 0), isFalse);
          expect(await settings.loadLaneMute(1, 0), isFalse);
        },
      );
    });

    group('undo / redo / encoder', () {
      test('undo and redo pass straight through to the repository', () {
        cubit
          ..undo(3)
          ..redo(5);
        verify(() => looper.undo(channel: 3)).called(1);
        verify(() => looper.redo(channel: 5)).called(1);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
      });

      test('encoderTurned accumulates the master gain and clamps at 0', () {
        cubit.encoderTurned(-8); // 1.0 - 8/64
        final captured = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(captured.single, closeTo(1 - 8 / 64, 1e-9));

        cubit.encoderTurned(-64); // clamps at 0
        final clamped = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(clamped.single, 0.0);
      });
    });

    group('looper reducer (the invalidation table)', () {
      test('clamps the cursor when the track list shrinks', () {
        cubit.selectTrack(7);
        expect(cubit.state.cursor, 7);

        setEngine(_emptyTracks(4));
        expect(cubit.state.cursor, 3);
        expect(cubit.state.activeBank, 0); // follows the clamped cursor
      });

      test('prunes parkedResume of emptied tracks', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.toggleMode(); // parkedResume = {0, 1}
        // Track 1 empties (undo-to-empty / clear): it drops from the set.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        expect(cubit.state.parkedResume, {0});
      });

      test('keeps capturing tracks in the stored sets', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode(); // finalizes + parkedResume = {0}
        expect(cubit.state.parkedResume, {0});
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        expect(cubit.state.parkedResume, {0}); // finishing a loop: kept
      });

      test('a no-change snapshot does not emit', () {
        final emits = <ControlState>[];
        final sub = cubit.stream.listen(emits.add);

        setEngine(_emptyTracks());
        expect(emits, isEmpty);
        unawaited(sub.cancel());
      });
    });

    group('pedal decode (events in via PedalRepository)', () {
      test('Rec/Play decodes into the record intent on the cursor', () async {
        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        verify(() => looper.record()).called(1);
      });

      test('Mode toggles the shared mode', () async {
        transport.emit(0x90, PedalButton.mode.note, 100);
        await pumpEventQueue();
        expect(cubit.state.mode, LooperMode.play);
      });

      test('Bank toggles the active bank and moves the cursor', () async {
        transport.emit(0x90, PedalButton.bank.note, 100);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('a track press targets the visible bank base', () async {
        transport.emit(0x90, PedalButton.bank.note, 100); // -> bank B
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.track3.note, 100);
        await pumpEventQueue();
        // track3 == index 2, bank B base 4 -> channel 6 (idle press selects).
        expect(cubit.state.cursor, 6);
      });

      test('the encoder drives the master gain', () async {
        transport.emit(0xB0, PedalCodec.encoderCc, 64 - 8); // -8 detents
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test('Clear decodes into the unified clear-all', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();

        verify(() => looper.clear()).called(1);
        verify(() => looper.clear(channel: 1)).called(1);
        verifyNever(() => looper.clear(channel: 2));
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.mode, LooperMode.record);
        expect(cubit.state.cursor, 0);
      });

      group('undo press timing', () {
        test('tap undoes the cursor track', () async {
          transport
            ..emit(0x90, PedalButton.undo.note, 100) // press
            ..emit(0x80, PedalButton.undo.note, 0); // quick release == tap
          await pumpEventQueue();

          verify(() => looper.undo()).called(1);
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
          verifyNever(() => looper.clear(channel: any(named: 'channel')));
        });

        test('the undo target is latched at press time', () async {
          transport.emit(0x90, PedalButton.undo.note, 100); // press, cursor 0
          await pumpEventQueue();
          // An on-screen click mid-hold must not retarget the committed
          // action.
          cubit.selectTrack(3);
          transport.emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();

          verify(() => looper.undo()).called(1); // channel 0, not 3
          verifyNever(() => looper.undo(channel: 3));
        });

        test('long-press redoes instead', () async {
          transport.emit(0x90, PedalButton.undo.note, 100);
          // Default long-press threshold is 500 ms.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();

          verify(() => looper.redo()).called(1);
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
        });
      });
    });

    group('frame projection (frames out via PedalRepository)', () {
      test('pushes an encoded frame to the bound pedal', () async {
        pedal.bind('out');
        transport.sent.clear();

        // Rec mode (default): the cursor track (0) is red; a playing
        // non-cursor track is off (green-for-playing is a Play-mode concern).
        setEngine(
          _tracksWith(const [
            Track(), // track 0 (cursor) -> red indicator
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame, isNotNull);
        expect(frame!.trackLeds[0], PedalTrackLed.red);
        expect(frame.trackLeds[1], PedalTrackLed.off);
      });

      test('a stored-intent change re-projects without a looper tick', () {
        pedal.bind('out');
        setEngine(_emptyTracks());
        transport.sent.clear();

        cubit.selectTrack(3); // cursor moves -> the red LED must follow

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.selectedTrack, 3);
        expect(frame.trackLeds[3], PedalTrackLed.red);
        expect(frame.trackLeds[0], PedalTrackLed.off);
      });

      test('a rebind force-pushes the CURRENT state', () async {
        setEngine(_emptyTracks());
        cubit.toggleMode(); // mode changes while unbound
        pedal.bind('out');
        await pumpEventQueue();

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.mode, PedalMode.play);
      });

      test('Clear LED lights while the footswitch is held and darkens on '
          'release', () async {
        pedal.bind('out');
        setEngine(_emptyTracks());
        transport.sent.clear();

        // Press: the Clear LED bit is set.
        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();
        expect(
          PedalCodec.decodeFrame(transport.sent.last)?.clearFadeActive,
          isTrue,
        );

        // Release (note-off): the bit clears again.
        transport.emit(0x80, PedalButton.clear.note, 0);
        await pumpEventQueue();
        expect(
          PedalCodec.decodeFrame(transport.sent.last)?.clearFadeActive,
          isFalse,
        );
      });

      test('sends a loop-top pulse when the playhead wraps', () async {
        pedal.bind('out');
        setEngine(_emptyTracks(), masterPositionFrames: 40000);
        await pumpEventQueue();
        transport.sent.clear();
        setEngine(_emptyTracks(), masterPositionFrames: 10);
        await pumpEventQueue();

        expect(
          transport.sent.any((m) => m.length == 1 && m.first == 0xFA),
          isTrue,
        );
      });

      test(
        'global_color carries the ring activity color (recording = red)',
        () async {
          pedal.bind('out');
          transport.sent.clear();
          setEngine(
            _tracksWith(const [Track(state: TrackState.recording)]),
          );
          await pumpEventQueue();

          final frame = PedalCodec.decodeFrame(transport.sent.last);
          expect(frame?.globalColor, GlobalColor.red);
        },
      );

      test(
        'the pushed frame carries the per-track LED projection',
        () async {
          pedal.bind('out');
          transport.sent.clear();
          setEngine(
            _tracksWith(const [
              Track(), // ch0 cursor by default -> red
              Track(channel: 1, state: TrackState.recording),
            ]),
          );
          await pumpEventQueue();

          final leds = PedalCodec.decodeFrame(transport.sent.last)?.trackLeds;
          expect(leds?[0], PedalTrackLed.red);
          expect(leds?[1], PedalTrackLed.red);
          expect(leds?[2], PedalTrackLed.off);

          cubit.selectTrack(2);
          await pumpEventQueue();
          expect(
            PedalCodec.decodeFrame(transport.sent.last)?.trackLeds[2],
            PedalTrackLed.red,
          );
        },
      );
    });
  });
}
