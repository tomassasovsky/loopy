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

        expect(cubit.state.armedTrack, 2); // track3 == channel 2 in bank A
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
      expect(cubit.state.armedTrack, 2);
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

    test('a Play-mode track press arms (green) / disarms (off)', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // -> Play (arms 0,1)
      await pumpEventQueue();
      transport.sent.clear();

      // Disarm ch0 (track1 button): stops it, LED off; ch1 stays armed (green).
      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();
      verify(() => looper.stopTrack()).called(1);
      var frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame!.trackLeds[0], PedalTrackLed.off);
      expect(frame.trackLeds[1], PedalTrackLed.green);

      // Re-arm ch0: plays it, LED green again.
      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();
      verify(() => looper.play()).called(1);
      frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame!.trackLeds[0], PedalTrackLed.green);

      // An empty track has nothing to arm.
      transport.emit(0x90, PedalButton.track3.note, 100);
      await pumpEventQueue();
      verifyNever(() => looper.play(channel: 2));
      await cubit.close();
    });

    test('Stop in Play mode freezes all tracks but keeps armed LEDs', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
      addTwoPlayingTracks();
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.mode.note, 100); // auto-arms 0, 1
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.stop.note, 100);
      await pumpEventQueue();
      for (var channel = 0; channel < 8; channel++) {
        verify(() => looper.stopTrack(channel: channel)).called(1);
      }

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
      await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
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
        expect(cubit.state.armedTrack, 4); // first track of bank B
        expect(bankSelections, [1]);
        expect(trackSelections, [4]); // selection follows to bank B's track 1
        await cubit.close();
      },
    );

    test(
      'global_color carries the ring activity color (recording = red)',
      () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
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
      expect(cubit.boundOutputId, isNull);

      // Appears -> reconnect binds it.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.boundOutputId, 'pedal');

      // Vanishes -> reconnect drops the stale handle.
      transport.outputs = const [];
      cubit.reconnect();
      expect(cubit.boundOutputId, isNull);

      // Reappears -> reconnect re-binds without a relaunch.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.boundOutputId, 'pedal');
      await cubit.close();
    });

    test('reconnect leaves an unpinned (None) output alone', () async {
      final cubit = buildCubit();
      await cubit.load(); // nothing saved -> no pinned device
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.boundOutputId, isNull);
      await cubit.close();
    });

    test('reconnect bumps outputsTick only on output-set changes', () async {
      transport.outputs = const [];
      final cubit = buildCubit();
      await cubit.load();
      final t0 = cubit.state.outputsTick;

      // Same (empty) set -> no refresh.
      cubit.reconnect();
      expect(cubit.state.outputsTick, t0);

      // Set changes -> picker refresh tick bumps.
      transport.outputs = const [MidiDevice(id: 'pedal', name: 'Pedal')];
      cubit.reconnect();
      expect(cubit.state.outputsTick, greaterThan(t0));

      // Unchanged again -> no further bump.
      final t1 = cubit.state.outputsTick;
      cubit.reconnect();
      expect(cubit.state.outputsTick, t1);
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
        expect(cubit.state.armedTrack, 0);
        expect(bankSelections, [0]);
        expect(trackSelections, [0]);
        await cubit.close();
      },
    );

    group('projection', () {
      test('pushes an encoded frame to the bound pedal', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
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
        await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));

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
      await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
      transport.sent.clear();

      await cubit.close();

      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame?.isGoodbye, isTrue);
    });
  });
}
