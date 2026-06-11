import 'package:flutter/material.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';

/// Shared effect-card metrics for every routing graph, so a card's footprint
/// and its drag-feedback ghost stay in lock-step without threading pixels
/// through widget constructors.
const double kRoutingCardWidth = 116;
const double kRoutingCardHeight = 40;

/// Gap between effect cards in a chain.
const double kRoutingCardGap = 16;

/// The square slot reserved for the add-effect button at a chain's end.
const double kRoutingAddSlot = 30;

/// Positions [child] in a graph [Stack] by its left edge and vertical centre,
/// so callers think in node centres rather than top-left corners.
Positioned positionedNode({
  required double left,
  required double centerY,
  required double width,
  required double height,
  required Widget child,
}) => Positioned(
  left: left,
  top: centerY - height / 2,
  width: width,
  height: height,
  child: child,
);

/// One output send leaving a row: the channels in [mask] are fed from
/// ([originX], [originY]) in [color], optionally [dashed].
///
/// A row can have several sends — the lane graph has one (its output), the
/// monitor graph has two (wet from the chain tail, dry from below the node) —
/// each with its own origin so they never overlap.
@immutable
class GraphSend {
  /// Creates a send description.
  const GraphSend({
    required this.originX,
    required this.originY,
    required this.mask,
    required this.color,
    this.dashed = false,
  });

  /// Where the send leaves the row.
  final double originX;
  final double originY;

  /// The output channels this send feeds, as a bitmask.
  final int mask;

  /// The send's wire colour.
  final Color color;

  /// Whether the send's wires are dashed.
  final bool dashed;
}

/// The x of each of [count] effect cards in a chain starting at [startX], laid
/// out left-to-right with [cardW]-wide cards separated by [gap].
List<double> cardColumnXs({
  required double startX,
  required int count,
  required double cardW,
  required double gap,
}) {
  final xs = <double>[];
  var x = startX;
  for (var k = 0; k < count; k++) {
    xs.add(x);
    x += cardW + gap;
  }
  return xs;
}

/// The wires that run along one row through its effect cards: node → first
/// card, then card → card. The send from the last card onward is built by
/// [fanEdges] (its origin is the chain's right edge).
List<GraphEdge> chainEdges({
  required double nodeRight,
  required double y,
  required List<double> cardXs,
  required double cardW,
  required Color color,
  required bool faded,
}) {
  final edges = <GraphEdge>[];
  if (cardXs.isEmpty) return edges;
  edges.add(
    GraphEdge(
      Offset(nodeRight, y),
      Offset(cardXs.first, y),
      color: color,
      faded: faded,
    ),
  );
  for (var k = 0; k < cardXs.length - 1; k++) {
    edges.add(
      GraphEdge(
        Offset(cardXs[k] + cardW, y),
        Offset(cardXs[k + 1], y),
        color: color,
        faded: faded,
      ),
    );
  }
  return edges;
}

/// The fan for each of [sends]: a hop along the send's own row to [railX] (a
/// shared rail just left of the output column), then one wire per set output
/// bit out to [outX]. Routing every send through its row's empty gutter means a
/// wire never passes behind another row's cards, however short the chain.
///
/// [outY] maps an output index and the output count to its vertical position.
List<GraphEdge> fanEdges({
  required List<GraphSend> sends,
  required double railX,
  required double outX,
  required int outCount,
  required double Function(int o, int count) outY,
  required bool faded,
}) {
  final edges = <GraphEdge>[];
  for (final s in sends) {
    final outs = [
      for (var o = 0; o < outCount; o++)
        if (s.mask & (1 << o) != 0) o,
    ];
    if (outs.isEmpty) continue;
    if (railX > s.originX + 0.5) {
      edges.add(
        GraphEdge(
          Offset(s.originX, s.originY),
          Offset(railX, s.originY),
          color: s.color,
          faded: faded,
          dashed: s.dashed,
        ),
      );
    }
    for (final o in outs) {
      edges.add(
        GraphEdge(
          Offset(railX, s.originY),
          Offset(outX, outY(o, outCount)),
          color: s.color,
          faded: faded,
          dashed: s.dashed,
        ),
      );
    }
  }
  return edges;
}
