import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';
import '../helpers/fake_pedal_transport.dart';

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

List<Track> _emptyTracks() => [
  for (var i = 0; i < 8; i++) Track(channel: i),
];

void main() {
  group('PedalCubit', () {
    late FakePedalTransport transport;
    late PedalRepository pedal;
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;

    setUp(() {
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast();
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
    });

    PedalCubit buildCubit() => PedalCubit(
      pedal: pedal,
      looper: looper,
      settings: settings,
      pollInterval: Duration.zero, // tests drive reconnect() directly
    );

    test('Rec/Play in Rec mode drives the armed track record cycle', () async {
      final cubit = buildCubit();
      transport.emit(0x90, PedalButton.recPlay.note, 100);
      await pumpEventQueue();

      verify(() => looper.record()).called(1);
      await cubit.close();
    });

    test(
      'a track press while idle re-arms without a transport change',
      () async {
        final cubit = buildCubit();
        looperStates.add(_stateWith(_emptyTracks()));
        await pumpEventQueue();

        transport.emit(0x90, PedalButton.track3.note, 100);
        await pumpEventQueue();

        expect(cubit.state.selectedTrack, 2); // track3 == channel 2 in bank A
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        await cubit.close();
      },
    );

    test('a track press hands off recording to the pressed track', () async {
      final cubit = buildCubit();
      // Track 0 is recording; pressing track 2 finalizes it and starts track 2.
      looperStates.add(
        _stateWith([
          const Track(state: TrackState.recording),
          for (var i = 1; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.track3.note, 100);
      await pumpEventQueue();

      verify(() => looper.record()).called(1); // finalize
      verify(() => looper.record(channel: 2)).called(1); // start pressed
      expect(cubit.state.selectedTrack, 2);
      await cubit.close();
    });

    test('Stop in Rec mutes the armed track', () async {
      final cubit = buildCubit();
      looperStates.add(_stateWith(_emptyTracks()));
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.stop.note, 100);
      await pumpEventQueue();

      verify(() => looper.setMute(muted: true)).called(1);
      await cubit.close();
    });

    test('Stop in Rec parks the sole audible track', () async {
      final cubit = buildCubit();
      looperStates.add(
        _stateWith([
          const Track(state: TrackState.playing, lengthFrames: 48000),
          for (var i = 1; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.stop.note, 100);
      await pumpEventQueue();
      verify(() => looper.setMute(muted: true)).called(1);
      verify(() => looper.stopTrack()).called(1); // sole track parked
      await cubit.close();
    });

    test(
      'Rec/Play unmutes and overdubs a muted, still-running track',
      () async {
        final cubit = buildCubit();
        // Selected track 0 is muted but its loop is still running.
        looperStates.add(
          _stateWith([
            const Track(
              state: TrackState.playing,
              muted: true,
              lengthFrames: 48000,
            ),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.record()).called(1); // unmute + overdub
        await cubit.close();
      },
    );

    test(
      'Rec/Play resumes a muted, parked sole track without overdub',
      () async {
        final cubit = buildCubit();
        // Selected track 0 is muted AND parked (stopped) — the sole-track case.
        looperStates.add(
          _stateWith([
            const Track(
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.play()).called(1); // resume, no overdub
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        await cubit.close();
      },
    );

    test('Mode toggles between Record and Play', () async {
      final cubit = buildCubit();
      expect(cubit.state.mode, LooperMode.record);

      transport.emit(0x90, PedalButton.mode.note, 100);
      await pumpEventQueue();

      expect(cubit.state.mode, LooperMode.play);
      await cubit.close();
    });

    test('setDefaultMode persists the token and applies the mode', () async {
      final cubit = buildCubit();
      await cubit.setDefaultMode(LooperMode.play);

      expect(cubit.state.defaultMode, LooperMode.play);
      expect(cubit.state.mode, LooperMode.play);
      expect(await settings.loadDefaultLooperMode(), LooperMode.play.token);
      await cubit.close();
    });

    test('load boots the live mode into the persisted default', () async {
      await settings.saveDefaultLooperMode(LooperMode.play.token);
      final cubit = buildCubit();
      await cubit.load();

      expect(cubit.state.defaultMode, LooperMode.play);
      expect(cubit.state.mode, LooperMode.play);
      await cubit.close();
    });

    test('toggleMode does not change the persisted default mode', () async {
      final cubit = buildCubit()..toggleMode();
      await pumpEventQueue();

      expect(cubit.state.mode, LooperMode.play);
      expect(cubit.state.defaultMode, LooperMode.record);
      expect(await settings.loadDefaultLooperMode(), isNull);
      await cubit.close();
    });

    // Two recorded (playing) tracks present before entering Play mode, so the
    // rec->play switch auto-arms channels 0 and 1.
    void addTwoPlayingTracks() => looperStates.add(
      _stateWith([
        const Track(state: TrackState.playing, lengthFrames: 48000),
        const Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
        for (var i = 2; i < 8; i++) Track(channel: i),
      ]),
    );

    // Two stopped (parked) recorded tracks, so Play-mode track presses arm
    // membership rather than muting.
    void addTwoStoppedTracks() => looperStates.add(
      _stateWith([
        const Track(state: TrackState.stopped, lengthFrames: 48000),
        const Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
        for (var i = 2; i < 8; i++) Track(channel: i),
      ]),
    );

    test('entering Play via setDefaultMode auto-arms content tracks', () async {
      final cubit = buildCubit();
      addTwoPlayingTracks();
      await pumpEventQueue();

      await cubit.setDefaultMode(LooperMode.play);

      expect(cubit.state.playArmed, {0, 1});
      await cubit.close();
    });

    test(
      'a parked Play-mode track press arms (green) / disarms (off)',
      () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        addTwoStoppedTracks();
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.mode.note, 100); // -> Play (arms 0,1)
        await pumpEventQueue();
        transport.sent.clear();

        // Parked: disarm ch0 (track1) — membership only, no transport change.
        transport.emit(0x90, PedalButton.track1.note, 100);
        await pumpEventQueue();
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        verifyNever(
          () => looper.setMute(
            muted: any(named: 'muted'),
            channel: any(named: 'channel'),
          ),
        );
        var frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.trackLeds[0], PedalTrackLed.off);
        expect(frame.trackLeds[1], PedalTrackLed.green);

        // Re-arm ch0: LED green again, still no transport change.
        transport.emit(0x90, PedalButton.track1.note, 100);
        await pumpEventQueue();
        frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.trackLeds[0], PedalTrackLed.green);

        // An empty track has nothing to arm.
        transport.emit(0x90, PedalButton.track3.note, 100);
        await pumpEventQueue();
        expect(cubit.state.playArmed, isNot(contains(2)));
        await cubit.close();
      },
    );

    test('a playing Play-mode track press mutes / unmutes the track', () async {
      final cubit = buildCubit();
      addTwoPlayingTracks(); // ch0, ch1 audible
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // -> Play (arms 0,1)
      await pumpEventQueue();

      // Playing: pressing track1 mutes ch0 (never stops it — ch1 keeps sound).
      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();
      verify(() => looper.setMute(muted: true)).called(1);
      verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

      // Reflect the mute, then press again -> unmute.
      looperStates.add(
        _stateWith([
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();
      verify(() => looper.setMute(muted: false)).called(1);
      await cubit.close();
    });

    test(
      'while playing, pressing an out-of-mix track joins it (arm + play)',
      () async {
        final cubit = buildCubit();
        // ch0 is playing; ch1 holds a loop but is parked (stopped) — out of the
        // running mix even after mode auto-arms it.
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.playing, lengthFrames: 48000),
            const Track(
              channel: 1,
              state: TrackState.stopped,
              lengthFrames: 48000,
            ),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.mode.note, 100); // Play, arms 0 and 1
        await pumpEventQueue();

        // Transport runs (ch0). Pressing ch1 — armed but parked, not live —
        // brings it into the mix (unmute + play) rather than muting a stopped
        // track.
        transport.emit(0x90, PedalButton.track2.note, 100);
        await pumpEventQueue();
        expect(cubit.state.playArmed, contains(1));
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.setMute(muted: true, channel: 1));
        await cubit.close();
      },
    );

    test('muting the last audible armed track parks the transport', () async {
      final cubit = buildCubit();
      // ch0 already muted; ch1 is the only audible armed track.
      looperStates.add(
        _stateWith([
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // -> Play (arms 0,1)
      await pumpEventQueue();

      // Mute ch1 (track2): nothing audible remains -> stop the loop AND disarm
      // everything (both LEDs go off).
      transport.emit(0x90, PedalButton.track2.note, 100);
      await pumpEventQueue();
      verify(() => looper.setMute(muted: true, channel: 1)).called(1);
      verify(() => looper.stopTrack()).called(1);
      verify(() => looper.stopTrack(channel: 1)).called(1);
      expect(cubit.state.playArmed, isEmpty);
      await cubit.close();
    });

    test('Stop in Play mode parks the armed set, keeping armed LEDs', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.stop.note, 100);
      await pumpEventQueue();
      verify(() => looper.stopTrack()).called(1);
      verify(() => looper.stopTrack(channel: 1)).called(1);
      verifyNever(() => looper.stopTrack(channel: 2));

      // Engine reflects the freeze (tracks stopped); armed LEDs stay green.
      looperStates.add(
        _stateWith([
          const Track(state: TrackState.stopped, lengthFrames: 48000),
          const Track(
            channel: 1,
            state: TrackState.stopped,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame!.trackLeds[0], PedalTrackLed.green);
      expect(frame.trackLeds[1], PedalTrackLed.green);
      await cubit.close();
    });

    test(
      'Rec/Play in Play mode resumes the armed set after a freeze',
      () async {
        final cubit = buildCubit();
        // Frozen (stopped) recorded tracks, as after a Stop.
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.stopped, lengthFrames: 48000),
            const Track(
              channel: 1,
              state: TrackState.stopped,
              lengthFrames: 48000,
            ),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
        await pumpEventQueue();

        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        await cubit.close();
      },
    );

    test(
      'Rec/Play in Play mode is a no-op when the whole content set is playing',
      () async {
        final cubit = buildCubit();
        addTwoPlayingTracks();
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
        await pumpEventQueue();

        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        // Both content tracks are already playing, so Rec/Play does nothing —
        // it no longer parks (parking is Stop's job now).
        verifyNever(() => looper.stopTrack());
        verifyNever(() => looper.stopTrack(channel: 1));
        await cubit.close();
      },
    );

    // Drives the reported scenario: record two loops, enter Play (auto-arms
    // both), then mute each — muting the last audible parks the transport and
    // disarms everything, leaving both tracks stopped + muted.
    Future<PedalCubit> parkedAfterMutingAll() async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // -> Play, arms 0,1
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.track1.note, 100); // mute ch0
      await pumpEventQueue();
      looperStates.add(
        _stateWith([
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      transport.emit(
        0x90,
        PedalButton.track2.note,
        100,
      ); // mute ch1: park+disarm
      await pumpEventQueue();
      looperStates.add(
        _stateWith([
          const Track(
            state: TrackState.stopped,
            muted: true,
            lengthFrames: 48000,
          ),
          const Track(
            channel: 1,
            state: TrackState.stopped,
            muted: true,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      return cubit;
    }

    test('arming a parked+muted track unmutes it so it reads green', () async {
      final cubit = await parkedAfterMutingAll();
      expect(cubit.state.playArmed, isEmpty); // stopped, nothing armed

      // Press track1: it arms ch0 and unmutes it (a park left it muted).
      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();
      expect(cubit.state.playArmed, contains(0));
      verify(() => looper.setMute(muted: false)).called(1);

      // Once the engine reflects the unmute, the LED reads green.
      looperStates.add(
        _stateWith([
          const Track(state: TrackState.stopped, lengthFrames: 48000),
          const Track(
            channel: 1,
            state: TrackState.stopped,
            muted: true,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();
      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame!.trackLeds[0], PedalTrackLed.green);
      await cubit.close();
    });

    test(
      'Rec/Play with nothing armed arms every content track and plays',
      () async {
        final cubit = await parkedAfterMutingAll();
        expect(cubit.state.playArmed, isEmpty);

        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        // Both recorded loops are armed and played; the empty tracks are not.
        expect(cubit.state.playArmed, {0, 1});
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        await cubit.close();
      },
    );

    test('externally emptied track drops from armed set', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
      await pumpEventQueue();
      transport.sent.clear();

      // Channel 0 is cleared from the on-screen UI (now empty); the pedal must
      // drop it from the armed set so its LED goes off.
      looperStates.add(
        _stateWith([
          const Track(), // ch0 emptied
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();

      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame!.trackLeds[0], PedalTrackLed.off);
      expect(frame.trackLeds[1], PedalTrackLed.green);
      await cubit.close();
    });

    test('Bank toggles the active bank and re-arms the cursor', () async {
      final cubit = buildCubit();
      transport.emit(0x90, PedalButton.bank.note, 100);
      await pumpEventQueue();

      // The cursor moves to bank B's first track; the presentation bridge
      // mirrors it onto the app (covered by pedal_cursor_bridge_test).
      expect(cubit.state.activeBank, 1);
      expect(cubit.state.selectedTrack, 4);
      await cubit.close();
    });

    test(
      'global_color carries the ring activity color (recording = red)',
      () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        transport.sent.clear();

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.recording),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame?.globalColor, GlobalColor.red);
        await cubit.close();
      },
    );

    test('reconnect re-binds the saved output across replugs', () async {
      await settings.savePedalOutputDevice(id: 'pedal', name: 'Pedal');
      transport.outputs = const []; // saved device absent at launch
      final cubit = buildCubit();
      await cubit.load();
      expect(cubit.state.boundOutputId, isNull);

      // Appears -> reconnect binds it.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, 'pedal');

      // Vanishes -> reconnect drops the stale handle.
      transport.outputs = const [];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, isNull);

      // Reappears -> reconnect re-binds without a relaunch.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, 'pedal');
      await cubit.close();
    });

    test('reconnect leaves an unpinned (None) output alone', () async {
      final cubit = buildCubit();
      await cubit.load(); // nothing saved -> no pinned device
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.boundOutputId, isNull);
      await cubit.close();
    });

    test('reconnect reflects the output set into state', () async {
      transport.outputs = const [];
      final cubit = buildCubit();
      await cubit.load();
      expect(cubit.state.availableOutputs, isEmpty);

      // Set changes -> the picker reads the new outputs off state.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      // The repository maps the transport's MidiDevice to a domain PedalOutput.
      expect(cubit.state.availableOutputs, const [
        PedalOutput(id: 'pedal', name: 'Pedal'),
      ]);

      // Vanishes -> state reflects the empty set again.
      transport.outputs = const [];
      cubit.reconnect();
      expect(cubit.state.availableOutputs, isEmpty);
      await cubit.close();
    });

    test('the encoder drives the master gain', () async {
      final cubit = buildCubit();
      transport.emit(0xB0, PedalCodec.encoderCc, 64 - 8); // -8 detents
      await pumpEventQueue();

      verify(() => looper.setMasterGain(any())).called(1);
      await cubit.close();
    });

    test('Undo tap undoes the armed track', () async {
      final cubit = buildCubit();
      transport
        ..emit(0x90, PedalButton.undo.note, 100) // press
        ..emit(0x80, PedalButton.undo.note, 0); // quick release == tap
      await pumpEventQueue();

      verify(() => looper.undo()).called(1);
      verifyNever(() => looper.redo(channel: any(named: 'channel')));
      await cubit.close();
    });

    test('Undo tap on a base-loop track undoes — never clears (the engine '
        'empties it redo-ably)', () async {
      final cubit = buildCubit();
      // A single-multiple recorded loop on the selected track: the old
      // behavior cleared it (losing redo); per-layer undo must undo.
      looperStates.add(
        _stateWith([
          const Track(state: TrackState.playing, lengthFrames: 48000),
          for (var i = 1; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();

      transport
        ..emit(0x90, PedalButton.undo.note, 100) // press
        ..emit(0x80, PedalButton.undo.note, 0); // quick release == tap
      await pumpEventQueue();

      verify(() => looper.undo()).called(1);
      verifyNever(() => looper.clear(channel: any(named: 'channel')));
      await cubit.close();
    });

    test('Clear wipes each recorded track and unmutes it', () async {
      final cubit = buildCubit();
      // Two recorded loops (ch0 muted), the rest empty.
      looperStates.add(
        _stateWith([
          const Track(
            state: TrackState.playing,
            muted: true,
            lengthFrames: 48000,
          ),
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
          ),
          for (var i = 2; i < 8; i++) Track(channel: i),
        ]),
      );
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.clear.note, 100);
      await pumpEventQueue();

      // Every content track is cleared and unmuted; empty tracks are untouched.
      verify(() => looper.clear()).called(1); // channel 0
      verify(() => looper.clear(channel: 1)).called(1);
      verifyNever(() => looper.clear(channel: 2));
      verify(() => looper.setMute(muted: false, channel: 1)).called(1);
      await cubit.close();
    });

    test('Clear LED lights while the footswitch is held and darkens on '
        'release', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      looperStates.add(_stateWith(_emptyTracks()));
      await pumpEventQueue();
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
      await cubit.close();
    });

    group('projection', () {
      test('pushes an encoded frame to the bound pedal', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        transport.sent.clear();

        // Rec mode (default): the armed track (0) is red; a playing non-armed
        // track is off (green-for-playing is a Play-mode concern).
        looperStates.add(
          _stateWith([
            const Track(), // track 0 (armed) -> red indicator
            const Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 48000,
            ),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame, isNotNull);
        expect(frame!.trackLeds[0], PedalTrackLed.red);
        expect(frame.trackLeds[1], PedalTrackLed.off);
        await cubit.close();
      });

      test('sends a loop-top pulse when the playhead wraps', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));

        looperStates.add(
          _stateWith(_emptyTracks(), masterPositionFrames: 40000),
        );
        await pumpEventQueue();
        transport.sent.clear();
        looperStates.add(_stateWith(_emptyTracks(), masterPositionFrames: 10));
        await pumpEventQueue();

        expect(
          transport.sent.any((m) => m.length == 1 && m.first == 0xFA),
          isTrue,
        );
        await cubit.close();
      });
    });

    test('close sends a goodbye frame to the bound pedal', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      transport.sent.clear();

      await cubit.close();

      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame?.isGoodbye, isTrue);
    });

    group('on-screen LED emulation API', () {
      test('bindStatus bound hides on-screen emulation in the view', () async {
        final cubit = buildCubit();
        expect(cubit.state.bindStatus, PedalBindStatus.none);

        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        await pumpEventQueue();
        expect(cubit.state.bindStatus, PedalBindStatus.bound);

        await cubit.close();
      });

      test('trackLedFor mirrors projection rules in Rec mode', () async {
        final cubit = buildCubit();
        looperStates.add(
          _stateWith([
            const Track(), // ch0 armed by default -> red
            const Track(channel: 1, state: TrackState.recording),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(cubit.trackLedFor(0), PedalTrackLed.red);
        expect(cubit.trackLedFor(1), PedalTrackLed.red);
        expect(cubit.trackLedFor(2), PedalTrackLed.off);

        cubit.selectTrack(2);
        expect(cubit.trackLedFor(2), PedalTrackLed.red);
        await cubit.close();
      });

      test('trackLedFor mirrors play-set membership in Play mode', () async {
        final cubit = buildCubit();
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.playing, lengthFrames: 48000),
            const Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 48000,
            ),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();
        cubit.toggleMode(); // -> Play, auto-arms 0 and 1
        await pumpEventQueue();

        expect(cubit.trackLedFor(0), PedalTrackLed.green);
        expect(cubit.trackLedFor(1), PedalTrackLed.green);

        cubit.togglePlayArm(0);
        expect(cubit.trackLedFor(0), PedalTrackLed.off);
        expect(cubit.trackLedFor(1), PedalTrackLed.green);
        await cubit.close();
      });

      test(
        'undo-to-empty darkens the LED and redo relights it in Play mode',
        () async {
          final cubit = buildCubit();
          looperStates.add(
            _stateWith([
              const Track(state: TrackState.playing, lengthFrames: 48000),
              for (var i = 1; i < 8; i++) Track(channel: i),
            ]),
          );
          await pumpEventQueue();
          cubit.toggleMode(); // -> Play, auto-arms track 0
          await pumpEventQueue();
          expect(cubit.trackLedFor(0), PedalTrackLed.green);

          // Undo past the base layer: the track empties (redo keeps the whole
          // history) and the armed set prunes it -> LED dark. The master grid
          // survives engine-side, so masterLengthFrames stays nonzero.
          looperStates.add(
            _stateWith([
              const Track(redoDepth: 2),
              for (var i = 1; i < 8; i++) Track(channel: i),
            ]),
          );
          await pumpEventQueue();
          expect(cubit.state.playArmed, isEmpty);
          expect(cubit.trackLedFor(0), PedalTrackLed.off);

          // Redo reinstates it (engine: EMPTY -> PLAYING): the reconciler
          // re-arms the track and the LED turns green again.
          looperStates.add(
            _stateWith([
              const Track(
                state: TrackState.playing,
                lengthFrames: 48000,
                redoDepth: 1,
              ),
              for (var i = 1; i < 8; i++) Track(channel: i),
            ]),
          );
          await pumpEventQueue();
          expect(cubit.state.playArmed, contains(0));
          expect(cubit.trackLedFor(0), PedalTrackLed.green);
          await cubit.close();
        },
      );

      test('a deliberate disarm of a still-playing track is respected — the '
          'reconciler only arms on the transition into sounding', () async {
        final cubit = buildCubit();
        final playing = _stateWith([
          const Track(state: TrackState.playing, lengthFrames: 48000),
          for (var i = 1; i < 8; i++) Track(channel: i),
        ]);
        looperStates.add(playing);
        await pumpEventQueue();
        cubit.toggleMode(); // -> Play, auto-arms track 0
        await pumpEventQueue();

        cubit.togglePlayArm(0); // on-screen disarm while it keeps playing
        expect(cubit.trackLedFor(0), PedalTrackLed.off);

        // The next looper poll must not re-arm it: no sounding transition.
        looperStates.add(playing);
        await pumpEventQueue();
        expect(cubit.state.playArmed, isNot(contains(0)));
        expect(cubit.trackLedFor(0), PedalTrackLed.off);
        await cubit.close();
      });

      test('a muted playing track does not auto-arm, so park-by-mute stays '
          'parked; unmuting it is a sounding edge that re-arms it', () async {
        final cubit = buildCubit();
        looperStates.add(_stateWith(_emptyTracks()));
        await pumpEventQueue();
        cubit.toggleMode(); // -> Play (nothing armed yet)
        await pumpEventQueue();

        // A muted-but-playing track (the park-by-mute in-flight window, or a
        // keyboard mute) must not slip into the armed set.
        looperStates.add(
          _stateWith([
            const Track(
              state: TrackState.playing,
              lengthFrames: 48000,
              muted: true,
            ),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();
        expect(cubit.state.playArmed, isNot(contains(0)));
        expect(cubit.trackLedFor(0), PedalTrackLed.off);

        // Unmuting it (e.g. from the screen) IS a fresh sounding transition:
        // the track re-enters pedal control and reads green.
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.playing, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();
        expect(cubit.state.playArmed, contains(0));
        expect(cubit.trackLedFor(0), PedalTrackLed.green);
        await cubit.close();
      });

      test('selectBank updates armed track to the bank base channel', () async {
        final cubit = buildCubit()..selectBank(1);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.selectedTrack, 4);
        await cubit.close();
      });

      test('selectTrack follows the cursor into its bank', () async {
        final cubit = buildCubit()..selectTrack(5); // bank B channel
        expect(cubit.state.selectedTrack, 5);
        expect(cubit.state.activeBank, 1);

        cubit.selectTrack(2); // back to bank A
        expect(cubit.state.selectedTrack, 2);
        expect(cubit.state.activeBank, 0);
        await cubit.close();
      });
    });
  });
}
