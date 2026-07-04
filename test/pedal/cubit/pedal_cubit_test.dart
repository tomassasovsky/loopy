import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
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

/// The pedal LINK tests: MIDI decode into [ControlIntents], output binding +
/// hotplug, press timing (undo tap/long-press, the held Clear LED), and the
/// projected frame push. The control BEHAVIOR the decoded intents produce is
/// covered by test/control/ — here the intents layer is real but the looper
/// is mocked, so assertions verify the decoded command, not looper semantics.
void main() {
  group('PedalCubit', () {
    late FakePedalTransport transport;
    late PedalRepository pedal;
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;
    late ControlOverlay overlay;
    late ControlIntents intents;

    void setEngine(LooperState state) {
      when(() => looper.state).thenReturn(state);
      looperStates.add(state);
    }

    setUp(() {
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast();
      settings = SettingsRepository(store: FakeKeyValueStore());

      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      when(() => looper.state).thenReturn(_stateWith(_emptyTracks()));
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

      overlay = ControlOverlay(looper: looper);
      intents = ControlIntents(
        looper: looper,
        overlay: overlay,
        settings: settings,
      );
    });

    tearDown(() async {
      await overlay.dispose();
    });

    PedalCubit buildCubit() => PedalCubit(
      pedal: pedal,
      looper: looper,
      overlay: overlay,
      intents: intents,
      settings: settings,
      pollInterval: Duration.zero, // tests drive reconnect() directly
    );

    test('Rec/Play decodes into the record intent on the cursor', () async {
      final cubit = buildCubit();
      transport.emit(0x90, PedalButton.recPlay.note, 100);
      await pumpEventQueue();

      verify(() => looper.record()).called(1);
      await cubit.close();
    });

    test('Stop decodes into the stop intent (Rec mode mutes)', () async {
      final cubit = buildCubit();
      setEngine(_stateWith(_emptyTracks()));
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.stop.note, 100);
      await pumpEventQueue();

      verify(() => looper.setMute(muted: true)).called(1);
      await cubit.close();
    });

    test('Mode toggles the shared overlay mode', () async {
      final cubit = buildCubit();
      expect(overlay.state.mode, LooperMode.record);

      transport.emit(0x90, PedalButton.mode.note, 100);
      await pumpEventQueue();

      expect(overlay.state.mode, LooperMode.play);
      await cubit.close();
    });

    test('Bank toggles the active bank and moves the shared cursor', () async {
      final cubit = buildCubit();
      transport.emit(0x90, PedalButton.bank.note, 100);
      await pumpEventQueue();

      expect(overlay.state.activeBank, 1);
      expect(overlay.state.cursor, 4);
      await cubit.close();
    });

    test('a track press targets the visible bank base', () async {
      final cubit = buildCubit();
      setEngine(_stateWith(_emptyTracks()));
      await pumpEventQueue();

      transport.emit(0x90, PedalButton.bank.note, 100); // -> bank B
      await pumpEventQueue();
      transport.emit(0x90, PedalButton.track3.note, 100);
      await pumpEventQueue();

      // track3 == index 2, bank B base 4 -> channel 6 (idle press selects).
      expect(overlay.state.cursor, 6);
      await cubit.close();
    });

    test('the encoder drives the master gain', () async {
      final cubit = buildCubit();
      transport.emit(0xB0, PedalCodec.encoderCc, 64 - 8); // -8 detents
      await pumpEventQueue();

      verify(() => looper.setMasterGain(any())).called(1);
      await cubit.close();
    });

    group('undo press timing', () {
      test('tap undoes the cursor track', () async {
        final cubit = buildCubit();
        transport
          ..emit(0x90, PedalButton.undo.note, 100) // press
          ..emit(0x80, PedalButton.undo.note, 0); // quick release == tap
        await pumpEventQueue();

        verify(() => looper.undo()).called(1);
        verifyNever(() => looper.redo(channel: any(named: 'channel')));
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
        await cubit.close();
      });

      test('the undo target is latched at press time', () async {
        final cubit = buildCubit();
        transport.emit(0x90, PedalButton.undo.note, 100); // press on cursor 0
        await pumpEventQueue();
        // An on-screen click mid-hold must not retarget the committed action.
        overlay.selectTrack(3);
        transport.emit(0x80, PedalButton.undo.note, 0);
        await pumpEventQueue();

        verify(() => looper.undo()).called(1); // channel 0, not 3
        verifyNever(() => looper.undo(channel: 3));
        await cubit.close();
      });

      test('long-press redoes instead', () async {
        final cubit = buildCubit();
        transport.emit(0x90, PedalButton.undo.note, 100);
        // Default long-press threshold is 500 ms.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.emit(0x80, PedalButton.undo.note, 0);
        await pumpEventQueue();

        verify(() => looper.redo()).called(1);
        verifyNever(() => looper.undo(channel: any(named: 'channel')));
        await cubit.close();
      });
    });

    test(
      'Clear decodes into clear-all: wipe + unmute + overlay home',
      () async {
        final cubit = buildCubit();
        setEngine(
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

        verify(() => looper.clear()).called(1);
        verify(() => looper.clear(channel: 1)).called(1);
        verifyNever(() => looper.clear(channel: 2));
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(overlay.state.mode, LooperMode.record);
        expect(overlay.state.cursor, 0);
        await cubit.close();
      },
    );

    test('Clear LED lights while the footswitch is held and darkens on '
        'release', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      setEngine(_stateWith(_emptyTracks()));
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

    group('output binding + hotplug', () {
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
        // The repository maps the transport MidiDevice to a domain
        // PedalOutput.
        expect(cubit.state.availableOutputs, const [
          PedalOutput(id: 'pedal', name: 'Pedal'),
        ]);

        // Vanishes -> state reflects the empty set again.
        transport.outputs = const [];
        cubit.reconnect();
        expect(cubit.state.availableOutputs, isEmpty);
        await cubit.close();
      });

      test('bindStatus reflects the bound output', () async {
        final cubit = buildCubit();
        expect(cubit.state.bindStatus, PedalBindStatus.none);

        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        await pumpEventQueue();
        expect(cubit.state.bindStatus, PedalBindStatus.bound);
        await cubit.close();
      });
    });

    group('projection push', () {
      test('pushes an encoded frame to the bound pedal', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        transport.sent.clear();

        // Rec mode (default): the cursor track (0) is red; a playing
        // non-cursor track is off (green-for-playing is a Play-mode concern).
        setEngine(
          _stateWith([
            const Track(), // track 0 (cursor) -> red indicator
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

      test('an overlay change re-projects without a looper tick', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        setEngine(_stateWith(_emptyTracks()));
        await pumpEventQueue();
        transport.sent.clear();

        overlay.selectTrack(3); // cursor moves -> the red LED must follow
        await pumpEventQueue();

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.selectedTrack, 3);
        expect(frame.trackLeds[3], PedalTrackLed.red);
        expect(frame.trackLeds[0], PedalTrackLed.off);
        await cubit.close();
      });

      test('a rebind force-pushes the CURRENT overlay', () async {
        final cubit = buildCubit();
        setEngine(_stateWith(_emptyTracks()));
        await pumpEventQueue();

        // Mode changes while unbound; the frame on (re)bind must carry it.
        intents.toggleMode();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
        await pumpEventQueue();

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.mode, PedalMode.play);
        await cubit.close();
      });

      test('sends a loop-top pulse when the playhead wraps', () async {
        final cubit = buildCubit();
        await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));

        setEngine(_stateWith(_emptyTracks(), masterPositionFrames: 40000));
        await pumpEventQueue();
        transport.sent.clear();
        setEngine(_stateWith(_emptyTracks(), masterPositionFrames: 10));
        await pumpEventQueue();

        expect(
          transport.sent.any((m) => m.length == 1 && m.first == 0xFA),
          isTrue,
        );
        await cubit.close();
      });

      test(
        'global_color carries the ring activity color (recording = red)',
        () async {
          final cubit = buildCubit();
          await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
          transport.sent.clear();

          setEngine(
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
    });

    test(
      'trackLedFor exposes the pure projection for the on-screen pedal',
      () async {
        final cubit = buildCubit();
        setEngine(
          _stateWith([
            const Track(), // ch0 cursor by default -> red
            const Track(channel: 1, state: TrackState.recording),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(cubit.trackLedFor(0), PedalTrackLed.red);
        expect(cubit.trackLedFor(1), PedalTrackLed.red);
        expect(cubit.trackLedFor(2), PedalTrackLed.off);

        overlay.selectTrack(2);
        expect(cubit.trackLedFor(2), PedalTrackLed.red);
        await cubit.close();
      },
    );

    test('close sends a goodbye frame to the bound pedal', () async {
      final cubit = buildCubit();
      await cubit.selectOutput(const PedalOutput(id: 'out', name: 'Pedal'));
      transport.sent.clear();

      await cubit.close();

      final frame = PedalCodec.decodeFrame(transport.sent.last);
      expect(frame?.isGoodbye, isTrue);
    });
  });
}
