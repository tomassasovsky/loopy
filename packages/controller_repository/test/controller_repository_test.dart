import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_controller_source.dart';

void main() {
  late FakeControllerSource source;

  setUp(() => source = FakeControllerSource());

  ControllerRepository build({ControllerMapping? mapping}) =>
      ControllerRepository(sources: [source], mapping: mapping);

  group('events', () {
    test('emits a mapped event for a press', () async {
      final repo = build();
      addTearDown(repo.dispose);
      final events = <ControllerEvent>[];
      repo.events.listen(events.add);

      source.press(ControllerSourceKind.midiCc, 80);
      await Future<void>.delayed(Duration.zero);

      expect(events, [
        const ControllerEvent(action: LooperAction.recordOverdub),
      ]);
    });

    test('does not emit for an unmapped or released control', () async {
      final repo = build();
      addTearDown(repo.dispose);
      final events = <ControllerEvent>[];
      repo.events.listen(events.add);

      source
        ..press(ControllerSourceKind.midiNote, 80) // unmapped
        ..emit(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 80,
            value: 0, // release
          ),
        );
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
    });

    test('merges inputs from multiple sources', () async {
      final second = FakeControllerSource();
      final repo = ControllerRepository(
        sources: [source, second],
        mapping: const ControllerMapping().withBinding(
          const MappingTrigger(kind: ControllerSourceKind.midiNote, id: 36),
          LooperAction.stop,
          channel: 3,
        ),
      );
      addTearDown(repo.dispose);
      final events = <ControllerEvent>[];
      repo.events.listen(events.add);

      second.press(ControllerSourceKind.midiNote, 36, value: 1);
      await Future<void>.delayed(Duration.zero);

      expect(events, [
        const ControllerEvent(action: LooperAction.stop, channel: 3),
      ]);
    });
  });

  group('MIDI-learn', () {
    test('captures the next press and suppresses its event', () async {
      final repo = build();
      addTearDown(repo.dispose);
      final events = <ControllerEvent>[];
      repo.events.listen(events.add);

      final learned = repo.learnNext();
      expect(repo.isLearning, isTrue);

      source.press(ControllerSourceKind.midiCc, 80);
      final input = await learned;

      expect(input?.trigger.id, 80);
      expect(repo.isLearning, isFalse);
      // The captured press did not produce an event.
      expect(events, isEmpty);
    });

    test('bind updates the mapping and emits the change', () async {
      final repo = build(mapping: const ControllerMapping());
      addTearDown(repo.dispose);
      final mappings = <ControllerMapping>[];
      repo.mappingChanges.listen(mappings.add);

      const trigger = MappingTrigger(
        kind: ControllerSourceKind.midiNote,
        id: 60,
      );
      repo.bind(trigger, LooperAction.recordOverdub, channel: 1);
      await Future<void>.delayed(Duration.zero);

      expect(mappings, hasLength(1));
      final events = <ControllerEvent>[];
      repo.events.listen(events.add);
      source.press(ControllerSourceKind.midiNote, 60);
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        const ControllerEvent(action: LooperAction.recordOverdub, channel: 1),
      ]);
    });

    test('a superseded learn completes with null', () async {
      final repo = build();
      addTearDown(repo.dispose);

      final first = repo.learnNext();
      unawaited(repo.learnNext()); // supersede
      expect(await first, isNull);
    });

    test('cancelLearn completes the pending capture with null', () async {
      final repo = build();
      addTearDown(repo.dispose);

      final learned = repo.learnNext();
      repo.cancelLearn();
      expect(await learned, isNull);
      expect(repo.isLearning, isFalse);
    });
  });

  group('dispose', () {
    test('disposes its sources', () async {
      final repo = build();
      await repo.dispose();
      expect(source.disposed, isTrue);
    });
  });
}
