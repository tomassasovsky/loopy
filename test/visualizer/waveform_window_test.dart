import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/visualizer/waveform_window.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';

void main() {
  group('waveformWindowPlacement', () {
    const args = WaveformWindowArgs(); // defaults: 120, 120, 960x320

    test('a single (primary-only) display → the windowed fallback', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1920, 1080),
            scale: 1,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1,
        args: args,
      );

      expect(placement.fullscreen, isFalse);
      expect(placement.position, const Offset(120, 120));
      expect(placement.size, const Size(960, 320));
    });

    test('a secondary display at the same DPI → full-bleed on it', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1920, 1080),
            scale: 1,
          ),
          (
            id: 'second',
            position: Offset(1920, 0),
            size: Size(2560, 1440),
            scale: 1,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1,
        args: args,
      );

      expect(placement.fullscreen, isTrue);
      expect(placement.position, const Offset(1920, 0));
      expect(placement.size, const Size(2560, 1440));
    });

    test('picks the first non-primary display when there are several', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (id: 'a', position: Offset.zero, size: Size(1920, 1080), scale: 1),
          (id: 'b', position: Offset(1920, 0), size: Size(1280, 720), scale: 1),
          (id: 'c', position: Offset(3200, 0), size: Size(1280, 720), scale: 1),
        ],
        primaryId: 'b',
        primaryScale: 1,
        args: args,
      );

      // 'a' is the first that is not the primary ('b').
      expect(placement.fullscreen, isTrue);
      expect(placement.position, Offset.zero);
      expect(placement.size, const Size(1920, 1080));
    });

    test(
      'a higher-DPI secondary is rescaled into the primary window space',
      () {
        // A 4K (3840x2160) secondary at 175% sits physically to the right of a
        // 100% primary. `screen_retriever` reports it in *its own* logical
        // units (physical / 1.75): origin x=1463, size 2194x1234. The placement
        // must convert back to the primary window's space (physical, since the
        // primary is 100%): origin x=2560, size 3840x2160 — the true monitor
        // bounds. This is the multi-DPI case the plain pass-through got wrong.
        final placement = waveformWindowPlacement(
          screens: const [
            (
              id: 'primary',
              position: Offset.zero,
              size: Size(2560, 1440),
              scale: 1,
            ),
            (
              id: 'second',
              position: Offset(1463, 0),
              size: Size(2194, 1234),
              scale: 1.75,
            ),
          ],
          primaryId: 'primary',
          primaryScale: 1,
          args: args,
        );

        expect(placement.fullscreen, isTrue);
        expect(placement.position.dx, closeTo(2560, 1));
        expect(placement.position.dy, 0);
        expect(placement.size.width, closeTo(3840, 1));
        expect(placement.size.height, closeTo(2160, 1));
      },
    );

    test('rescales relative to the primary DPI, not absolutely', () {
      // Both displays at 150%: the secondary's own-logical bounds are already
      // in the primary's logical space, so `scale / primaryScale == 1` leaves
      // them untouched (no spurious 1.5x blow-up).
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1280, 720),
            scale: 1.5,
          ),
          (
            id: 'second',
            position: Offset(1280, 0),
            size: Size(1280, 720),
            scale: 1.5,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1.5,
        args: args,
      );

      expect(placement.fullscreen, isTrue);
      expect(placement.position, const Offset(1280, 0));
      expect(placement.size, const Size(1280, 720));
    });
  });
}
