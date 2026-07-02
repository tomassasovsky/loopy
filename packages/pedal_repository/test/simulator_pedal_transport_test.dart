import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart';

/// A controllable inner [PedalTransport]: push inbound with [emit], inspect
/// outbound in [sent], and configure the enumerated outputs + open result.
class _FakeInner implements PedalTransport {
  List<MidiDevice> outputs = const [];
  int openResult = 0;

  final StreamController<PedalRawMessage> _input =
      StreamController<PedalRawMessage>.broadcast();
  final List<Uint8List> sent = [];
  int openCalls = 0;
  int closeCalls = 0;
  bool disposed = false;

  void emit(PedalRawMessage message) => _input.add(message);

  @override
  Stream<PedalRawMessage> get input => _input.stream;

  @override
  List<MidiDevice> enumerateOutputs() => outputs;

  @override
  int openOutput(String id) {
    openCalls++;
    return openResult;
  }

  @override
  int closeOutput() {
    closeCalls++;
    return 0;
  }

  @override
  int send(Uint8List bytes) {
    sent.add(bytes);
    return 0;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _input.close();
  }
}

PedalStateFrame _sampleFrame() => PedalStateFrame(
  globalColor: GlobalColor.amber,
  trackLeds: List<PedalTrackLed>.filled(
    PedalStateFrame.trackCount,
    PedalTrackLed.green,
  ),
  activeBank: 1,
  selectedTrack: 3,
  mode: PedalMode.play,
  loopLengthMicros: 1000,
  clearFadeActive: false,
);

void main() {
  group('SimulatorPedalTransport', () {
    late _FakeInner inner;
    late SimulatorPedalTransport transport;

    setUp(() {
      inner = _FakeInner();
      transport = SimulatorPedalTransport(inner: inner);
    });

    tearDown(() => transport.dispose());

    group('enumerateOutputs', () {
      test('always appends the simulator device', () {
        expect(transport.enumerateOutputs(), [
          const MidiDevice(id: kSimulatorOutputId, name: 'On-screen pedal'),
        ]);
      });

      test('keeps real outputs and appends the simulator last', () {
        inner.outputs = const [MidiDevice(id: 'real', name: 'Real Pedal')];
        final outputs = transport.enumerateOutputs();
        expect(outputs.map((d) => d.id), ['real', kSimulatorOutputId]);
      });

      test('drops a real device masquerading as the reserved id', () {
        inner.outputs = const [
          MidiDevice(id: kSimulatorOutputId, name: 'Imposter'),
        ];
        final sims = transport.enumerateOutputs().where(
          (d) => d.id == kSimulatorOutputId,
        );
        expect(sims, hasLength(1));
        expect(sims.single.name, 'On-screen pedal');
      });
    });

    group('binding', () {
      test('openOutput(sim) succeeds and closes the inner port', () {
        expect(transport.openOutput(kSimulatorOutputId), 0);
        expect(inner.closeCalls, 1);
        expect(inner.openCalls, 0);
      });

      test('openOutput(real) delegates to the inner transport', () {
        inner.openResult = 0;
        expect(transport.openOutput('real'), 0);
        expect(inner.openCalls, 1);
      });

      test('openOutput(real) surfaces the inner failure code', () {
        inner.openResult = 1;
        expect(transport.openOutput('real'), 1);
      });
    });

    group('send', () {
      test('renders decoded frames on frame when bound to the simulator', () {
        transport.openOutput(kSimulatorOutputId);
        final frame = _sampleFrame();
        transport.send(PedalCodec.encodeFrame(frame));
        expect(transport.frame.value, frame);
        expect(inner.sent, isEmpty);
      });

      test('ignores the loop-top pulse (frame stays blank)', () {
        transport
          ..openOutput(kSimulatorOutputId)
          ..send(PedalCodec.encodeLoopTop());
        expect(transport.frame.value, PedalStateFrame.blank());
      });

      test('delegates to the inner transport when a real device is bound', () {
        transport.openOutput('real');
        final bytes = PedalCodec.encodeFrame(_sampleFrame());
        transport.send(bytes);
        expect(inner.sent, [bytes]);
        expect(transport.frame.value, PedalStateFrame.blank());
      });
    });

    group('injection', () {
      test('frame is seeded with a blank frame', () {
        expect(transport.frame.value, PedalStateFrame.blank());
      });

      test('press emits NoteOn on down and NoteOff on up', () async {
        final seen = <PedalRawMessage>[];
        final sub = transport.input.listen(seen.add);

        transport
          ..press(PedalButton.recPlay, down: true)
          ..press(PedalButton.recPlay, down: false);
        await pumpEventQueue();

        expect(seen, [
          (status: 0x90, data1: PedalButton.recPlay.note, data2: 100),
          (status: 0x80, data1: PedalButton.recPlay.note, data2: 0),
        ]);
        await sub.cancel();
      });

      test('turn emits a clamped encoder CC', () async {
        final seen = <PedalRawMessage>[];
        final sub = transport.input.listen(seen.add);

        transport
          ..turn(5)
          ..turn(200) // clamps to +63
          ..turn(-200); // clamps to -64
        await pumpEventQueue();

        expect(seen, [
          (status: 0xB0, data1: PedalCodec.encoderCc, data2: 64 + 5),
          (status: 0xB0, data1: PedalCodec.encoderCc, data2: 127),
          (status: 0xB0, data1: PedalCodec.encoderCc, data2: 0),
        ]);
        await sub.cancel();
      });

      test('releaseAll sends NoteOff for every held button', () async {
        transport
          ..press(PedalButton.undo, down: true)
          ..press(PedalButton.stop, down: true);
        final seen = <PedalRawMessage>[];
        final sub = transport.input.listen(seen.add);

        transport.releaseAll();
        await pumpEventQueue();

        expect(seen, hasLength(2));
        expect(seen.every((m) => m.status == 0x80 && m.data2 == 0), isTrue);
        expect(
          seen.map((m) => m.data1).toSet(),
          {PedalButton.undo.note, PedalButton.stop.note},
        );

        // Nothing left held: a second releaseAll emits nothing.
        seen.clear();
        transport.releaseAll();
        await pumpEventQueue();
        expect(seen, isEmpty);
        await sub.cancel();
      });

      test('input merges inner messages with injected ones', () async {
        final seen = <PedalRawMessage>[];
        final sub = transport.input.listen(seen.add);

        inner.emit((status: 0x90, data1: 7, data2: 100));
        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();

        expect(seen, contains((status: 0x90, data1: 7, data2: 100)));
        expect(
          seen,
          contains((status: 0x90, data1: PedalButton.stop.note, data2: 100)),
        );
        await sub.cancel();
      });
    });

    group('dispose', () {
      test('is idempotent and disposes the inner transport', () async {
        await transport.dispose();
        await transport.dispose(); // no throw on second dispose
        expect(inner.disposed, isTrue);
      });

      test('press/turn are no-ops after dispose', () async {
        final seen = <PedalRawMessage>[];
        final sub = transport.input.listen(seen.add);
        await transport.dispose();
        // Must not throw (stream is closed) and must not emit.
        transport
          ..press(PedalButton.recPlay, down: true)
          ..turn(1);
        await pumpEventQueue();
        expect(seen, isEmpty);
        await sub.cancel();
      });
    });
  });
}
