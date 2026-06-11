import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

const _wet = Color(0xFF3B82F6);
const _dry = Color(0xFFF59E0B);

void main() {
  group('GraphEdgePainter', () {
    const edge = GraphEdge(Offset.zero, Offset(10, 10), color: _wet);

    test('does not repaint when the edge list is unchanged', () {
      final a = GraphEdgePainter(const [edge]);
      final b = GraphEdgePainter(const [edge]);
      expect(a.shouldRepaint(b), isFalse);
    });

    test('repaints when the edge list differs', () {
      final a = GraphEdgePainter(const [edge]);
      final b = GraphEdgePainter(
        const [GraphEdge(Offset.zero, Offset(20, 20), color: _wet)],
      );
      expect(a.shouldRepaint(b), isTrue);
    });

    test('paints faded, solid, and dashed edges without error', () {
      // Exercises _draw across all three branches: the faded-first ordering,
      // the solid stroke, and the dashed-segment loop (which needs a non-zero
      // span to iterate).
      final painter = GraphEdgePainter(const [
        GraphEdge(Offset.zero, Offset(100, 40), color: _wet, faded: true),
        GraphEdge(Offset.zero, Offset(100, 40), color: _wet),
        GraphEdge(Offset(0, 60), Offset(120, 60), color: _dry, dashed: true),
      ]);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      painter.paint(canvas, const Size(200, 100));

      // The recording produced a valid picture (paint() ran to completion).
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);
      expect(picture, isNotNull);
    });
  });
}
