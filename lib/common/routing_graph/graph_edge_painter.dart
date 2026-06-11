import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';

/// Paints a list of [GraphEdge]s as smooth bezier wires.
///
/// Every wire leaves and enters horizontally with the same tangent: a fixed
/// control-handle length (clamped on short hops so they stay straight) gives a
/// uniform curvature across the whole graph. Faded wires are painted first so
/// the focused row's wires sit on top; dashed edges are stroked in segments.
class GraphEdgePainter extends CustomPainter {
  /// Creates a painter for [edges].
  GraphEdgePainter(this.edges);

  /// The wires to paint, in build order (faded ones are still drawn first).
  final List<GraphEdge> edges;

  /// The fixed horizontal control-handle length for every wire, so all curves
  /// share one tangent — a uniform, standard bend.
  static const double curveHandle = 48;

  void _draw(Canvas canvas, GraphEdge e) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = e.faded ? 1.4 : 2.4
      ..color = e.color.withValues(alpha: e.faded ? 0.22 : 0.95);
    // Clamp the handle to half the horizontal span so short hops stay straight.
    final span = (e.to.dx - e.from.dx).abs();
    final dx = math.min(span / 2, curveHandle);
    final path = Path()
      ..moveTo(e.from.dx, e.from.dy)
      ..cubicTo(
        e.from.dx + dx,
        e.from.dy,
        e.to.dx - dx,
        e.to.dy,
        e.to.dx,
        e.to.dy,
      );
    if (e.dashed) {
      for (final metric in path.computeMetrics()) {
        var d = 0.0;
        while (d < metric.length) {
          canvas.drawPath(metric.extractPath(d, d + 6), paint);
          d += 11;
        }
      }
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Faded wires first so the focused row's wires sit on top.
    for (final e in edges) {
      if (e.faded) _draw(canvas, e);
    }
    for (final e in edges) {
      if (!e.faded) _draw(canvas, e);
    }
  }

  @override
  bool shouldRepaint(GraphEdgePainter old) => !listEquals(old.edges, edges);
}
