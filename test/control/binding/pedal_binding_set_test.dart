import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/binding/fx_binding_target.dart';
import 'package:loopy/control/binding/pedal_binding.dart';
import 'package:loopy/control/binding/pedal_binding_set.dart';
import 'package:pedal_repository/pedal_repository.dart';

const _track5 = FxAddress(stage: FxStage.track, index: 5);
const _master = FxAddress(stage: FxStage.master);

String get _chainTarget => const FxChainTarget(_track5).canonicalString();
String get _slotTarget =>
    const FxSlotTarget(address: _master, slotId: 'slot-a').canonicalString();

PedalBinding _binding(
  PedalButton button, {
  int? bank,
  String? target,
  BindingBehavior behavior = BindingBehavior.toggle,
}) => PedalBinding(
  key: PedalBindingKey(button: button, bank: bank),
  target: target ?? _chainTarget,
  behavior: behavior,
);

void main() {
  group('PedalBindingKey', () {
    test('track buttons are bank-keyed, everything else is not (A3)', () {
      for (final button in PedalBindingKey.trackButtons) {
        expect(PedalBindingKey.isBankKeyed(button), isTrue);
      }
      for (final button in const [
        PedalButton.recPlay,
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
      ]) {
        expect(PedalBindingKey.isBankKeyed(button), isFalse);
      }
    });

    test('the same track button in two banks is two distinct controls', () {
      expect(
        const PedalBindingKey(button: PedalButton.track1, bank: 0),
        isNot(const PedalBindingKey(button: PedalButton.track1, bank: 1)),
      );
    });

    test('round-trips through JSON, omitting an absent bank', () {
      const perButton = PedalBindingKey(button: PedalButton.stop);
      const perBank = PedalBindingKey(button: PedalButton.track3, bank: 1);
      expect(perButton.toJson().containsKey('bank'), isFalse);
      expect(PedalBindingKey.fromJson(perButton.toJson()), perButton);
      expect(PedalBindingKey.fromJson(perBank.toJson()), perBank);
    });

    group('fromJson refuses a map that does not describe a bindable '
        'control', () {
      test('an unknown button name', () {
        expect(
          PedalBindingKey.fromJson(const {'button': 'expression'}),
          isNull,
        );
        expect(PedalBindingKey.fromJson(const {'button': 3}), isNull);
        expect(PedalBindingKey.fromJson(const <String, dynamic>{}), isNull);
      });

      test('a track button with no bank, or one out of range', () {
        expect(PedalBindingKey.fromJson(const {'button': 'track1'}), isNull);
        expect(
          PedalBindingKey.fromJson(const {'button': 'track1', 'bank': 2}),
          isNull,
        );
        expect(
          PedalBindingKey.fromJson(const {'button': 'track1', 'bank': -1}),
          isNull,
        );
      });

      test('a stray bank on a per-button control — honoring it would let one '
          'button hold two bindings the screen can never show', () {
        expect(
          PedalBindingKey.fromJson(const {'button': 'stop', 'bank': 0}),
          isNull,
        );
      });
    });
  });

  group('PedalBinding', () {
    test('round-trips through JSON with its behavior', () {
      final binding = _binding(
        PedalButton.stop,
        behavior: BindingBehavior.momentary,
      );
      expect(PedalBinding.fromJson(binding.toJson()), binding);
    });

    test('decodeTarget yields the typed target', () {
      expect(
        _binding(PedalButton.stop, target: _slotTarget).decodeTarget(),
        const FxSlotTarget(address: _master, slotId: 'slot-a'),
      );
    });

    test('a target string that no longer parses decodes to null — the stale '
        'binding case (R25), not a crash', () {
      expect(
        _binding(PedalButton.stop, target: 'garbage').decodeTarget(),
        isNull,
      );
    });

    test('an unknown behavior falls back to toggle — a momentary that never '
        'releases is the failure mode worth avoiding', () {
      final json = _binding(PedalButton.stop).toJson()
        ..['behavior'] = 'latching';
      expect(PedalBinding.fromJson(json)?.behavior, BindingBehavior.toggle);
    });

    test('fromJson refuses a missing or empty target', () {
      final json = _binding(PedalButton.stop).toJson()..remove('target');
      expect(PedalBinding.fromJson(json), isNull);
      expect(
        PedalBinding.fromJson({...json, 'target': ''}),
        isNull,
      );
    });
  });

  group('PedalBindingSet', () {
    test('holds at most one binding per control, last wins', () {
      final set = PedalBindingSet([
        _binding(PedalButton.stop, target: _chainTarget),
        _binding(PedalButton.stop, target: _slotTarget),
      ]);
      expect(set.length, 1);
      expect(set.lookup(PedalButton.stop, bank: 0)?.target, _slotTarget);
    });

    test('drops a binding on MODE or Bank rather than rejecting the whole '
        'set (B12) — a hand-edited blob must not cost the user every other '
        'binding they made', () {
      final set = PedalBindingSet([
        _binding(PedalButton.mode),
        _binding(PedalButton.bank),
        _binding(PedalButton.stop),
      ]);
      expect(set.length, 1);
      expect(set.lookup(PedalButton.mode, bank: 0), isNull);
      expect(set.lookup(PedalButton.bank, bank: 0), isNull);
      expect(set.lookup(PedalButton.stop, bank: 0), isNotNull);
    });

    test('lookup consults the bank only for a bank-keyed control (A3)', () {
      final set = PedalBindingSet([
        _binding(PedalButton.track1, bank: 1),
        _binding(PedalButton.stop),
      ]);
      expect(set.lookup(PedalButton.track1, bank: 1), isNotNull);
      expect(set.lookup(PedalButton.track1, bank: 0), isNull);
      // Per-button controls answer the same regardless of the live bank.
      expect(set.lookup(PedalButton.stop, bank: 0), isNotNull);
      expect(set.lookup(PedalButton.stop, bank: 1), isNotNull);
    });

    group('encode / decode', () {
      test('round-trips a populated set', () {
        final set = PedalBindingSet([
          _binding(PedalButton.track1, bank: 0),
          _binding(PedalButton.track3, bank: 1, target: _slotTarget),
          _binding(PedalButton.stop, behavior: BindingBehavior.momentary),
        ]);
        expect(PedalBindingSet.decode(set.encode()), set);
      });

      test('the encoding is byte-stable regardless of insertion order, so an '
          'unchanged set never looks dirty', () {
        final a = PedalBindingSet([
          _binding(PedalButton.stop),
          _binding(PedalButton.track1, bank: 0),
        ]);
        final b = PedalBindingSet([
          _binding(PedalButton.track1, bank: 0),
          _binding(PedalButton.stop),
        ]);
        expect(a.encode(), b.encode());
        expect(a, b);
      });

      test('an empty set encodes to the empty string and back', () {
        expect(PedalBindingSet.empty.encode(), isEmpty);
        expect(PedalBindingSet.decode(''), PedalBindingSet.empty);
        expect(PedalBindingSet.empty.isEmpty, isTrue);
      });

      test('a corrupt blob degrades to what DID decode rather than blocking '
          'a load — a remap is optional over working defaults', () {
        expect(PedalBindingSet.decode('not json'), PedalBindingSet.empty);
        expect(PedalBindingSet.decode('{"a":1}'), PedalBindingSet.empty);

        final partial = PedalBindingSet.decode(
          jsonEncode([
            _binding(PedalButton.stop).toJson(),
            {'button': 'nonsense', 'target': _chainTarget},
            'not even a map',
            _binding(PedalButton.mode).toJson(), // unbindable
          ]),
        );
        expect(partial.length, 1);
        expect(partial.lookup(PedalButton.stop, bank: 0), isNotNull);
      });

      test('a target string is carried through opaquely even when it no '
          'longer resolves (R25)', () {
        final set = PedalBindingSet([
          _binding(PedalButton.stop, target: 'stale-but-preserved'),
        ]);
        final decoded = PedalBindingSet.decode(set.encode());
        expect(
          decoded.lookup(PedalButton.stop, bank: 0)?.target,
          'stale-but-preserved',
        );
      });
    });

    group('withBinding / without', () {
      test('withBinding replaces the binding on the same control', () {
        final set = PedalBindingSet([_binding(PedalButton.stop)]).withBinding(
          _binding(PedalButton.stop, target: _slotTarget),
        );
        expect(set.length, 1);
        expect(set.lookup(PedalButton.stop, bank: 0)?.target, _slotTarget);
      });

      test('withBinding still drops an unbindable control (B12)', () {
        expect(
          PedalBindingSet.empty.withBinding(_binding(PedalButton.mode)).isEmpty,
          isTrue,
        );
      });

      test('without clears one control and leaves the rest', () {
        final set = PedalBindingSet([
          _binding(PedalButton.stop),
          _binding(PedalButton.track1, bank: 0),
        ]).without(const PedalBindingKey(button: PedalButton.stop));
        expect(set.length, 1);
        expect(set.lookup(PedalButton.track1, bank: 0), isNotNull);
      });

      test('without on an unknown key is a no-op', () {
        final set = PedalBindingSet([_binding(PedalButton.stop)]);
        expect(
          set.without(const PedalBindingKey(button: PedalButton.undo)),
          set,
        );
      });
    });

    group('merge rule (A12)', () {
      final globals = PedalBindingSet([
        _binding(PedalButton.stop),
        _binding(PedalButton.undo),
      ]);

      test('a session with ANY bindings overrides the globals WHOLESALE — no '
          'per-button merging', () {
        final session = PedalBindingSet([
          _binding(PedalButton.track1, bank: 0),
        ]);
        final resolved = globals.resolveAgainst(session);

        expect(resolved, session);
        // The globals' own buttons are NOT inherited alongside.
        expect(resolved.lookup(PedalButton.stop, bank: 0), isNull);
        expect(resolved.lookup(PedalButton.undo, bank: 0), isNull);
      });

      test('a session with no bindings falls back to the globals entirely', () {
        expect(globals.resolveAgainst(PedalBindingSet.empty), globals);
      });

      test('empty globals and an empty session resolve to empty', () {
        expect(
          PedalBindingSet.empty.resolveAgainst(PedalBindingSet.empty).isEmpty,
          isTrue,
        );
      });
    });
  });
}
