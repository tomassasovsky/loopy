import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';

const _wet = Color(0xFF3B82F6);
const _dry = Color(0xFFF59E0B);

void main() {
  group('GraphEdge', () {
    test('is a value type: equal fields compare equal', () {
      const a = GraphEdge(
        Offset.zero,
        Offset(10, 10),
        color: _wet,
        dashed: true,
      );
      const b = GraphEdge(
        Offset.zero,
        Offset(10, 10),
        color: _wet,
        dashed: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differs when any field differs', () {
      const base = GraphEdge(
        Offset.zero,
        Offset(10, 10),
        color: _wet,
      );
      expect(
        base ==
            const GraphEdge(
              Offset.zero,
              Offset(10, 10),
              color: _dry,
            ),
        isFalse,
      );
      expect(
        base ==
            const GraphEdge(
              Offset.zero,
              Offset(10, 10),
              color: _wet,
              faded: true,
            ),
        isFalse,
      );
      expect(
        base ==
            const GraphEdge(
              Offset.zero,
              Offset(10, 10),
              color: _wet,
              dashed: true,
            ),
        isFalse,
      );
    });
  });
}
