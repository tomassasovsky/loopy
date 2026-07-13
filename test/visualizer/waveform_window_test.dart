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
          (id: 'primary', position: Offset.zero, size: Size(1920, 1080)),
        ],
        primaryId: 'primary',
        args: args,
      );

      expect(placement.fullscreen, isFalse);
      expect(placement.position, const Offset(120, 120));
      expect(placement.size, const Size(960, 320));
    });

    test('a secondary display → full-bleed on it', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (id: 'primary', position: Offset.zero, size: Size(1920, 1080)),
          (id: 'second', position: Offset(1920, 0), size: Size(2560, 1440)),
        ],
        primaryId: 'primary',
        args: args,
      );

      expect(placement.fullscreen, isTrue);
      expect(placement.position, const Offset(1920, 0));
      expect(placement.size, const Size(2560, 1440));
    });

    test('picks the first non-primary display when there are several', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (id: 'a', position: Offset.zero, size: Size(1920, 1080)),
          (id: 'b', position: Offset(1920, 0), size: Size(1280, 720)),
          (id: 'c', position: Offset(3200, 0), size: Size(1280, 720)),
        ],
        primaryId: 'b',
        args: args,
      );

      // 'a' is the first that is not the primary ('b').
      expect(placement.fullscreen, isTrue);
      expect(placement.position, Offset.zero);
      expect(placement.size, const Size(1920, 1080));
    });
  });
}
