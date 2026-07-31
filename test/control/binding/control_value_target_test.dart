import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/binding/control_value_target.dart';

void main() {
  group('ControlValueTarget canonical strings', () {
    test('an FX param round-trips and extends the part 3a address form', () {
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        slotId: 'slot-7',
        param: 2,
      );

      final encoded = target.canonicalString();
      expect(ControlValueTarget.tryParse(encoded), target);
      // The address contributes its own keys, so the SAME map still decodes as
      // a part 3a address — the additive-only contract R19 relies on.
      final map = jsonDecode(encoded) as Map<String, dynamic>;
      expect(FxAddress.fromJson(map), target.address);
      expect(map['slot'], 'slot-7');
      expect(map['param'], 2);
    });

    test('the rig-level controls round-trip', () {
      const volume = TrackVolumeTarget(3);
      const master = MasterGainTarget();

      expect(ControlValueTarget.tryParse(volume.canonicalString()), volume);
      expect(ControlValueTarget.tryParse(master.canonicalString()), master);
    });

    test('equal targets encode byte-identically', () {
      const a = FxParamTarget(
        address: FxAddress(stage: FxStage.master),
        slotId: 's',
        param: 0,
      );
      const b = FxParamTarget(
        address: FxAddress(stage: FxStage.master),
        slotId: 's',
        param: 0,
      );

      expect(a.canonicalString(), b.canonicalString());
    });

    test('a corrupt or partial string decodes to null, never a guess', () {
      expect(ControlValueTarget.tryParse('not json'), isNull);
      expect(ControlValueTarget.tryParse('[]'), isNull);
      expect(ControlValueTarget.tryParse('{"ctl":"nope"}'), isNull);
      expect(ControlValueTarget.tryParse('{"ctl":"trackVolume"}'), isNull);
      // An FX target missing its slot or param would otherwise widen to
      // "some parameter of some effect", which is exactly the retarget A9
      // forbids.
      expect(
        ControlValueTarget.tryParse(
          jsonEncode({
            ...const FxAddress(stage: FxStage.track, index: 1).toJson(),
            'param': 0,
          }),
        ),
        isNull,
      );
      expect(
        ControlValueTarget.tryParse(
          jsonEncode({
            ...const FxAddress(stage: FxStage.track, index: 1).toJson(),
            'slot': 'x',
          }),
        ),
        isNull,
      );
    });

    test('a chain-level (part 6b) string is not a value target', () {
      // The two sealed families are deliberately disjoint: a stomp target
      // names an `enabled` flag, not something to sweep.
      const chain = FxAddress(stage: FxStage.track, index: 2);

      expect(ControlValueTarget.tryParse(chain.canonicalString()), isNull);
    });
  });
}
