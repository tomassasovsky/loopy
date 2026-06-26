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

  group('ControllerMapping.gpioDefaults', () {
    final mapping = ControllerMapping.gpioDefaults();

    test('binds GPIO footswitch pins to transport actions', () {
      const press = RawControllerInput(
        kind: ControllerSourceKind.gpio,
        id: 17,
        value: 1,
      );
      expect(
        mapping.resolve(press),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
    });

    test('every entry is a GPIO trigger', () {
      expect(
        mapping.entries.every(
          (e) => e.trigger.kind == ControllerSourceKind.gpio,
        ),
        isTrue,
      );
    });

    test('covers the default transport actions plus the encoder press', () {
      final actions = mapping.entries.map((e) => e.action).toSet();
      // The four footswitches mirror the MIDI defaults...
      expect(
        actions,
        containsAll(
          ControllerMapping.defaults().entries.map((e) => e.action),
        ),
      );
      // ...and the encoder push-switch adds a global play-all.
      expect(actions, contains(LooperAction.playAll));
    });

    test('binds the encoder push-switch to play-all', () {
      const press = RawControllerInput(
        kind: ControllerSourceKind.gpio,
        id: 26,
        value: 1,
      );
      expect(
        mapping.resolve(press),
        const ControllerEvent(action: LooperAction.playAll),
      );
    });
  });

  group('ControllerMapping.merge', () {
    test('combines MIDI and GPIO defaults so both resolve', () {
      final merged = ControllerMapping.defaults().merge(
        ControllerMapping.gpioDefaults(),
      );

      const midiPress = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 127,
      );
      const gpioPress = RawControllerInput(
        kind: ControllerSourceKind.gpio,
        id: 17,
        value: 1,
      );
      expect(
        merged.resolve(midiPress),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
      expect(
        merged.resolve(gpioPress),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
    });

    test('other wins on a shared trigger', () {
      const trigger = MappingTrigger(kind: ControllerSourceKind.gpio, id: 17);
      final base = const ControllerMapping().withBinding(
        trigger,
        LooperAction.play,
      );
      final other = const ControllerMapping().withBinding(
        trigger,
        LooperAction.clear,
      );

      const press = RawControllerInput(
        kind: ControllerSourceKind.gpio,
        id: 17,
        value: 1,
      );
      expect(
        base.merge(other).resolve(press),
        const ControllerEvent(action: LooperAction.clear),
      );
    });

    test('keeps the receiver name', () {
      final merged = ControllerMapping.defaults().merge(
        ControllerMapping.gpioDefaults(),
      );
      expect(merged.name, ControllerMapping.defaults().name);
    });

    test('merging an empty mapping is an identity on entries', () {
      final base = ControllerMapping.defaults();
      expect(base.merge(const ControllerMapping()).entries, base.entries);
      expect(
        const ControllerMapping().merge(base).entries,
        base.entries,
      );
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
