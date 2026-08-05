import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// Paints a mirrored, centered loop waveform from peak [samples] (index 0 =
/// loop start, each in `0..1`) with a white playhead bar at [progress]
/// (`0..1`). The stroke colour comes from the active [LooperTheme]'s waveform
/// table, keyed by [state]. Repaints on a new list or progress is supplied.
class WaveformView extends StatelessWidget {
  /// Creates a [WaveformView].
  const WaveformView({
    required this.samples,
    required this.state,
    this.progress = 0,
    this.semanticLabel,
    this.selectedTrack,
    super.key,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`; the white bar is hidden when `<= 0`.
  final double progress;

  /// The transport state the stroke colour speaks for — the [selectedTrack]'s,
  /// so the colour and the name label describe the same track. Required: the
  /// waveform is part of the transport legend, so there is no such thing as
  /// "the waveform colour" without a state to resolve it against.
  final LooperMeterState state;

  /// Accessible name for the otherwise-opaque waveform (WCAG 1.1.1). When set,
  /// the view is exposed to screen readers with this label and a playhead-
  /// position value; null leaves it decorative (the caller supplies the locale-
  /// resolved string, since this widget can run in a window without l10n).
  final String? semanticLabel;

  /// The name of the selected track.
  final String? selectedTrack;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>();
    final theme = Theme.of(context);
    // Paint the themed backdrop here rather than leaving it to each caller: the
    // state colours carry alpha, so what sits behind them decides what they
    // actually render as — and the contrast floors in `test/theme/` are
    // measured against this token.
    final background = looper?.waveformBackground ?? Colors.black;
    // Null-guarded like the LooperTheme above: this view also runs in the
    // second window, which is a separate engine.
    final surface = theme.extension<SurfaceTheme>();
    final paint = CustomPaint(
      key: const Key('waveform_view_paint'),
      painter: WaveformPainter(
        samples: samples,
        progress: progress,
        color: looper?.waveformColor(state) ?? Colors.tealAccent,
        background: background,
      ),
      size: Size.infinite,
    );
    // if (semanticLabel == null) return paint;
    return Semantics(
      label: semanticLabel,
      value: '${(progress.clamp(0.0, 1.0) * 100).round()}%',
      child: ColoredBox(
        color: background,
        child: Stack(
          children: [
            paint,
            if (selectedTrack != null)
              Align(
                alignment: Alignment.topCenter,
                child: Text(
                  selectedTrack!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: surface?.textPrimary ?? Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The [CustomPainter] backing [WaveformView]; public so it can be unit-tested.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({
    required this.samples,
    required this.color,
    required this.background,
    this.progress = 0,
  });

  /// Loop waveform peaks, index 0 = loop start, each in `0..1`.
  final Float32List samples;

  /// Playhead position in `0..1`.
  final double progress;

  /// Waveform color.
  final Color color;

  /// The surface the waveform is drawn on. Used to cut the playhead free of
  /// the bars — see [paint].
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;

    // A faint baseline so the surface reads as "ready" even with no audio.
    canvas.drawRect(
      Rect.fromLTWH(0, midY - 0.5, size.width, 1),
      Paint()..color = color.withValues(alpha: 0.18),
    );

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
      // A background-coloured gutter either side of the playhead. It vanishes
      // against the empty surface, but where bars cover the playhead it cuts
      // them away from it — without this the white playhead is invisible
      // wherever the waveform is itself white, which the not-sounding states
      // are (opaque white in high contrast). Drawn before the bar so the bar
      // stays a crisp 2px.
      canvas
        ..drawRect(
          Rect.fromLTWH(x - 2, 0, 4, size.height),
          Paint()..color = background,
        )
        ..drawRect(
          Rect.fromLTWH(x - 1, 0, 2, size.height),
          Paint()..color = Colors.white,
        );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      !identical(oldDelegate.samples, samples) ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.background != background;
}
