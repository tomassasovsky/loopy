import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:loopy/theme/theme.dart';

/// Paints a mirrored, centered loop waveform from peak [samples] (index 0 =
/// loop start, each in `0..1`) with a white playhead bar at [progress]
/// (`0..1`). Colors default to the active [LooperTheme]. Repaints on a new list
/// or progress is supplied.
class WaveformView extends StatelessWidget {
  /// Creates a [WaveformView].
  const WaveformView({
    required this.samples,
    this.progress = 0,
    this.color,
    super.key,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`; the white bar is hidden when `<= 0`.
  final double progress;

  /// Stroke color; defaults to [LooperTheme.waveformColor].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>();
    return CustomPaint(
      key: const Key('waveform_view_paint'),
      painter: WaveformPainter(
        samples: samples,
        progress: progress,
        color: color ?? looper?.waveformColor ?? Colors.tealAccent,
      ),
      size: Size.infinite,
    );
  }
}

/// The [CustomPainter] backing [WaveformView]; public so it can be unit-tested.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({
    required this.samples,
    required this.color,
    this.progress = 0,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`.
  final double progress;

  /// Waveform color.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;

    if (samples.isNotEmpty) {
      final dx = size.width / samples.length;
      final barWidth = dx < 1.5 ? dx : dx * 0.7;
      final fill = Paint()..color = color;
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

    if (progress > 0) {
      final x = (progress.clamp(0.0, 1.0)) * size.width;
      canvas.drawRect(
        Rect.fromLTWH(x - 1, 0, 2, size.height),
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color;
}
