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

    test(
      'tapTempo, toggleMetronome and cancelArm are global (D20), like '
      'stopAll — not per-track',
      () {
        expect(LooperAction.tapTempo.isChannelScoped, isFalse);
        expect(LooperAction.toggleMetronome.isChannelScoped, isFalse);
        expect(LooperAction.cancelArm.isChannelScoped, isFalse);
      },
    );
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

    test(
      'resolves the default tapTempo / toggleMetronome / cancelArm triggers '
      '(D20 — id 84 restores the pre-2f0513a tapTempo slot; 85/86 are new)',
      () {
        const tapTempo = RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 84,
          value: 127,
        );
        const toggleMetronome = RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 85,
          value: 127,
        );
        const cancelArm = RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 86,
          value: 127,
        );
        expect(
          mapping.resolve(tapTempo),
          const ControllerEvent(action: LooperAction.tapTempo),
        );
        expect(
          mapping.resolve(toggleMetronome),
          const ControllerEvent(action: LooperAction.toggleMetronome),
        );
        expect(
          mapping.resolve(cancelArm),
          const ControllerEvent(action: LooperAction.cancelArm),
        );
      },
    );
  });

  group('ControllerMapping.merge', () {
    // A second mapping bound to MIDI notes, layered over the CC defaults.
    ControllerMapping customNotes() =>
        const ControllerMapping(
          name: 'custom',
        ).withBinding(
          const MappingTrigger(kind: ControllerSourceKind.midiNote, id: 36),
          LooperAction.recordOverdub,
        );

    test('combines two mappings so both resolve', () {
      final merged = ControllerMapping.defaults().merge(customNotes());

      const ccPress = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 127,
      );
      const notePress = RawControllerInput(
        kind: ControllerSourceKind.midiNote,
        id: 36,
        value: 127,
      );
      expect(
        merged.resolve(ccPress),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
      expect(
        merged.resolve(notePress),
        const ControllerEvent(action: LooperAction.recordOverdub),
      );
    });

    test('other wins on a shared trigger', () {
      const trigger = MappingTrigger(kind: ControllerSourceKind.midiCc, id: 80);
      final base = const ControllerMapping().withBinding(
        trigger,
        LooperAction.play,
      );
      final other = const ControllerMapping().withBinding(
        trigger,
        LooperAction.clear,
      );

      const press = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 80,
        value: 1,
      );
      expect(
        base.merge(other).resolve(press),
        const ControllerEvent(action: LooperAction.clear),
      );
    });

    test('keeps the receiver name', () {
      final merged = ControllerMapping.defaults().merge(customNotes());
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
        kind: ControllerSourceKind.midiNote,
        id: 36,
      );
      final mapping = const ControllerMapping().withBinding(
        trigger,
        LooperAction.recordOverdub,
        channel: 1,
      );
      const press = RawControllerInput(
        kind: ControllerSourceKind.midiNote,
        id: 36,
        value: 1,
      );
      expect(
        mapping.resolve(press),
        const ControllerEvent(action: LooperAction.recordOverdub, channel: 1),
      );
    });
  });
}
