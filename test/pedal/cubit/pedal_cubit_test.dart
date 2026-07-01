import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
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
    late List<int> bankSelections;
    late List<int> trackSelections;

    setUp(() {
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast();
      settings = SettingsRepository(store: FakeKeyValueStore());
      bankSelections = [];
      trackSelections = [];

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
      onBankSelected: bankSelections.add,
      onTrackSelected: trackSelections.add,
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
        expect(trackSelections, [2]); // mirrored to loopy's on-screen selection
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

    test('Mode toggles between Rec and Play', () async {
      final cubit = buildCubit();
      expect(cubit.state.mode, PedalMode.rec);

      transport.emit(0x90, PedalButton.mode.note, 100);
      await pumpEventQueue();

      expect(cubit.state.mode, PedalMode.play);
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

      // Mute ch1 (track2): nothing audible remains -> park the armed set.
      transport.emit(0x90, PedalButton.track2.note, 100);
      await pumpEventQueue();
      verify(() => looper.setMute(muted: true, channel: 1)).called(1);
      verify(() => looper.stopTrack()).called(1);
      verify(() => looper.stopTrack(channel: 1)).called(1);
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

    test('Rec/Play in Play mode freezes the armed set when playing', () async {
      final cubit = buildCubit();
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.recPlay.note, 100);
      await pumpEventQueue();
      verify(() => looper.stopTrack()).called(1);
      verify(() => looper.stopTrack(channel: 1)).called(1);
      await cubit.close();
    });

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

    test(
      'Bank toggles the active bank, re-arms, and syncs the BankCubit',
      () async {
        final cubit = buildCubit();
        transport.emit(0x90, PedalButton.bank.note, 100);
        await pumpEventQueue();

        expect(cubit.state.activeBank, 1);
        expect(cubit.state.selectedTrack, 4); // first track of bank B
        expect(bankSelections, [1]);
        expect(trackSelections, [4]); // selection follows to bank B's track 1
        await cubit.close();
      },
    );

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

    test(
      'Clear erases every track instantly and re-arms the first track',
      () async {
        final cubit = buildCubit();
        await cubit.load();

        // Start on bank B so we can prove Clear resets to bank A, track 1.
        transport.emit(0x90, PedalButton.bank.note, 100);
        await pumpEventQueue();
        bankSelections.clear();
        trackSelections.clear();

        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();

        // Every track erased immediately — no fade wait.
        for (var channel = 0; channel < 8; channel++) {
          verify(() => looper.clear(channel: channel)).called(1);
        }
        // Re-armed bank A, track 1 (channel 0), mirrored to loopy's UI.
        expect(cubit.state.activeBank, 0);
        expect(cubit.state.selectedTrack, 0);
        expect(bankSelections, [0]);
        expect(trackSelections, [0]);
        await cubit.close();
      },
    );

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

      test('selectBank updates armed track to the bank base channel', () async {
        final cubit = buildCubit()..selectBank(1);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.selectedTrack, 4);
        await cubit.close();
      });
    });
  });
}
