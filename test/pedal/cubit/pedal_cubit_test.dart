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

    test('a Play-mode track press toggles mute', () async {
      final cubit = buildCubit();
      transport.emit(0x90, PedalButton.mode.note, 100); // -> Play
      looperStates.add(_stateWith(_emptyTracks()));
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.track1.note, 100);
      await pumpEventQueue();

      verify(() => looper.setMute(muted: true)).called(1);
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

    test('Clear with the fade disabled erases every track', () async {
      await settings.savePedalClearFadeMs(0);
      final cubit = buildCubit();
      await cubit.load();

      transport.emit(0x90, PedalButton.clear.note, 100);
      await pumpEventQueue();

      for (var channel = 0; channel < 8; channel++) {
        verify(() => looper.clear(channel: channel)).called(1);
      }
      await cubit.close();
    });

    test(
      'Clear with a fade enters the abort window, a 2nd Clear aborts it',
      () async {
        final cubit = buildCubit();
        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();
        expect(cubit.state.clearFadeActive, isTrue);

        transport.emit(0x90, PedalButton.clear.note, 100); // 2nd clear aborts
        await pumpEventQueue();
        expect(cubit.state.clearFadeActive, isFalse);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
        await cubit.close();
      },
    );

    group('projection', () {
      test('pushes an encoded frame to the bound pedal', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const MidiDevice(id: 'out', name: 'Pedal'));
        transport.sent.clear();

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
        // Track 1 is playing and not armed -> green; the armed track 0 -> red.
        expect(frame!.trackLeds[1], PedalTrackLed.green);
        expect(frame.trackLeds[0], PedalTrackLed.red);
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
