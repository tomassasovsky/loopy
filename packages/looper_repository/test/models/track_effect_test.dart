import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

void main() {
  group('domain ↔ engine parity', () {
    test('mirrors every engine effect type with an identical code set', () {
      expect(
        TrackEffectType.values.map((t) => t.code).toList(),
        engine.TrackEffectType.values.map((t) => t.code).toList(),
      );
    });

    test('sources label, param descriptors, and defaults from the engine '
        '(no drift)', () {
      for (final type in TrackEffectType.values) {
        final eng = engine.TrackEffectType.fromCode(type.code);
        expect(type.label, eng.label, reason: 'label for ${type.name}');
        expect(
          type.defaultParams,
          eng.defaultParams,
          reason: 'defaultParams for ${type.name}',
        );
        expect(
          type.paramLabels,
          eng.paramLabels,
          reason: 'paramLabels for ${type.name}',
        );
        expect(type.params.length, eng.params.length);
        for (var i = 0; i < type.params.length; i++) {
          expect(type.params[i].label, eng.params[i].label);
          expect(type.params[i].divisions, eng.params[i].divisions);
          // Readout kinds are distinct enums; parity is by name.
          expect(type.params[i].readout.name, eng.params[i].readout.name);
        }
      }
    });

    test('TrackEffectParam value equality covers label/divisions/readout', () {
      const a = TrackEffectParam(
        'Shift',
        divisions: 48,
        readout: ParamReadout.pitchShift,
      );
      const b = TrackEffectParam(
        'Shift',
        divisions: 48,
        readout: ParamReadout.pitchShift,
      );
      const differentReadout = TrackEffectParam('Shift', divisions: 48);

      expect(a, b);
      expect(a, isNot(differentReadout));
      expect(a, isNot(const TrackEffectParam('Tone')));
    });
  });

  group('encode / decode', () {
    test('round-trips type order and pads params to the engine width', () {
      final chain = [
        TrackEffect(type: TrackEffectType.filter),
        // A 3-value chain (the 4th param is omitted) must round-trip padded
        // with the type's own default for the trailing slot.
        TrackEffect(
          type: TrackEffectType.delay,
          params: const [0.3, 0.42, 0.5],
        ),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded.map((e) => e.type), [
        TrackEffectType.filter,
        TrackEffectType.delay,
      ]);
      expect(decoded[0].params, TrackEffectType.filter.defaultParams);
      expect(decoded[1].params, [0.3, 0.42, 0.5, 0]);
    });

    test('reads a chain written by the engine serializer (wire-format '
        'compat)', () {
      final engineEncoded = engine.encodeTrackEffects([
        engine.TrackEffect(type: engine.TrackEffectType.reverb),
        engine.TrackEffect(type: engine.TrackEffectType.octaver),
      ]);

      final decoded = decodeTrackEffects(engineEncoded);

      expect(decoded.map((e) => e.type), [
        TrackEffectType.reverb,
        TrackEffectType.octaver,
      ]);
    });

    test('malformed input decodes to an empty chain', () {
      expect(decodeTrackEffects(null), isEmpty);
      expect(decodeTrackEffects(''), isEmpty);
      expect(decodeTrackEffects('not json'), isEmpty);
    });
  });

  group('TrackEffect', () {
    test('defaults params to the type defaults', () {
      expect(
        TrackEffect(type: TrackEffectType.drive).params,
        TrackEffectType.drive.defaultParams,
      );
    });

    test('value equality is by type and params', () {
      expect(
        TrackEffect(type: TrackEffectType.drive),
        TrackEffect(type: TrackEffectType.drive),
      );
      expect(
        TrackEffect(type: TrackEffectType.drive),
        isNot(TrackEffect(type: TrackEffectType.filter)),
      );
    });

    test('copyWith replaces type while keeping params', () {
      final fx = TrackEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3, 0.4],
      );

      final swapped = fx.copyWith(type: TrackEffectType.echo);

      expect(swapped.type, TrackEffectType.echo);
      expect(swapped.params, [0.1, 0.2, 0.3, 0.4]);
    });
  });
}
