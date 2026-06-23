import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A rotary **knob** — the instrument-panel control that replaces a flat slider
/// for the mix level. Drag up/down (or use arrow keys when focused) to turn it;
/// a glowing indicator sweeps a 270° arc and a mono caption reads the value.
///
/// Fully keyboard- and screen-reader-operable: it exposes the `slider`
/// semantics (value + increase/decrease actions) a [Slider] would, so swapping
/// the slider for the knob keeps WCAG 2.1.1 / 4.1.2 intact.
class SignalKnob extends StatelessWidget {
  /// Creates a [SignalKnob].
  const SignalKnob({
    required this.value,
    required this.onChanged,
    required this.label,
    required this.color,
    this.max = 1,
    this.readoutBuilder,
    this.resetValue,
    this.snapTargets = const [],
    this.knobKey,
    this.size = 52,
    super.key,
  });

  /// The current value, `0..max`.
  final double value;

  /// The maximum value (unity is `1.0` = 0 dB; a mix knob uses `2.0` = +6 dB).
  final double max;

  /// Called with the new clamped value as the knob turns.
  final ValueChanged<double> onChanged;

  /// The mono caption under the knob (e.g. `VOL`).
  final String label;

  /// The lit accent colour of the indicator + glow.
  final Color color;

  /// Overrides the readout text (e.g. a `%` or unit for an FX parameter);
  /// defaults to the signed-dB gain readout.
  final String Function(double value)? readoutBuilder;

  /// The value a double-tap restores (e.g. unity gain, or a param's default).
  final double? resetValue;

  /// Values the knob "catches" on (detents) as it's turned — e.g. unity gain.
  final List<double> snapTargets;

  /// Optional key on the interactive surface (for tests).
  final Key? knobKey;

  /// The knob's diameter in logical pixels.
  final double size;

  /// 270° of travel, centred at the top: −135°..+135°.
  static const double _sweep = 1.5 * math.pi;
  static const double _start = -0.75 * math.pi;

  /// A linear gain [v] as a signed dB readout, to one decimal (`+6.0 dB`,
  /// `0.0 dB`, `−3.5 dB`, `−∞`).
  static String _readout(double v) {
    if (v <= 0.001) return '−∞';
    final db = 20 * (math.log(v) / math.ln10);
    if (db.abs() < 0.05) return '0.0 dB';
    return '${db >= 0 ? '+' : '−'}${db.abs().toStringAsFixed(1)} dB';
  }

  static const double _snapTol = 0.022;

  /// Snaps [v] to the nearest detent within a small fraction of full travel.
  double _snap(double v) {
    for (final t in snapTargets) {
      if ((v - t).abs() <= _snapTol * max) return t;
    }
    return v;
  }

  /// Moves the knob by a fraction of its full travel. While [settle] is false
  /// (a live drag) the value passes through freely, so a detent never traps the
  /// gesture; the catch is applied on release / discrete steps instead.
  void _move(double deltaNorm, {bool settle = false}) {
    final next = (value + deltaNorm * max).clamp(0.0, max);
    onChanged(settle ? _snap(next) : next);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final v = value.clamp(0.0, max);
    final norm = max <= 0 ? 0.0 : (v / max).clamp(0.0, 1.0);
    final angle = _start + _sweep * norm;
    final read = readoutBuilder ?? _readout;
    return Semantics(
      slider: true,
      value: read(v),
      increasedValue: read((v + 0.05 * max).clamp(0.0, max)),
      decreasedValue: read((v - 0.05 * max).clamp(0.0, max)),
      onIncrease: () => _move(0.05, settle: true),
      onDecrease: () => _move(-0.05, settle: true),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Focus(
            // Arrow keys live on the focusable node itself (the one `onTap`
            // focuses), so they actually fire — and there's no per-build
            // FocusNode to leak.
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.arrowUp ||
                  key == LogicalKeyboardKey.arrowRight) {
                _move(0.05, settle: true);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowDown ||
                  key == LogicalKeyboardKey.arrowLeft) {
                _move(-0.05, settle: true);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Builder(
              builder: (context) {
                final focused = Focus.of(context).hasFocus;
                return GestureDetector(
                  key: knobKey,
                  // The whole face is draggable, including its unpainted
                  // corners, so a grab never falls through the gaps.
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Focus.of(context).requestFocus(),
                  // Double-tap restores the default (unity gain / param default).
                  onDoubleTap: resetValue == null
                      ? null
                      : () => onChanged(resetValue!.clamp(0.0, max)),
                  // Vertical drag is the studio convention: up turns it up.
                  // Free while dragging; the detent catch lands on release.
                  onVerticalDragUpdate: (d) => _move(-d.delta.dy * 0.006),
                  onVerticalDragEnd: (_) =>
                      onChanged(_snap(value.clamp(0.0, max))),
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: CustomPaint(
                      painter: _KnobPainter(
                        value: norm,
                        angle: angle,
                        color: color,
                        trackColor: surface.line,
                        faceTop: const Color(0xFF23232B),
                        faceBottom: const Color(0xFF121217),
                        focused: focused,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 7),
          // Captions stay single-line + centred so the column keeps the knob's
          // footprint even in a fixed-width slot (an FX device card); a wide
          // readout ellipsises rather than wrapping and shoving the layout.
          SizedBox(
            width: size * 1.5,
            child: Text(
              label.toUpperCase(),
              style: signalMono(
                color: surface.textTertiary,
                size: 9,
                tracking: 1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: size * 1.5,
            child: Text(
              read(v),
              style: signalMono(color: surface.textSecondary, size: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({
    required this.value,
    required this.angle,
    required this.color,
    required this.trackColor,
    required this.faceTop,
    required this.faceBottom,
    required this.focused,
  });

  final double value;
  final double angle;
  final Color color;
  final Color trackColor;
  final Color faceTop;
  final Color faceBottom;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final arcRect = Rect.fromCircle(center: center, radius: r - 3);

    // Unlit arc track (the full 270° sweep).
    canvas.drawArc(
      arcRect,
      SignalKnob._start,
      SignalKnob._sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = trackColor,
    );
    // Lit arc up to the current value, with a soft glow.
    final sweep = SignalKnob._sweep * value;
    canvas
      ..drawArc(
        arcRect,
        SignalKnob._start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.30)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      )
      ..drawArc(
        arcRect,
        SignalKnob._start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = color,
      );

    // The knob face — a radial-gradient cap.
    final faceR = r - 9;
    canvas
      ..drawCircle(
        center,
        faceR,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.35),
            colors: [faceTop, faceBottom],
          ).createShader(Rect.fromCircle(center: center, radius: faceR)),
      )
      ..drawCircle(
        center,
        faceR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = focused ? color : trackColor,
      );

    // The pointer line from just inside the face toward the cap edge.
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas
      ..drawLine(
        center + dir * (faceR * 0.30),
        center + dir * (faceR * 0.92),
        Paint()
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawLine(
        center + dir * (faceR * 0.30),
        center + dir * (faceR * 0.92),
        Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.value != value || old.focused != focused || old.color != color;
}
