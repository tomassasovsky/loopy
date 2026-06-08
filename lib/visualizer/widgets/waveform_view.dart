import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:loopy/theme/theme.dart';

/// Paints a mirrored, centered output waveform from decimated peak [samples]
/// (oldest → newest, each in `0..1`). Colors default to the active
/// [LooperTheme]. Repaints whenever a new sample list is supplied.
class WaveformView extends StatelessWidget {
  /// Creates a [WaveformView].
  const WaveformView({required this.samples, this.color, super.key});

  /// Decimated output peaks, oldest first, each in `0..1`.
  final Float32List samples;

  /// Stroke color; defaults to [LooperTheme.waveformColor].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>();
    return CustomPaint(
      key: const Key('waveform_view_paint'),
      painter: WaveformPainter(
        samples: samples,
        color: color ?? looper?.waveformColor ?? Colors.tealAccent,
      ),
      size: Size.infinite,
    );
  }
}

/// The [CustomPainter] backing [WaveformView]; public so it can be unit-tested.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({required this.samples, required this.color});

  /// Decimated output peaks, oldest first, each in `0..1`.
  final Float32List samples;

  /// Waveform color.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;
    final dx = size.width / samples.length;
    final fill = Paint()..color = color;
    final barWidth = dx < 1.5 ? dx : dx * 0.7;

    for (var i = 0; i < samples.length; i++) {
      final amp = samples[i].clamp(0.0, 1.0);
      if (amp <= 0) continue;
      final half = amp * midY;
      final x = i * dx;
      canvas.drawRect(
        Rect.fromLTRB(x, midY - half, x + barWidth, midY + half),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) || oldDelegate.color != color;
}
