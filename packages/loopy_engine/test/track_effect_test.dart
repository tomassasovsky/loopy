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
      // cleanly now that the pre/post model is gone.
      final fx = TrackEffect.fromJson(const {
        'type': 4,
        'stage': 1,
        'params': [0.4, 0.5, 0.6],
      });
      expect(fx.type, TrackEffectType.tremolo);
      expect(fx.params, [0.4, 0.5, 0.6]);
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
      expect(TrackEffectType.reverb.defaultParams, [0.5, 0.5, 0.35]);
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

    test('the octaver Shift is a discrete, formatted pitch control', () {
      final shift = TrackEffectType.octaver.params.first;
      expect(shift.label, 'Shift');
      expect(shift.divisions, 48); // one step per semitone across +-2 octaves
      expect(shift.format, isNotNull);
    });
  });

  group('formatPitchShift', () {
    test('reads unison, semitones, and whole octaves from the 0..1 range', () {
      expect(formatPitchShift(0.5), 'Unison');
      expect(formatPitchShift(0.25), '-1 oct'); // -12 semitones
      expect(formatPitchShift(0.75), '+1 oct'); // +12 semitones
      expect(formatPitchShift(0), '-2 oct');
      expect(formatPitchShift(1), '+2 oct');
      // 7 semitones up: 0.5 + 7/48.
      expect(formatPitchShift(0.5 + 7 / 48), '+7 st');
    });
  });

  group('encode/decode chain', () {
    test('round-trips an ordered chain', () {
      final chain = [
        TrackEffect(type: TrackEffectType.drive),
        TrackEffect(type: TrackEffectType.delay, params: const [0.5, 0.4, 0.3]),
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
      expect(decoded.first.params, [0.2, 0.3, 0]);
    });

    test('empty or malformed input yields an empty chain', () {
      expect(decodeTrackEffects(null), isEmpty);
      expect(decodeTrackEffects(''), isEmpty);
      expect(decodeTrackEffects('not json'), isEmpty);
      expect(decodeTrackEffects('{"type":1}'), isEmpty);
    });
  });
}
