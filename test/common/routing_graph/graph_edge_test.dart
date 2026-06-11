import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/common/routing_graph/graph_colors.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';

void main() {
  group('GraphEdge', () {
    test('is a value type: equal fields compare equal', () {
      const a = GraphEdge(
        Offset(0, 0),
        Offset(10, 10),
        color: kWetRouteColor,
        dashed: true,
      );
      const b = GraphEdge(
        Offset(0, 0),
        Offset(10, 10),
        color: kWetRouteColor,
        dashed: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differs when any field differs', () {
      const base = GraphEdge(
        Offset(0, 0),
        Offset(10, 10),
        color: kWetRouteColor,
      );
      expect(
        base ==
            const GraphEdge(
              Offset(0, 0),
              Offset(10, 10),
              color: kDryRouteColor,
            ),
        isFalse,
      );
      expect(
        base ==
            const GraphEdge(
              Offset(0, 0),
              Offset(10, 10),
              color: kWetRouteColor,
              faded: true,
            ),
        isFalse,
      );
      expect(
        base ==
            const GraphEdge(
              Offset(0, 0),
              Offset(10, 10),
              color: kWetRouteColor,
              dashed: true,
            ),
        isFalse,
      );
    });
  });
}
