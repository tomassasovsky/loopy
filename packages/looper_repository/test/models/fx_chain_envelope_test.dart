import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('FxChainEnvelope codec', () {
    test('round-trips chainEnabled + meta + entries', () {
      final envelope = FxChainEnvelope(
        chainEnabled: false,
        meta: const FxChainMeta(inheritedFrom: [2, 5]),
        entries: [
          BuiltInEffect(
            type: TrackEffectType.delay,
            params: const [0.3, 0.4, 0.5, 0],
            enabled: false,
            slotId: 'a-1',
          ),
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            slotId: 'a-2',
          ),
        ],
      );

      final decoded = decodeFxChain(encodeFxChain(envelope));

      expect(decoded, envelope);
      expect(decoded.chainEnabled, isFalse);
      expect(decoded.meta?.inheritedFrom, [2, 5]);
      expect(decoded.entries.map((e) => e.slotId), ['a-1', 'a-2']);
      expect(decoded.entries.first.enabled, isFalse);
    });

    test('legacy bare-array payloads decode enabled with no meta (R15)', () {
      // Exactly what encodeTrackEffects wrote before FX v3.
      final legacy = encodeTrackEffects([
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);

      final decoded = decodeFxChain(legacy);

      expect(decoded.chainEnabled, isTrue);
      expect(decoded.meta, isNull);
      expect(decoded.entries, hasLength(2));
      // Migration defaults every level to enabled; ids stay null for the
      // repository write boundary to mint exactly once (A9).
      expect(decoded.entries.every((e) => e.enabled), isTrue);
      expect(decoded.entries.every((e) => e.slotId == null), isTrue);
    });

    test('entries missing enabled decode true inside the envelope too', () {
      const encoded =
          '{"chainEnabled":true,"entries":[{"type":1,"params":[0.5,0.8,0,0]}]}';
      final decoded = decodeFxChain(encoded);
      expect(decoded.entries.single.enabled, isTrue);
      expect(decoded.entries.single.slotId, isNull);
    });

    test('unknown envelope keys are ignored (additive-only contract)', () {
      const encoded = '{"chainEnabled":false,"futureKey":1,"entries":[]}';
      final decoded = decodeFxChain(encoded);
      expect(decoded.chainEnabled, isFalse);
      expect(decoded.entries, isEmpty);
    });

    test('malformed / empty input decodes to the empty enabled envelope', () {
      expect(decodeFxChain(null), const FxChainEnvelope());
      expect(decodeFxChain(''), const FxChainEnvelope());
      expect(decodeFxChain('not json'), const FxChainEnvelope());
      expect(decodeFxChain('42'), const FxChainEnvelope());
    });

    test('wrong-TYPED fields never throw — corrupt persisted strings decode '
        'to safe defaults on the uncaught boot path', () {
      // Envelope-level: a non-bool chainEnabled falls back to enabled.
      expect(
        decodeFxChain('{"chainEnabled":1,"entries":[]}'),
        const FxChainEnvelope(),
      );
      expect(
        decodeFxChain('{"chainEnabled":"no","entries":[]}').chainEnabled,
        isTrue,
      );
      // Entry-level: wrong-typed enabled/slotId decode to their defaults.
      final decoded = decodeFxChain(
        '{"chainEnabled":true,"entries":['
        '{"type":1,"params":[0.5,0.8,0,0],"enabled":"true","slotId":123}]}',
      );
      expect(decoded.entries.single.enabled, isTrue);
      expect(decoded.entries.single.slotId, isNull);
      // Wrong-typed entries/meta shapes degrade, never throw.
      expect(
        decodeFxChain('{"chainEnabled":true,"entries":5}').entries,
        isEmpty,
      );
      expect(decodeFxChain('{"meta":[1],"entries":[]}').meta, isNull);
    });

    test('an empty non-inherited meta is not persisted', () {
      final encoded = encodeFxChain(
        const FxChainEnvelope(meta: FxChainMeta()),
      );
      expect(encoded, isNot(contains('meta')));
      expect(decodeFxChain(encoded).meta, isNull);
    });
  });

  group('concatenateInheritedChains (A8)', () {
    test('concatenates in input order and lists full provenance', () {
      final chainA = [BuiltInEffect(type: TrackEffectType.drive)];
      final chainB = [
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.reverb),
      ];

      final result = concatenateInheritedChains([(0, chainA), (3, chainB)]);

      expect(result.entries, [...chainA, ...chainB]);
      expect(result.meta.inheritedFrom, [0, 3]);
    });

    test('a single-input inherit produces a one-element provenance list', () {
      final result = concatenateInheritedChains([
        (2, [BuiltInEffect(type: TrackEffectType.echo)]),
      ]);
      expect(result.meta.inheritedFrom, [2]);
      expect(result.meta.isInherited, isTrue);
    });
  });
}
