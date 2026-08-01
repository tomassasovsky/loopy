import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cc = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 21,
    midiChannel: 3,
  );

  group('MappingTrigger', () {
    test('matches on kind + id, and on channel when scoped', () {
      const input = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 21,
        value: 64,
        midiChannel: 3,
      );

      expect(cc.matches(input), isTrue);
      expect(
        const MappingTrigger(
          kind: ControllerSourceKind.midiCc,
          id: 21,
        ).matches(input),
        isTrue,
        reason: 'an omni trigger fires on every channel',
      );
      expect(
        const MappingTrigger(
          kind: ControllerSourceKind.midiCc,
          id: 21,
          midiChannel: 4,
        ).matches(input),
        isFalse,
      );
      expect(
        const MappingTrigger(
          kind: ControllerSourceKind.midiNote,
          id: 21,
        ).matches(input),
        isFalse,
      );
    });

    test('round-trips through JSON, omitting an omni channel', () {
      expect(MappingTrigger.fromJson(cc.toJson()), cc);
      const omni = MappingTrigger(kind: ControllerSourceKind.midiNote, id: 7);
      expect(omni.toJson().containsKey('channel'), isFalse);
      expect(MappingTrigger.fromJson(omni.toJson()), omni);
    });

    test('rejects corrupt JSON rather than widening it', () {
      expect(MappingTrigger.fromJson({'kind': 'sysex', 'id': 1}), isNull);
      expect(MappingTrigger.fromJson({'kind': 'midiCc'}), isNull);
      expect(MappingTrigger.fromJson({'kind': 'midiCc', 'id': 200}), isNull);
      expect(
        MappingTrigger.fromJson({'kind': 'midiCc', 'id': 1, 'channel': 16}),
        isNull,
        reason: 'an out-of-range channel must not decode as omni',
      );
    });

    test('an input exposes both an omni and a channel-scoped identity', () {
      const input = RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 21,
        value: 1,
        midiChannel: 3,
      );

      expect(input.trigger.midiChannel, isNull);
      expect(input.channelTrigger, cc);
    });
  });

  group('ContinuousBinding', () {
    test('maps the full CC range onto lo..hi', () {
      const binding = ContinuousBinding(
        trigger: cc,
        target: 't',
        lo: 0.25,
        hi: 0.75,
      );

      expect(binding.valueFor(0), closeTo(0.25, 1e-9));
      expect(binding.valueFor(127), closeTo(0.75, 1e-9));
      expect(binding.valueFor(64), closeTo(0.25 + 0.5 * (64 / 127), 1e-9));
    });

    test('honours an inverted range and clamps out-of-range CC values', () {
      const binding = ContinuousBinding(
        trigger: cc,
        target: 't',
        lo: 1,
        hi: 0,
      );

      expect(binding.valueFor(0), 1);
      expect(binding.valueFor(127), 0);
      expect(binding.valueFor(999), 0);
      expect(binding.valueFor(-5), 1);
    });

    test('round-trips through JSON', () {
      const binding = ContinuousBinding(
        trigger: cc,
        target: '{"stage":"track"}',
        lo: 0.2,
        hi: 0.9,
      );

      expect(ControllerBinding.fromJson(binding.toJson()), binding);
    });
  });

  group('DiscreteBinding', () {
    const binding = DiscreteBinding(trigger: cc, target: 't');

    test('reads on at the threshold and off well below it', () {
      expect(binding.isOn(64, previous: false), isTrue);
      expect(binding.isOn(127, previous: false), isTrue);
      expect(binding.isOn(0, previous: true), isFalse);
    });

    test('holds its state inside the hysteresis band', () {
      // Sitting one step under the threshold keeps whatever the control last
      // read, so dithering around the boundary cannot chatter the target.
      expect(binding.isOn(63, previous: true), isTrue);
      expect(binding.isOn(63, previous: false), isFalse);
      expect(
        binding.isOn(64 - DiscreteBinding.hysteresis - 1, previous: true),
        isFalse,
      );
    });

    test('every allowed threshold can still reach its off edge', () {
      // Taken literally, `value >= 0` reads every CC as on and the off edge
      // needs a negative value, so a momentary bound to it could never release
      // (B1's stuck momentary). A LOW threshold has the same hole from the
      // other side: `threshold - hysteresis` lands below zero. Both are
      // reachable — the threshold knob writes 0 at full counter-clockwise, and
      // a hand-edited blob can carry anything.
      for (final threshold in [0, 1, 4, 8, 9]) {
        final binding = DiscreteBinding(
          trigger: cc,
          target: 't',
          threshold: threshold,
        );

        expect(
          binding.isOn(0, previous: true),
          isFalse,
          reason: 'threshold $threshold must release at CC 0',
        );
        expect(
          binding.isOn(127, previous: false),
          isTrue,
          reason: 'threshold $threshold must still engage',
        );
      }
    });

    test('round-trips through JSON', () {
      const momentary = DiscreteBinding(
        trigger: cc,
        target: '{"stage":"master"}',
        threshold: 100,
        behavior: BindingBehavior.momentary,
      );

      expect(ControllerBinding.fromJson(momentary.toJson()), momentary);
    });
  });

  group('ControllerBinding.fromJson', () {
    test('rejects entries that do not describe a binding', () {
      expect(ControllerBinding.fromJson({'bind': 'continuous'}), isNull);
      expect(
        ControllerBinding.fromJson({...cc.toJson(), 'target': 't'}),
        isNull,
        reason: 'an entry with no kind names neither trigger shape',
      );
      expect(
        ControllerBinding.fromJson({
          'bind': 'continuous',
          ...cc.toJson(),
          'target': '',
        }),
        isNull,
      );
    });

    test('falls back to defaults for out-of-domain endpoints', () {
      final decoded =
          ControllerBinding.fromJson({
                'bind': 'continuous',
                ...cc.toJson(),
                'target': 't',
                'lo': -3,
                'hi': 12,
              })!
              as ContinuousBinding;

      expect(decoded.lo, 0);
      expect(decoded.hi, 1);
    });

    test('an unknown behavior decodes as toggle, never momentary', () {
      final decoded =
          ControllerBinding.fromJson({
                'bind': 'discrete',
                ...cc.toJson(),
                'target': 't',
                'behavior': 'sostenuto',
              })!
              as DiscreteBinding;

      expect(decoded.behavior, BindingBehavior.toggle);
    });
  });
}
