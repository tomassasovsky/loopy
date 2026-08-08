import 'dart:async';

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

    test('holds the last note between picks, then lets it go', () async {
      final cubit = build()..arm();
      addTearDown(cubit.close);

      states.add(reading(110));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.pitch!.note, 'A');

      // A gap: the string has decayed but the player is still on this note.
      // The reading is held, and flagged as held rather than fresh.
      states.add(reading(0));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.pitch!.note, 'A');
      expect(cubit.state.isStale, isTrue);

      // Long enough and it clears: a needle pointing at a note nobody is
      // playing is worse than one that admits it has nothing.
      final frames = TunerCubit.holdFor.inMilliseconds ~/ 16;
      for (var i = 0; i < frames + 1; i++) {
        states.add(reading(0));
        await Future<void>.delayed(Duration.zero);
      }
      expect(cubit.state.hasReading, isFalse);
      expect(cubit.state.isStale, isFalse);
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
