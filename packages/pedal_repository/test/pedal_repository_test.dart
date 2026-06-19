import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/fake_pedal_transport.dart';

void main() {
  group('PedalRepository', () {
    late FakePedalTransport transport;
    late PedalRepository repo;

    setUp(() {
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'pedal-out', name: 'Loopy Pedal')],
      );
      repo = PedalRepository(
        transport,
        clock: () => const Duration(milliseconds: 7),
      );
    });

    tearDown(() async => repo.dispose());

    group('events', () {
      test('decodes a button NoteOn into a stamped ButtonPressed', () async {
        final expectation = expectLater(
          repo.events,
          emits(
            const ButtonPressed(
              PedalButton.recPlay,
              timestamp: Duration(milliseconds: 7),
            ),
          ),
        );
        // recPlay note == 0, velocity > 0.
        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await expectation;
      });

      test('decodes a NoteOn velocity 0 as a release', () async {
        final expectation = expectLater(
          repo.events,
          emits(
            const ButtonReleased(
              PedalButton.stop,
              timestamp: Duration(milliseconds: 7),
            ),
          ),
        );
        transport.emit(0x90, PedalButton.stop.note, 0);
        await expectation;
      });

      test('decodes a relative encoder CC into an EncoderDelta', () async {
        final expectation = expectLater(
          repo.events,
          emits(const EncoderDelta(6)),
        );
        transport.emit(0xB0, PedalCodec.encoderCc, 64 + 6);
        await expectation;
      });

      test('drops messages that are not pedal input', () async {
        final received = <PedalEvent>[];
        final sub = repo.events.listen(received.add);
        // A CC on a non-encoder controller number is not pedal input.
        transport
          ..emit(0xB0, 0x7F, 1)
          ..emit(0x90, PedalButton.bank.note, 1); // a real one follows
        await pumpEventQueue();
        expect(received, [
          const ButtonPressed(
            PedalButton.bank,
            timestamp: Duration(milliseconds: 7),
          ),
        ]);
        await sub.cancel();
      });
    });

    group('bind', () {
      test('binds and sends an identity request on open', () async {
        final expectation = expectLater(
          repo.statusChanges,
          emitsInOrder([PedalBindStatus.connecting, PedalBindStatus.bound]),
        );

        repo.bind('pedal-out');

        expect(repo.status, PedalBindStatus.bound);
        expect(repo.boundOutputId, 'pedal-out');
        expect(transport.openedId, 'pedal-out');
        expect(transport.sent, hasLength(1));
        expect(transport.sent.single, PedalCodec.encodeIdentityRequest());
        await expectation;
      });

      test('reports error and stays unbound when the port fails', () async {
        transport.openResult = 3;
        final expectation = expectLater(
          repo.statusChanges,
          emitsInOrder([PedalBindStatus.connecting, PedalBindStatus.error]),
        );

        repo.bind('pedal-out');

        expect(repo.status, PedalBindStatus.error);
        expect(repo.boundOutputId, isNull);
        // No identity request on a failed bind.
        expect(transport.sent, isEmpty);
        await expectation;
      });
    });

    group('unbind', () {
      test('sends a goodbye frame, closes, and returns to none', () {
        repo
          ..bind('pedal-out')
          ..unbind();

        expect(repo.status, PedalBindStatus.none);
        expect(repo.boundOutputId, isNull);
        expect(transport.calls, contains('close'));
        // The last payload is the goodbye frame.
        expect(
          transport.sent.last,
          PedalCodec.encodeFrame(PedalStateFrame.blank(goodbye: true)),
        );
      });
    });

    group('pushState', () {
      test('encodes and sends the frame when bound', () {
        repo.bind('pedal-out');
        final framesBefore = transport.sent.length;
        final frame = PedalStateFrame.blank();

        repo.pushState(frame);

        expect(transport.sent.length, framesBefore + 1);
        expect(transport.sent.last, PedalCodec.encodeFrame(frame));
      });

      test('is a no-op when not bound', () {
        repo.pushState(PedalStateFrame.blank());
        expect(transport.sent, isEmpty);
      });
    });

    group('sendLoopTop', () {
      test('sends the single-byte pulse when bound', () {
        repo.bind('pedal-out');
        final before = transport.sent.length;

        repo.sendLoopTop();

        expect(transport.sent.length, before + 1);
        expect(transport.sent.last, [PedalCodec.loopTopPulse]);
      });

      test('is a no-op when not bound', () {
        repo.sendLoopTop();
        expect(transport.sent, isEmpty);
      });
    });

    test('availableOutputs delegates to the transport', () {
      expect(repo.availableOutputs(), transport.outputs);
      expect(transport.calls, contains('enumerate'));
    });

    group('dispose', () {
      test('disposes the transport and ignores later commands', () async {
        await repo.dispose();

        expect(transport.disposed, isTrue);
        // Commands after dispose are inert.
        repo
          ..bind('pedal-out')
          ..pushState(PedalStateFrame.blank());
        expect(repo.status, PedalBindStatus.none);

        // Idempotent.
        await repo.dispose();
      });
    });
  });
}
