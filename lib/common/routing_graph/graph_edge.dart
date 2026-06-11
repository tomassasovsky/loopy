import 'package:flutter/material.dart';

/// One wire in a routing graph, from [from] to [to].
///
/// A value type (with `==`/`hashCode`) so a [CustomPainter] can compare edge
/// lists and skip repaints when nothing moved.
@immutable
class GraphEdge {
  /// Creates a wire between two points.
  const GraphEdge(
    this.from,
    this.to, {
    required this.color,
    this.faded = false,
    this.dashed = false,
  });

  /// The wire's endpoints, in canvas coordinates.
  final Offset from;
  final Offset to;

  /// The wire's stroke colour (before the faded/normal alpha is applied).
  final Color color;

  /// A wire on a row other than the focused one — drawn thin and dim so the
  /// focused row's wires stand out.
  final bool faded;

  /// Drawn dashed instead of solid (used for the monitor's dry send).
  final bool dashed;

  @override
  bool operator ==(Object other) =>
      other is GraphEdge &&
      other.from == from &&
      other.to == to &&
      other.color == color &&
      other.faded == faded &&
      other.dashed == dashed;

  @override
  int get hashCode => Object.hash(from, to, color, faded, dashed);
}
