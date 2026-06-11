import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

const _wet = Color(0xFF3B82F6);
const _dry = Color(0xFFF59E0B);

void main() {
  group('cardColumnXs', () {
    test('lays out cards left-to-right with gaps', () {
      final xs = cardColumnXs(startX: 10, count: 3, cardW: 100, gap: 20);
      expect(xs, [10, 130, 250]);
    });

    test('is empty for a chain of zero cards', () {
      expect(cardColumnXs(startX: 10, count: 0, cardW: 100, gap: 20), isEmpty);
    });
  });

  group('chainEdges', () {
    test('wires node -> first card -> ... -> last', () {
      final edges = chainEdges(
        nodeRight: 0,
        y: 50,
        cardXs: const [100, 230],
        cardW: 100,
        color: _wet,
        faded: false,
      );
      // node(0) -> card0(100), then card0 right(200) -> card1(230).
      expect(edges, hasLength(2));
      expect(edges[0].from, const Offset(0, 50));
      expect(edges[0].to, const Offset(100, 50));
      expect(edges[1].from, const Offset(200, 50));
      expect(edges[1].to, const Offset(230, 50));
    });

    test('has no edges when the chain is empty', () {
      expect(
        chainEdges(
          nodeRight: 0,
          y: 0,
          cardXs: const [],
          cardW: 100,
          color: _wet,
          faded: false,
        ),
        isEmpty,
      );
    });
  });

  group('fanEdges', () {
    double outY(int o, int count) => 10.0 + o * 30.0;

    test('fans each set output bit from the rail', () {
      final edges = fanEdges(
        sends: const [
          GraphSend(
            originX: 100,
            originY: 50,
            mask: 0x3,
            color: _wet,
          ),
        ],
        railX: 200,
        outX: 300,
        outCount: 2,
        outY: outY,
        faded: false,
      );
      // One rail hop (100->200 at y=50) + one wire per output (2).
      expect(edges, hasLength(3));
      expect(edges.first.from, const Offset(100, 50));
      expect(edges.first.to, const Offset(200, 50));
      expect(edges[1].to, Offset(300, outY(0, 2)));
      expect(edges[2].to, Offset(300, outY(1, 2)));
    });

    test('skips a send with an empty mask', () {
      final edges = fanEdges(
        sends: const [
          GraphSend(originX: 100, originY: 50, mask: 0, color: _wet),
        ],
        railX: 200,
        outX: 300,
        outCount: 2,
        outY: outY,
        faded: false,
      );
      expect(edges, isEmpty);
    });

    test('omits the rail hop when the origin already sits past the rail', () {
      final edges = fanEdges(
        sends: const [
          GraphSend(
            originX: 205,
            originY: 50,
            mask: 0x1,
            color: _wet,
          ),
        ],
        railX: 200,
        outX: 300,
        outCount: 1,
        outY: outY,
        faded: false,
      );
      // No rail hop (origin is right of the rail) — just the fan wire.
      expect(edges, hasLength(1));
      expect(edges.single.from, const Offset(200, 50));
    });

    // R1 mitigation: the dual-route (wet + dry) geometry must keep the dry send
    // on its own row offset, never collapsing onto the wet send's origin.
    test('two sends keep distinct origin Ys and the dry send is dashed', () {
      const wetY = 50.0;
      const dryY = 79.0; // node bottom + offset, clears the cards
      final edges = fanEdges(
        sends: const [
          GraphSend(
            originX: 150,
            originY: wetY,
            mask: 0x1,
            color: _wet,
          ),
          GraphSend(
            originX: 100,
            originY: dryY,
            mask: 0x1,
            color: _dry,
            dashed: true,
          ),
        ],
        railX: 200,
        outX: 300,
        outCount: 1,
        outY: outY,
        faded: false,
      );
      final wet = edges.where((e) => e.color == _wet).toList();
      final dry = edges.where((e) => e.color == _dry).toList();
      expect(wet, isNotEmpty);
      expect(dry, isNotEmpty);
      // Every wet origin sits at wetY; every dry origin at the distinct dryY.
      expect(wet.every((e) => e.from.dy == wetY), isTrue);
      expect(dry.every((e) => e.from.dy == dryY), isTrue);
      expect(wetY == dryY, isFalse);
      // The dry send is dashed; the wet send is not.
      expect(dry.every((e) => e.dashed), isTrue);
      expect(wet.every((e) => !e.dashed), isTrue);
    });
  });
}
