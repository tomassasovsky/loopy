import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LooperAction.isChannelScoped', () {
    test('channel actions are scoped; transport actions are not', () {
      expect(LooperAction.recordOverdub.isChannelScoped, isTrue);
      expect(LooperAction.undo.isChannelScoped, isTrue);
      expect(LooperAction.playAll.isChannelScoped, isFalse);
      expect(LooperAction.stopAll.isChannelScoped, isFalse);
    });
  });

  group('ControllerMapping.resolve', () {
    final mapping = ControllerMapping.defaults();

    test('resolves a mapped press to its action', () {
      const input = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 127,
      );
      expect(
        mapping.resolve(input),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
    });

    test('returns null for a release (value 0)', () {
      const release = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 0,
      );
      expect(mapping.resolve(release), isNull);
    });

    test('returns null for an unmapped trigger', () {
      const input = RawControllerInput(
        kind: ControllerSourceKind.midiNote,
        id: 80,
        value: 127,
      );
      expect(mapping.resolve(input), isNull);
    });
  });

  group('ControllerMapping.withBinding', () {
    test('replaces the entry for an existing trigger', () {
      const trigger = MappingTrigger(
        kind: ControllerSourceKind.midiCc,
        id: 80,
      );
      final remapped = ControllerMapping.defaults().withBinding(
        trigger,
        LooperAction.stopAll,
        channel: 2,
      );

      const press = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 1,
      );
      expect(
        remapped.resolve(press),
        const ControllerEvent(action: LooperAction.stopAll, channel: 2),
      );
      // The original mapping is unchanged (immutability).
      expect(
        ControllerMapping.defaults().resolve(press),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
    });

    test('adds a new entry for an unseen trigger', () {
      const trigger = MappingTrigger(
        kind: ControllerSourceKind.gpio,
        id: 17,
      );
      final mapping = const ControllerMapping().withBinding(
        trigger,
        LooperAction.recordOverdub,
        channel: 1,
      );
      const press = RawControllerInput(
        kind: ControllerSourceKind.gpio,
        id: 17,
        value: 1,
      );
      expect(
        mapping.resolve(press),
        const ControllerEvent(action: LooperAction.recordOverdub, channel: 1),
      );
    });
  });
}
