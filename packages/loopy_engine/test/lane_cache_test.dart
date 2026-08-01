import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('LaneCacheState.fromNative', () {
    test('maps every documented le_cache_state code', () {
      // The codes are the native enum's, spelled out here rather than derived,
      // so a renumbering on the C side fails this test instead of silently
      // relabelling every glyph (loopy_engine_api.h, le_cache_state).
      expect(LaneCacheState.fromNative(0), LaneCacheState.live);
      expect(LaneCacheState.fromNative(1), LaneCacheState.rendering);
      expect(LaneCacheState.fromNative(2), LaneCacheState.cached);
      expect(LaneCacheState.fromNative(3), LaneCacheState.failedRetrying);
      expect(LaneCacheState.fromNative(4), LaneCacheState.gaveUp);
    });

    test('falls back to live for an unknown code', () {
      // Claiming "cached" for a state this build doesn't recognize would be
      // the one wrong answer — live is the honest default, and it matches the
      // cache's own "when in doubt, play live" contract.
      expect(LaneCacheState.fromNative(99), LaneCacheState.live);
      expect(LaneCacheState.fromNative(-1), LaneCacheState.live);
    });
  });

  group('MockAudioEngine.laneCacheState', () {
    test('reports live for a lane nothing seeded', () {
      final engine = MockAudioEngine();
      expect(
        engine.laneCacheState(channel: 0, lane: 0),
        LaneCacheState.live,
      );
    });

    test('reports a seeded state for exactly its own lane', () {
      final engine = MockAudioEngine()
        ..laneCacheStates[(1, 0)] = LaneCacheState.cached;

      expect(
        engine.laneCacheState(channel: 1, lane: 0),
        LaneCacheState.cached,
      );
      expect(
        engine.laneCacheState(channel: 1, lane: 1),
        LaneCacheState.live,
      );
      expect(
        engine.laneCacheState(channel: 0, lane: 0),
        LaneCacheState.live,
      );
    });
  });
}
