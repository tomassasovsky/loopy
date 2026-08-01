import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const expression = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 11,
    midiChannel: 0,
  );
  const stomp = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 21,
    midiChannel: 0,
  );
  const cutoff = ContinuousBinding(trigger: expression, target: 'cutoff');
  const volume = ContinuousBinding(trigger: expression, target: 'volume');
  const bypass = DiscreteBinding(trigger: stomp, target: 'chain');

  group('ControllerBindingSet', () {
    test('keeps one binding per (control, target) pair', () {
      final set = ControllerBindingSet([
        cutoff,
        volume,
        cutoff.copyWith(lo: 0.5),
      ]);

      expect(set.length, 2);
      expect(
        set.bindings.whereType<ContinuousBinding>().first.lo,
        0.5,
        reason: 'the last entry for a repeated key wins',
      );
    });

    test('matching returns every binding a control drives (fan-out)', () {
      final set = ControllerBindingSet(const [cutoff, volume, bypass]);
      const input = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 11,
        value: 64,
      );

      expect(set.matching(input), [cutoff, volume]);
    });

    test('matching ignores a control on another channel', () {
      final set = ControllerBindingSet(const [cutoff]);
      const other = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 11,
        value: 64,
        midiChannel: 5,
      );

      expect(set.matching(other), isEmpty);
    });

    test(
      'isTriggerBound sees other bindings but not the one being relearned',
      () {
        final set = ControllerBindingSet(const [cutoff]);

        expect(set.isTriggerBound(expression), isTrue);
        expect(set.isTriggerBound(expression, except: cutoff), isFalse);
        expect(set.isTriggerBound(stomp), isFalse);
      },
    );

    test('withoutTrigger clears the control, keeping the exempt binding', () {
      final set = ControllerBindingSet(const [cutoff, volume, bypass]);

      expect(
        set.withoutTrigger(expression, except: volume).bindings,
        [volume, bypass],
      );
    });

    test('replace keeps row order; without removes', () {
      final set = ControllerBindingSet(const [cutoff, volume, bypass]);
      final edited = volume.copyWith(hi: 0.4);

      expect(set.replace(volume, edited).bindings, [cutoff, edited, bypass]);
      expect(set.without(volume).bindings, [cutoff, bypass]);
      expect(
        set.without(const ContinuousBinding(trigger: stomp, target: 'nope')),
        set,
      );
    });

    test('encode → decode → encode is byte-stable', () {
      final set = ControllerBindingSet([
        cutoff.copyWith(lo: 0.2, hi: 0.8),
        bypass.copyWith(
          threshold: 100,
          behavior: BindingBehavior.momentary,
        ),
      ]);

      final blob = set.encode();
      final restored = ControllerBindingSet.decode(blob);

      expect(restored, set);
      expect(restored.encode(), blob);
    });

    test('an empty set encodes to the empty string and back', () {
      expect(ControllerBindingSet.empty.encode(), '');
      expect(ControllerBindingSet.decode(''), ControllerBindingSet.empty);
    });

    test('a corrupt blob degrades to whatever decoded', () {
      expect(
        ControllerBindingSet.decode('not json'),
        ControllerBindingSet.empty,
      );
      expect(
        ControllerBindingSet.decode('{"bind":"continuous"}').isEmpty,
        isTrue,
      );
      expect(
        ControllerBindingSet.decode('[${_json(cutoff)}, 7, {"bind":"nope"}]'),
        ControllerBindingSet(const [cutoff]),
        reason: 'one unusable entry must not cost the user the others',
      );
    });
  });
}

String _json(ControllerBinding binding) =>
    ControllerBindingSet([binding]).encode().replaceAll(RegExp(r'^\[|\]$'), '');
