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
        BuiltInEffect(type: TrackEffectType.filter),
        // A 3-value chain (the 4th param is omitted) must round-trip padded
        // with the type's own default for the trailing slot.
        BuiltInEffect(
          type: TrackEffectType.delay,
          params: const [0.3, 0.42, 0.5],
        ),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded.map((e) => (e as BuiltInEffect).type), [
        TrackEffectType.filter,
        TrackEffectType.delay,
      ]);
      expect(
        (decoded[0] as BuiltInEffect).params,
        TrackEffectType.filter.defaultParams,
      );
      expect((decoded[1] as BuiltInEffect).params, [0.3, 0.42, 0.5, 0]);
    });

    test('reads a chain written by the engine serializer (wire-format '
        'compat)', () {
      final engineEncoded = engine.encodeTrackEffects([
        engine.BuiltInEffect(type: engine.TrackEffectType.reverb),
        engine.BuiltInEffect(type: engine.TrackEffectType.octaver),
      ]);

      final decoded = decodeTrackEffects(engineEncoded);

      expect(decoded.map((e) => (e as BuiltInEffect).type), [
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
        BuiltInEffect(type: TrackEffectType.drive).params,
        TrackEffectType.drive.defaultParams,
      );
    });

    test('value equality is by type and params', () {
      expect(
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.drive),
      );
      expect(
        BuiltInEffect(type: TrackEffectType.drive),
        isNot(BuiltInEffect(type: TrackEffectType.filter)),
      );
    });

    test('copyWith replaces type while keeping params', () {
      final fx = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3, 0.4],
      );

      final swapped = fx.copyWith(type: TrackEffectType.echo);

      expect(swapped.type, TrackEffectType.echo);
      expect(swapped.params, [0.1, 0.2, 0.3, 0.4]);
    });
  });

  group('PluginEffect (domain)', () {
    const ref = PluginRef(
      format: PluginFormat.clap,
      id: 'com.acme.reverb',
      version: 0x00010200,
    );

    test('value equality, copyWith, and typeCode', () {
      expect(const PluginEffect(ref: ref), const PluginEffect(ref: ref));
      expect(const PluginEffect(ref: ref).typeCode, 8);
      const other = PluginRef(format: PluginFormat.vst3, id: 'x');
      expect(const PluginEffect(ref: ref).copyWith(ref: other).ref, other);
      expect(
        const PluginEffect(ref: ref),
        isNot(const PluginEffect(ref: other)),
      );
    });

    test('loading is a distinct, copyable, equality-bearing flag (F5)', () {
      const base = PluginEffect(ref: ref);
      expect(base.loading, isFalse);
      final loading = base.copyWith(loading: true);
      expect(loading.loading, isTrue);
      expect(loading, isNot(base));
      // Clearing it (a resolved bind) restores equality.
      expect(loading.copyWith(loading: false), base);
    });

    test('PluginRef equality includes format, id, and version', () {
      expect(
        ref,
        const PluginRef(
          format: PluginFormat.clap,
          id: 'com.acme.reverb',
          version: 0x00010200,
        ),
      );
      expect(
        ref,
        isNot(
          const PluginRef(
            format: PluginFormat.vst3,
            id: 'com.acme.reverb',
            version: 0x00010200,
          ),
        ),
      );
      expect(
        ref,
        isNot(
          const PluginRef(
            format: PluginFormat.clap,
            id: 'other',
            version: 0x00010200,
          ),
        ),
      );
      expect(
        ref,
        isNot(
          const PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
        ),
      );
    });

    test('a domain plugin chain round-trips through the engine serializer', () {
      // Exercises the repo boundary mappers (_trackEffectToEngine /
      // _trackEffectFromEngine plugin arms + the format/version mapping) — a
      // format or version swap must survive encode -> decode unchanged.
      final chain = <TrackEffect>[
        BuiltInEffect(type: TrackEffectType.drive),
        const PluginEffect(ref: ref),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'TUID-HEX'),
        ),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded, chain);
      expect(decoded[1], isA<PluginEffect>());
      expect((decoded[1] as PluginEffect).ref.format, PluginFormat.clap);
      expect((decoded[2] as PluginEffect).ref.format, PluginFormat.vst3);
    });

    test('opaque state survives the engine-serializer round-trip', () {
      final chain = <TrackEffect>[
        const PluginEffect(ref: ref, state: 'YmxvYg=='),
      ];
      final decoded = decodeTrackEffects(encodeTrackEffects(chain));
      expect(decoded, chain);
      expect((decoded.single as PluginEffect).state, 'YmxvYg==');
    });

    test('paramValues survive the engine-serializer round-trip', () {
      final chain = <TrackEffect>[
        const PluginEffect(ref: ref, paramValues: {100: 0.25, 300: 0.9}),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded, chain);
      expect((decoded.single as PluginEffect).paramValues, {
        100: 0.25,
        300: 0.9,
      });
    });

    test(
      'paramValues and params participate in/are excluded from equality',
      () {
        const base = PluginEffect(ref: ref);
        // paramValues is persisted state — it counts toward equality.
        expect(
          const PluginEffect(ref: ref, paramValues: {100: 0.5}),
          isNot(base),
        );
        // params is transient metadata — Equatable props include it, so a card
        // can rebuild when it arrives, but it never persists.
        const withMeta = PluginEffect(
          ref: ref,
          params: [
            PluginParamInfo(
              id: 100,
              name: 'Gain',
              unit: 'dB',
              min: 0,
              max: 1,
              def: 0.5,
              stepCount: 0,
              flags: 0x01,
            ),
          ],
        );
        expect(encodeTrackEffects([withMeta]), encodeTrackEffects([base]));
      },
    );
  });

  group('enabled + slotId (R16/A9)', () {
    const ref = PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb');

    test('default enabled=true, slotId=null on both subtypes', () {
      expect(BuiltInEffect(type: TrackEffectType.drive).enabled, isTrue);
      expect(BuiltInEffect(type: TrackEffectType.drive).slotId, isNull);
      expect(const PluginEffect(ref: ref).enabled, isTrue);
      expect(const PluginEffect(ref: ref).slotId, isNull);
    });

    test('copyWith threads both fields and preserves them by default', () {
      final builtIn = BuiltInEffect(
        type: TrackEffectType.delay,
        enabled: false,
        slotId: 's-1',
      );
      final tweaked = builtIn.copyWith(params: const [0.1, 0.2, 0.3, 0.4]);
      expect(tweaked.enabled, isFalse);
      expect(tweaked.slotId, 's-1');
      expect(builtIn.copyWith(enabled: true).enabled, isTrue);
      expect(builtIn.copyWith(slotId: 's-2').slotId, 's-2');

      const plugin = PluginEffect(ref: ref, enabled: false, slotId: 'p-1');
      final relinked = plugin.copyWith(name: 'Acme');
      expect(relinked.enabled, isFalse);
      expect(relinked.slotId, 'p-1');
    });

    test('equality includes both fields — two otherwise-identical effects '
        'with different ids are different entries (A9)', () {
      expect(
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'a'),
        isNot(BuiltInEffect(type: TrackEffectType.drive, slotId: 'b')),
      );
      expect(
        BuiltInEffect(type: TrackEffectType.drive, enabled: false),
        isNot(BuiltInEffect(type: TrackEffectType.drive)),
      );
      expect(
        const PluginEffect(ref: ref, slotId: 'a'),
        isNot(const PluginEffect(ref: ref, slotId: 'b')),
      );
      expect(
        const PluginEffect(ref: ref, enabled: false),
        isNot(const PluginEffect(ref: ref)),
      );
    });

    test('both fields survive the boundary mappers in BOTH arms (the '
        'engine-serializer round-trip) [R16]', () {
      final chain = <TrackEffect>[
        BuiltInEffect(
          type: TrackEffectType.delay,
          enabled: false,
          slotId: 'built-in-1',
        ),
        const PluginEffect(ref: ref, enabled: false, slotId: 'plugin-1'),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded, chain);
      expect(decoded[0].enabled, isFalse);
      expect(decoded[0].slotId, 'built-in-1');
      expect(decoded[1].enabled, isFalse);
      expect(decoded[1].slotId, 'plugin-1');
    });

    test('legacy entries decode enabled=true with a null slotId', () {
      // A pre-FX-v3 wire chain: no enabled / slotId keys anywhere.
      final decoded = decodeTrackEffects(
        '[{"type":3,"params":[0.3,0.4,0.5,0]},'
        '{"type":8,"plugin":{"format":1,"id":"p","version":0}}]',
      );
      expect(decoded, hasLength(2));
      expect(decoded.every((e) => e.enabled), isTrue);
      expect(decoded.every((e) => e.slotId == null), isTrue);
    });

    test('default-valued fields are omitted from the wire (legacy-stable '
        'encoding)', () {
      final encoded = encodeTrackEffects([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      expect(encoded, isNot(contains('enabled')));
      expect(encoded, isNot(contains('slotId')));
    });
  });

  group('fxChainFingerprint', () {
    const ref = PluginRef(format: PluginFormat.clap, id: 'p');

    test('an empty chain hashes to the FNV offset basis', () {
      expect(
        fxChainFingerprint(const <TrackEffect>[]),
        engine.FxFingerprint.offset,
      );
    });

    test('is deterministic for the same chain', () {
      final a = [BuiltInEffect(type: TrackEffectType.drive)];
      final b = [BuiltInEffect(type: TrackEffectType.drive)];
      expect(fxChainFingerprint(a), fxChainFingerprint(b));
    });

    test('is order-sensitive', () {
      final ab = [
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.reverb),
      ];
      expect(
        fxChainFingerprint(ab),
        isNot(fxChainFingerprint(ab.reversed.toList())),
      );
    });

    test('reflects a parameter change', () {
      final a = [
        BuiltInEffect(
          type: TrackEffectType.delay,
          params: const [0.3, 0, 0, 0],
        ),
      ];
      final b = [
        BuiltInEffect(
          type: TrackEffectType.delay,
          params: const [0.9, 0, 0, 0],
        ),
      ];
      expect(fxChainFingerprint(a), isNot(fxChainFingerprint(b)));
    });

    test('the per-slot enabled bit changes the hash (R16)', () {
      final enabled = [BuiltInEffect(type: TrackEffectType.drive)];
      final disabled = [
        BuiltInEffect(type: TrackEffectType.drive, enabled: false),
      ];
      expect(
        fxChainFingerprint(enabled),
        isNot(fxChainFingerprint(disabled)),
      );
      // A plugin's enabled bit folds too.
      const pRef = PluginRef(format: PluginFormat.clap, id: 'p');
      expect(
        fxChainFingerprint(const [PluginEffect(ref: pRef)]),
        isNot(
          fxChainFingerprint(const [PluginEffect(ref: pRef, enabled: false)]),
        ),
      );
    });

    test('the chain-enabled flag changes the hash — but only for a NON-empty '
        'chain (D-FPEMPTY)', () {
      final chain = [BuiltInEffect(type: TrackEffectType.drive)];
      expect(
        fxChainFingerprint(chain),
        isNot(fxChainFingerprint(chain, chainEnabled: false)),
      );
      // Empty chains hash to the offset basis regardless of the flag: a
      // chain-disabled empty chain and an enabled empty chain are both dry.
      expect(
        fxChainFingerprint(const <TrackEffect>[], chainEnabled: false),
        engine.FxFingerprint.offset,
      );
    });

    test('slotId does NOT fold — sound identity, not entry identity (A9)', () {
      expect(
        fxChainFingerprint([
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'a'),
        ]),
        fxChainFingerprint([
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'b'),
        ]),
      );
    });

    test('a plugin entry folds in its type only (not host-owned params)', () {
      // Two plugins with different paramValues fingerprint the same — the
      // engine stores no plugin params in a_fx_param, so the fingerprint must
      // not either (it would never match the engine otherwise).
      final a = [
        const PluginEffect(ref: ref, paramValues: {1: 0.2}),
      ];
      final b = [
        const PluginEffect(ref: ref, paramValues: {1: 0.8}),
      ];
      expect(fxChainFingerprint(a), fxChainFingerprint(b));
      // But a plugin differs from a built-in.
      final builtIn = [BuiltInEffect(type: TrackEffectType.drive)];
      expect(
        fxChainFingerprint(a),
        isNot(fxChainFingerprint(builtIn)),
      );
    });
  });
}
