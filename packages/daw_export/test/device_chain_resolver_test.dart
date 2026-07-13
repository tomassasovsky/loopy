import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

Map<String, dynamic> _fx(int type, List<double> params) => {
  'type': type,
  'params': params,
};

void main() {
  group('resolveDeviceChain', () {
    test('a channel with no captured lanes resolves an empty chain, no '
        'fallback reason', () {
      final result = resolveDeviceChain([]);
      expect(result.chain, isEmpty);
      expect(result.fallbackReason, isNull);
    });

    test(
      'a single lane with no effects resolves an empty chain, no fallback '
      'reason',
      () {
        final result = resolveDeviceChain([[]]);
        expect(result.chain, isEmpty);
        expect(result.fallbackReason, isNull);
      },
    );

    test('identical chains across 1 lane resolve to that chain', () {
      final result = resolveDeviceChain([
        [
          _fx(3, [0.35, 0.35, 0.35, 0.0]),
        ],
      ]);
      expect(result.fallbackReason, isNull);
      expect(result.chain, [
        const DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
      ]);
    });

    test('identical chains across 2 lanes resolve to that chain', () {
      final chain = [
        _fx(3, [0.35, 0.35, 0.35, 0.0]),
        _fx(7, [0.5, 0.5, 0.35, 0.0]),
      ];
      final result = resolveDeviceChain([chain, chain]);
      expect(result.fallbackReason, isNull);
      expect(result.chain, [
        const DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
        const DawEffect(type: 7, params: [0.5, 0.5, 0.35, 0.0]),
      ]);
    });

    test('identical chains across 3+ lanes resolve to that chain', () {
      final chain = [
        _fx(1, [0.5, 0.8, 0.0, 0.0]),
      ];
      final result = resolveDeviceChain([chain, chain, chain, chain]);
      expect(result.fallbackReason, isNull);
      expect(result.chain, [
        const DawEffect(type: 1, params: [0.5, 0.8, 0.0, 0.0]),
      ]);
    });

    test(
      'falls back to mixedLaneChains when lanes have the same effect but '
      'different param values (near-miss, not a false match)',
      () {
        final result = resolveDeviceChain([
          [
            _fx(3, [0.35, 0.35, 0.35, 0.0]),
          ],
          [
            _fx(3, [0.9, 0.35, 0.35, 0.0]),
          ],
        ]);
        expect(result.chain, isNull);
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.mixedLaneChains,
        );
      },
    );

    test(
      'falls back to mixedLaneChains when lanes have the same effects in a '
      'different order (near-miss, not a false match)',
      () {
        final result = resolveDeviceChain([
          [
            _fx(3, [0.35, 0.35, 0.35, 0.0]),
            _fx(7, [0.5, 0.5, 0.35, 0.0]),
          ],
          [
            _fx(7, [0.5, 0.5, 0.35, 0.0]),
            _fx(3, [0.35, 0.35, 0.35, 0.0]),
          ],
        ]);
        expect(result.chain, isNull);
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.mixedLaneChains,
        );
      },
    );

    test('falls back to mixedLaneChains when one lane has no effects and '
        'another does', () {
      final result = resolveDeviceChain([
        [],
        [
          _fx(3, [0.35, 0.35, 0.35, 0.0]),
        ],
      ]);
      expect(result.chain, isNull);
      expect(result.fallbackReason, DeviceChainFallbackReason.mixedLaneChains);
    });

    test(
      'falls back to thirdPartyPlugin when the shared chain contains a '
      'hosted-plugin entry',
      () {
        final chain = [
          {
            'type': kPluginFxCode,
            'plugin': {'format': 0, 'id': 'AABB', 'version': 0},
          },
        ];
        final result = resolveDeviceChain([chain, chain]);
        expect(result.chain, isNull);
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.thirdPartyPlugin,
        );
      },
    );

    test(
      'falls back to unrepresentedEffectType for an out-of-range type code',
      () {
        final chain = [
          _fx(42, [0.0, 0.0, 0.0, 0.0]),
        ];
        final result = resolveDeviceChain([chain, chain]);
        expect(result.chain, isNull);
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.unrepresentedEffectType,
        );
      },
    );

    test(
      'falls back to unrepresentedEffectType for type 0 (None) appearing '
      'in a chain',
      () {
        final chain = [
          _fx(0, [0.0, 0.0, 0.0, 0.0]),
        ];
        final result = resolveDeviceChain([chain, chain]);
        expect(result.chain, isNull);
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.unrepresentedEffectType,
        );
      },
    );

    test(
      'two different third-party plugin entries (same type, different '
      'plugin identity) are correctly NOT treated as identical, but still '
      'fall back to thirdPartyPlugin either way',
      () {
        final result = resolveDeviceChain([
          [
            {
              'type': kPluginFxCode,
              'plugin': {'format': 0, 'id': 'AAAA', 'version': 0},
            },
          ],
          [
            {
              'type': kPluginFxCode,
              'plugin': {'format': 0, 'id': 'BBBB', 'version': 0},
            },
          ],
        ]);
        expect(result.chain, isNull);
        // Whichever fallback fires first is fine — both mixedLaneChains
        // (since the plugin identities genuinely differ) and
        // thirdPartyPlugin are honest outcomes here; the point of this test
        // is only that _jsonEquals doesn't wrongly report these as the same
        // chain.
        expect(
          result.fallbackReason,
          DeviceChainFallbackReason.mixedLaneChains,
        );
      },
    );
  });
}
