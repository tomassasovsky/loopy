import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:routing_graph/src/widgets/graph_edge.dart';

/// Paints a list of [GraphEdge]s as wires.
///
/// Simple hops are straight; connectors that change height use a horizontal-
/// tangent cubic. Wires with a [GraphEdge.knee] are one stroke — a straight run
/// along the row that eases into a fan curve to the port. Faded wires are
/// painted first so the focused row's wires sit on top; a dashed edge dashes
/// its straight lead but strokes its curved tail solid, so the bend stays
/// legible instead of falling into the dash gaps.
class GraphEdgePainter extends CustomPainter {
  /// Creates a painter for [edges].
  GraphEdgePainter(this.edges);

  /// The wires to paint, in build order (faded ones are still drawn first).
  final List<GraphEdge> edges;

  /// Fraction of a curve's horizontal span used for each control handle.
  ///
  /// `0.5` puts both handles at the horizontal midpoint — the canonical smooth
  /// S: a clearly visible bow that still leaves each end on a horizontal
  /// tangent, so a fan curve joins its straight run without a kink. Larger
  /// flattens the bow; smaller tightens it (toward a hard corner).
  static const double curveBow = 0.5;

  /// Radius of the soft turn where a wire changes direction at a right angle
  /// (e.g. the dry send dropping below a node, then running across). Clamped to
  /// the shorter of the two legs in [_roundedCorner] so it never overruns.
  static const double cornerRadius = 8;

  /// Builds the stroke path for [e] together with the arc-length at which its
  /// curved tail begins. A dashed wire dashes its straight lead but strokes the
  /// curve solid — a dashed curve falls in the gaps and reads as nearly
  /// straight, so the bend would otherwise vanish. `infinity` means the wire is
  /// all straight (dash the lot); `0` means it curves from the start.
  (Path, double) _path(GraphEdge e) {
    final path = Path()..moveTo(e.from.dx, e.from.dy);
    if (e.knee != null) {
      return _kneePath(path, e);
    }
    final spanX = (e.to.dx - e.from.dx).abs();
    final spanY = (e.to.dy - e.from.dy).abs();
    if (spanX < 0.5 && spanY < 0.5) {
      return (path, double.infinity);
    }
    if (spanX < 0.5 || spanY < 0.5) {
      path.lineTo(e.to.dx, e.to.dy);
      return (path, double.infinity);
    }
    final handle = spanX * curveBow;
    path.cubicTo(
      e.from.dx + handle,
      e.from.dy,
      e.to.dx - handle,
      e.to.dy,
      e.to.dx,
      e.to.dy,
    );
    return (path, 0);
  }

  /// A wire that runs straight into the knee, then either fans to a port or
  /// turns to run across.
  ///
  /// A vertical run into the knee is a right-angle turn (the dry send dropping
  /// below the node) — round it. A horizontal run is the approach to a fan
  /// curve: run straight to the knee, then bow into the port with a symmetric
  /// cubic ([curveBow]). Because the curve leaves the knee on a horizontal
  /// tangent — matching the straight run — the two meet without a kink while
  /// the bow stays clearly visible. Returns the straight-run length as the
  /// solid-from mark so a dashed wire keeps its bow solid.
  (Path, double) _kneePath(Path path, GraphEdge e) {
    final knee = e.knee!;
    if ((e.from.dx - knee.dx).abs() < 0.5) {
      return _roundedCorner(path, e);
    }
    final dir = e.to.dx >= knee.dx ? 1.0 : -1.0;
    final spanX = (e.to.dx - knee.dx).abs();
    final spanY = (e.to.dy - knee.dy).abs();

    // Straight run to the knee.
    path.lineTo(knee.dx, knee.dy);
    final straightLen = (knee - e.from).distance;

    // Port sits on the row — no fan, just run straight through.
    if (spanY < 0.5) {
      path.lineTo(e.to.dx, e.to.dy);
      return (path, double.infinity);
    }

    final handle = spanX * curveBow;
    path.cubicTo(
      knee.dx + dir * handle,
      knee.dy,
      e.to.dx - dir * handle,
      e.to.dy,
      e.to.dx,
      e.to.dy,
    );
    return (path, straightLen);
  }

  /// A wire that drops (or rises) to the knee, then turns to run across. Round
  /// the right angle with a short arc — straight in, [cornerRadius] (clamped to
  /// the shorter leg) of quadratic through the knee, then straight out — so the
  /// turn reads as a soft bend rather than a hard 90°. Returns the drop's
  /// length as the solid-from mark so a dashed wire keeps its turn solid.
  (Path, double) _roundedCorner(Path path, GraphEdge e) {
    final knee = e.knee!;
    final vDir = knee.dy >= e.from.dy ? 1.0 : -1.0;
    final hDir = e.to.dx >= knee.dx ? 1.0 : -1.0;
    final r = math.min(
      cornerRadius,
      math.min((knee.dy - e.from.dy).abs(), (e.to.dx - knee.dx).abs()),
    );
    final leadEnd = Offset(knee.dx, knee.dy - vDir * r);
    path
      ..lineTo(leadEnd.dx, leadEnd.dy)
      ..quadraticBezierTo(knee.dx, knee.dy, knee.dx + hDir * r, knee.dy)
      ..lineTo(e.to.dx, e.to.dy);
    return (path, (leadEnd - e.from).distance);
  }

  void _draw(Canvas canvas, GraphEdge e) {
    final (path, solidFrom) = _path(e);
    // A soft neon underglow beneath each solid wire, so the routing reads as
    // lit signal rather than hairlines. Skipped for faded/dashed wires (the
    // focused-only monitor send) to keep the canvas calm.
    if (!e.faded && !e.dashed) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..color = e.color.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = e.faded ? 1.4 : 2.4
      ..color = e.color.withValues(alpha: e.faded ? 0.22 : 0.95);
    if (!e.dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    // Dash the straight lead, then stroke the curved tail solid so the bend
    // stays legible instead of disappearing into the dash gaps.
    for (final metric in path.computeMetrics()) {
      final solidStart = solidFrom.clamp(0.0, metric.length);
      var d = 0.0;
      while (d < solidStart) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 6, solidStart)),
          paint,
        );
        d += 11;
      }
      if (solidStart < metric.length) {
        canvas.drawPath(metric.extractPath(solidStart, metric.length), paint);
      }
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
