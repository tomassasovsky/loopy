import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;

  setUp(() {
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    // No device open by default, so `arm` has no rig to resolve against and
    // leaves the selection alone — the state every test but the rig-shaped
    // ones below starts from.
    when(() => repository.state).thenReturn(const LooperState());
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() => states.close());

  TunerCubit build() => TunerCubit(repository: repository);

  LooperState reading(double hz, {double confidence = 1, int input = 0}) =>
      LooperState(
        tuner: TunerReading(hz: hz, confidence: confidence, input: input),
      );

  group('TunerCubit', () {
    test('does not arm the engine until the face opens', () {
      final cubit = build();
      addTearDown(cubit.close);

      verifyNever(() => repository.setTunerInput(input: any(named: 'input')));
      expect(cubit.state.isOpen, isFalse);
    });

    test('arming listens on the selected input; leaving disarms', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      verify(() => repository.setTunerInput(input: 0)).called(1);

      cubit.disarm();
      verify(() => repository.setTunerInput(input: -1)).called(1);
      expect(cubit.state.isOpen, isFalse);
    });

    test(
      'ignores readings while closed, so a shut face costs nothing',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        states.add(reading(110));
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.hasReading, isFalse);
      },
    );

    test('resolves a confident reading to a note', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      states.add(reading(110));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.pitch!.note, 'A');
      expect(cubit.state.pitch!.octave, 2);
      expect(cubit.state.pitch!.isInTune, isTrue);
      expect(cubit.state.hz, 110);
      expect(cubit.state.isStale, isFalse);
    });

    test('rejects a reading the engine is not confident about', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      states.add(reading(110, confidence: 0.2));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.hasReading, isFalse);
    });

    test('holds the last note between picks, then lets it go on the clock '
        'alone (regression: the repository emits only on CHANGE, so counting '
        '"no pitch" frames left the note up forever on a still rig)', () {
      fakeAsync((async) {
        final local = StreamController<LooperState>.broadcast();
        when(() => repository.looperState).thenAnswer((_) => local.stream);
        final cubit = build()..arm();

        local.add(reading(110));
        async.flushMicrotasks();
        expect(cubit.state.pitch!.note, 'A');

        // A gap: the string has decayed but the player is still on this note.
        // The reading is held, and flagged as held rather than fresh.
        local.add(reading(0));
        async.flushMicrotasks();
        expect(cubit.state.pitch!.note, 'A');
        expect(cubit.state.isStale, isTrue);

        // And this is the LAST event the cubit ever sees: a stopped transport
        // over a silent input projects the same LooperState every poll, and
        // `_poll` drops the duplicates. Time alone has to release the note —
        // a needle pointing at a note nobody is playing is worse than one that
        // admits it has nothing.
        async.elapse(TunerCubit.holdFor + const Duration(milliseconds: 1));
        expect(cubit.state.hasReading, isFalse);
        expect(cubit.state.isStale, isFalse);

        unawaited(cubit.close());
        unawaited(local.close());
        async.flushMicrotasks();
      });
    });

    test('ignores a reading the engine tagged with another input', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      cubit.selectInput(1);
      // The switch is queued but not yet consumed, so this frame still carries
      // input 0's pitch. Drawing it under input 1's tab would be a lie.
      states.add(reading(110));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.hasReading, isFalse);
    });

    test(
      're-pushes the arm when the engine says it is not listening '
      '(the command ring can drop one, and nothing else would notice)',
      () async {
        final cubit = build()..arm();
        addTearDown(cubit.close);
        verify(() => repository.setTunerInput(input: 0)).called(1);

        // The arm never landed: the engine reports itself disarmed on a rig
        // that plainly has inputs.
        states.add(
          const LooperState(status: EngineStatus(inputChannels: 2)),
        );
        await Future<void>.delayed(Duration.zero);
        verify(() => repository.setTunerInput(input: 0)).called(1);

        // Once it takes, the watchdog goes quiet rather than pushing per frame.
        states.add(
          const LooperState(
            status: EngineStatus(inputChannels: 2),
            tuner: TunerReading(hz: 110, confidence: 1, input: 0),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.pitch!.note, 'A');
        verifyNever(() => repository.setTunerInput(input: any(named: 'input')));
      },
    );

    test(
      're-pushes a dropped input SWITCH too, where the engine is still armed '
      'on the input before it and so never reads as disarmed',
      () async {
        final cubit = build()..arm();
        addTearDown(cubit.close);

        cubit.selectInput(1);
        verify(() => repository.setTunerInput(input: 1)).called(1);

        // The switch never landed: the engine is armed, just on the input the
        // player moved off. Readings for it are rightly refused — and refusing
        // them forever is what this re-push exists to prevent.
        states.add(
          const LooperState(
            status: EngineStatus(inputChannels: 2),
            tuner: TunerReading(hz: 110, confidence: 1),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.hasReading, isFalse);
        verify(() => repository.setTunerInput(input: 1)).called(1);
      },
    );

    test('never tunes a loopback capture, which carries our own output '
        'back — it folds onto the first channel that is real', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      // Four captures, the last pair being "Loop 1/2" on a Scarlett-class rig.
      // Input 0 is fine here, so nothing moves.
      states.add(
        const LooperState(
          status: EngineStatus(inputChannels: 4, excludedInputMask: 0xC),
          tuner: TunerReading(input: 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.input, 0);

      // A virtual loopback device is NOT positional — the mask comes from
      // channel names, so channel 0 itself can be excluded.
      states.add(
        const LooperState(
          status: EngineStatus(inputChannels: 4, excludedInputMask: 0x3),
          tuner: TunerReading(input: 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.input, 2);
      verify(() => repository.setTunerInput(input: 2)).called(1);
    });

    test('disarms rather than tuning anything when every capture on the '
        'rig is a loopback', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);
      verify(() => repository.setTunerInput(input: 0)).called(1);

      states.add(
        const LooperState(
          status: EngineStatus(inputChannels: 2, excludedInputMask: 0x3),
          tuner: TunerReading(input: 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.input, -1);
      expect(cubit.state.hasReading, isFalse);
      verify(() => repository.setTunerInput(input: -1)).called(1);

      // And it stays disarmed rather than thrashing the engine each frame.
      states.add(
        const LooperState(
          status: EngineStatus(inputChannels: 2, excludedInputMask: 0x3),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => repository.setTunerInput(input: any(named: 'input')));
    });

    test('folds a selection the rig no longer has back to the first '
        'socket, since the engine disarms an out-of-range input', () async {
      final cubit = build()..selectInput(5);
      addTearDown(cubit.close);
      cubit.arm();

      states.add(
        const LooperState(status: EngineStatus(inputChannels: 2)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.input, 0);
      verify(() => repository.setTunerInput(input: 0)).called(1);
    });

    test('switching input re-arms and drops the previous note', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      states.add(reading(110));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.hasReading, isTrue);

      cubit.selectInput(1);
      expect(cubit.state.input, 1);
      expect(cubit.state.hasReading, isFalse);
      verify(() => repository.setTunerInput(input: 1)).called(1);
    });

    test('selecting an input while closed does not arm the engine', () {
      final cubit = build()..selectInput(1);
      addTearDown(cubit.close);

      expect(cubit.state.input, 1);
      verifyNever(() => repository.setTunerInput(input: any(named: 'input')));
    });

    test('closing disarms, so no face leaves the engine analysing', () async {
      final cubit = build()..arm();
      await cubit.close();

      verify(() => repository.setTunerInput(input: -1)).called(1);
    });
  });
}
