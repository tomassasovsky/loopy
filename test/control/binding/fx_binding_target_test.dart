import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/fx_binding_target.dart';

void main() {
  group('FxBindingTarget', () {
    const track = FxAddress(stage: FxStage.track, index: 5);
    const loop = FxAddress(stage: FxStage.loop, index: 1, lane: 2);

    test('a chain target round-trips through its canonical string', () {
      for (final address in const [
        FxAddress(stage: FxStage.input, index: 3),
        loop,
        track,
        FxAddress(stage: FxStage.master),
      ]) {
        final target = FxChainTarget(address);
        expect(FxBindingTarget.tryParse(target.canonicalString()), target);
      }
    });

    test('a chain target IS the address canonical string — the encoding '
        'extends part 3a rather than redeclaring it (R19)', () {
      expect(
        const FxChainTarget(track).canonicalString(),
        track.canonicalString(),
      );
    });

    test('a slot target round-trips and appends exactly one key', () {
      const target = FxSlotTarget(address: loop, slotId: 'slot-abc');
      expect(FxBindingTarget.tryParse(target.canonicalString()), target);
      expect(
        jsonDecode(target.canonicalString()),
        {...loop.toJson(), 'slot': 'slot-abc'},
      );
    });

    test('the encoding is byte-stable, so string equality is target '
        'identity', () {
      const a = FxSlotTarget(address: track, slotId: 'x');
      const b = FxSlotTarget(
        address: FxAddress(stage: FxStage.track, index: 5),
        slotId: 'x',
      );
      expect(a.canonicalString(), b.canonicalString());
      expect(a, b);
    });

    test('a chain and a slot target on the same address are distinct', () {
      const chain = FxChainTarget(track);
      const slot = FxSlotTarget(address: track, slotId: 'x');
      expect(chain, isNot(slot));
      expect(chain.canonicalString(), isNot(slot.canonicalString()));
    });

    group('tryParse rejects rather than throwing — bindings cross package '
        'boundaries and restarts as bare strings', () {
      test('non-JSON', () {
        expect(FxBindingTarget.tryParse('not json'), isNull);
      });

      test('a JSON value that is not an object', () {
        expect(FxBindingTarget.tryParse('[1,2]'), isNull);
        expect(FxBindingTarget.tryParse('"track"'), isNull);
      });

      test('an unknown or missing stage', () {
        expect(FxBindingTarget.tryParse('{"stage":"sidechain"}'), isNull);
        expect(FxBindingTarget.tryParse('{"index":1}'), isNull);
      });

      test('a present-but-unusable slot is corruption, NOT a chain target — '
          'widening an effect binding to its whole chain would bypass far '
          'more than the user asked for', () {
        expect(
          FxBindingTarget.tryParse(
            jsonEncode({...track.toJson(), 'slot': 7}),
          ),
          isNull,
        );
        expect(
          FxBindingTarget.tryParse(
            jsonEncode({...track.toJson(), 'slot': ''}),
          ),
          isNull,
        );
      });
    });

    test('an unknown key decodes as the chain target it otherwise is — the '
        'additive-only contract from part 3a', () {
      final encoded = jsonEncode({...track.toJson(), 'future': 'value'});
      expect(FxBindingTarget.tryParse(encoded), const FxChainTarget(track));
    });

    test('address exposes the containing chain for both variants', () {
      expect(const FxChainTarget(loop).address, loop);
      expect(
        const FxSlotTarget(address: loop, slotId: 'x').address,
        loop,
      );
    });
  });
}
