import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The wet/dry colour legend: a solid swatch for the effected (wet) send and a
/// dashed swatch for the clean (dry) send.
class RouteLegend extends StatelessWidget {
  /// Creates a [RouteLegend].
  const RouteLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Row(
      children: [
        _LegendKey(
          color: surface.wetRoute,
          label: l10n.legendEffectedWet,
          dashed: false,
        ),
        const SizedBox(width: 20),
        _LegendKey(
          color: surface.dryRoute,
          label: l10n.legendCleanDry,
          dashed: true,
        ),
      ],
    );
  }
}

class _LegendKey extends StatelessWidget {
  const _LegendKey({
    required this.color,
    required this.label,
    required this.dashed,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 26,
          height: 12,
          child: CustomPaint(
            painter: _LegendLinePainter(color, dashed: dashed),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: context.surface.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

/// Draws a short solid/dashed colour swatch for the wet/dry legend.
class _LegendLinePainter extends CustomPainter {
  _LegendLinePainter(this.color, {required this.dashed});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = color;
    final y = size.height / 2;
    if (dashed) {
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(x + 5, y), paint);
        x += 9;
      }
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_LegendLinePainter old) =>
      old.color != color || old.dashed != dashed;
}
