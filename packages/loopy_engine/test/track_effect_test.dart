import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('TrackEffect', () {
    test('defaults params to the type musical defaults', () {
      final fx = TrackEffect(type: TrackEffectType.delay);
      expect(fx.params, TrackEffectType.delay.defaultParams);
      expect(fx.params.length, greaterThan(0));
    });

    test('params is unmodifiable', () {
      final fx = TrackEffect(type: TrackEffectType.drive);
      expect(() => fx.params[0] = 1, throwsUnsupportedError);
    });

    test('toJson carries only type and params (no stage)', () {
      final json = TrackEffect(
        type: TrackEffectType.filter,
        params: const [0.1, 0.2, 0.3],
      ).toJson();
      expect(json.keys, containsAll(<String>['type', 'params']));
      expect(json.containsKey('stage'), isFalse);
      expect(json['type'], TrackEffectType.filter.code);
      expect(json['params'], [0.1, 0.2, 0.3]);
    });

    test('fromJson ignores a legacy stage key', () {
      // Older persisted chains stored a `stage` integer; it must decode
      // cleanly now that the pre/post model is gone. The length-3 params from
      // that era are padded to the current width with the type's default.
      final fx = TrackEffect.fromJson(const {
        'type': 4,
        'stage': 1,
        'params': [0.4, 0.5, 0.6],
      });
      expect(fx.type, TrackEffectType.tremolo);
      expect(fx.params, [0.4, 0.5, 0.6, 0]);
    });

    test(
      'fromJson falls back to none + defaults for unknown/missing fields',
      () {
        final fx = TrackEffect.fromJson(const {});
        expect(fx.type, TrackEffectType.none);
        expect(fx.params, TrackEffectType.none.defaultParams);
      },
    );

    test('copyWith replaces type and params independently', () {
      final base = TrackEffect(
        type: TrackEffectType.drive,
        params: const [0.1, 0.2, 0.3],
      );
      expect(
        base.copyWith(type: TrackEffectType.filter).type,
        TrackEffectType.filter,
      );
      expect(base.copyWith(type: TrackEffectType.filter).params, base.params);
      expect(base.copyWith(params: const [0.9, 0, 0]).params, [0.9, 0, 0]);
    });

    test('copyWith preserves the unmodifiable params contract', () {
      final copy = TrackEffect(type: TrackEffectType.drive).copyWith(
        params: [0.9, 0, 0],
      );
      expect(() => copy.params[0] = 0, throwsUnsupportedError);
    });

    test('fromJson pads a pre-rewrite 3-param chain to the current width', () {
      // A chain saved by the 3-param build: the octaver gains its new `mode`
      // slot, which must default to 0.0 (phase vocoder), not leave the list
      // short or read garbage.
      final fx = TrackEffect.fromJson({
        'type': TrackEffectType.octaver.code,
        'params': const [0.25, 0.5, 0.5],
      });
      expect(fx.type, TrackEffectType.octaver);
      expect(fx.params, [0.25, 0.5, 0.5, 0]);
      expect(fx.params, hasLength(kTrackEffectParams));
      expect(fx.params.last, 0.0); // mode == phase vocoder
    });

    test('fromJson pads with the type default, not a blanket zero', () {
      // delay's p2 default is 0.35; a 2-param save pads p2 from the default and
      // p3 from the (zero) default, proving the per-type pad (not a blanket 0).
      final fx = TrackEffect.fromJson({
        'type': TrackEffectType.delay.code,
        'params': const [0.1, 0.2],
      });
      expect(fx.params, [0.1, 0.2, 0.35, 0]);
    });

    test('fromJson truncates an over-long params list', () {
      final fx = TrackEffect.fromJson({
        'type': TrackEffectType.drive.code,
        'params': const [0.1, 0.2, 0.3, 0.4, 0.5],
      });
      expect(fx.params, [0.1, 0.2, 0.3, 0.4]);
      expect(fx.params, hasLength(kTrackEffectParams));
    });

    test('fromJson falls back to defaults when params is not a list', () {
      final fx = TrackEffect.fromJson(const {
        'type': 1,
        'params': 'nonsense',
      });
      expect(fx.type, TrackEffectType.drive);
      expect(fx.params, TrackEffectType.drive.defaultParams);
    });

    test('value equality ignores instance identity', () {
      final a = TrackEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      final b = TrackEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('a differing type or param breaks equality', () {
      final a = TrackEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      expect(a, isNot(equals(a.copyWith(type: TrackEffectType.drive))));
      expect(a, isNot(equals(a.copyWith(params: const [0.9, 0.2, 0.3]))));
    });
  });

  group('TrackEffectType', () {
    test('kTrackEffectParams mirrors the native LE_FX_PARAMS width', () {
      // Pins the Dart side of the cross-language contract (the native test
      // asserts LE_FX_PARAMS == 4 in turn).
      expect(kTrackEffectParams, 4);
    });

    test('fromCode maps known codes and falls back to none', () {
      for (final type in TrackEffectType.values) {
        expect(TrackEffectType.fromCode(type.code), type);
      }
      expect(TrackEffectType.fromCode(999), TrackEffectType.none);
    });

    test('paramLabels length never exceeds the param cap', () {
      for (final type in TrackEffectType.values) {
        expect(type.paramLabels.length, lessThanOrEqualTo(kTrackEffectParams));
        expect(type.defaultParams.length, kTrackEffectParams);
      }
    });

    test('codes match the native le_fx_type contract', () {
      // These integers are the wire contract with the engine and persisted
      // chains; they must never drift.
      expect(TrackEffectType.octaver.code, 5);
      expect(TrackEffectType.echo.code, 6);
      expect(TrackEffectType.reverb.code, 7);
    });

    test('reverb exposes size, damping and mix', () {
      expect(TrackEffectType.reverb.paramLabels, ['Size', 'Damping', 'Mix']);
      // The fourth slot is the inert, shared trailing param.
      expect(TrackEffectType.reverb.defaultParams, [0.5, 0.5, 0.35, 0]);
    });

    test('codes are unique', () {
      final codes = TrackEffectType.values.map((t) => t.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('paramLabels stay in sync with params', () {
      for (final type in TrackEffectType.values) {
        expect(type.paramLabels, type.params.map((p) => p.label).toList());
      }
    });

    test('the octaver Shift is a discrete, pitch-readout control', () {
      final shift = TrackEffectType.octaver.params.first;
      expect(shift.label, 'Shift');
      expect(shift.divisions, 48); // one step per semitone across +-2 octaves
      expect(shift.readout, ParamReadout.pitchShift);
    });

    test('the octaver exposes a discrete two-state Mode control', () {
      final mode = TrackEffectType.octaver.params.last;
      expect(mode.label, 'Mode');
      expect(mode.divisions, 1); // two states: phase vocoder / PSOLA
      expect(mode.readout, ParamReadout.octaverMode);
    });

    test('non-octaver params carry no readout', () {
      for (final type in TrackEffectType.values) {
        if (type == TrackEffectType.octaver) continue;
        for (final p in type.params) {
          expect(p.readout, ParamReadout.none);
        }
      }
    });
  });

  group('encode/decode chain', () {
    test('round-trips an ordered chain', () {
      // Params are at the current width, so decode (which normalizes) round-
      // trips them exactly.
      final chain = [
        TrackEffect(type: TrackEffectType.drive),
        TrackEffect(
          type: TrackEffectType.delay,
          params: const [0.5, 0.4, 0.3, 0],
        ),
      ];
      final decoded = decodeTrackEffects(encodeTrackEffects(chain));
      expect(decoded, chain);
    });

    test('decodes a legacy chain that still carries stage keys', () {
      final legacy = jsonEncode([
        {
          'type': TrackEffectType.filter.code,
          'stage': 1,
          'params': [0.2, 0.3, 0],
        },
      ]);
      final decoded = decodeTrackEffects(legacy);
      expect(decoded, hasLength(1));
      expect(decoded.first.type, TrackEffectType.filter);
      // The length-3 legacy params are padded to the current width.
      expect(decoded.first.params, [0.2, 0.3, 0, 0]);
    });

    test('empty or malformed input yields an empty chain', () {
      expect(decodeTrackEffects(null), isEmpty);
      expect(decodeTrackEffects(''), isEmpty);
      expect(decodeTrackEffects('not json'), isEmpty);
      expect(decodeTrackEffects('{"type":1}'), isEmpty);
    });
  });
}
