import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

void main() {
  group('GraphCardRef', () {
    test('holds its row and index', () {
      const ref = GraphCardRef(2, 5);
      expect(ref.rowId, 2);
      expect(ref.index, 5);
    });
  });
}
