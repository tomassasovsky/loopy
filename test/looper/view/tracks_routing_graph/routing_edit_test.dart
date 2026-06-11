import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_edit.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';

void main() {
  group('RoutingEdit.forTarget', () {
    const track = Track(); // inputMask 0x1, outputMask 0x3
    const in0 = RoutingNode(
      kind: RoutingNodeKind.input,
      index: 0,
      label: 'In 1',
    );
    const in1 = RoutingNode(
      kind: RoutingNodeKind.input,
      index: 1,
      label: 'In 2',
    );
    const out1 = RoutingNode(
      kind: RoutingNodeKind.output,
      index: 1,
      label: 'Out 2',
    );

    test('adds an unset input bit', () {
      expect(
        RoutingEdit.forTarget(track, in1),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x3),
      );
    });

    test('clears an already-set input bit', () {
      expect(
        RoutingEdit.forTarget(track, in0),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x0),
      );
    });

    test('toggles an output bit', () {
      expect(
        RoutingEdit.forTarget(track, out1),
        const RoutingEdit(isInput: false, channel: 0, mask: 0x1),
      );
    });

    test('an excluded input resolves to nothing', () {
      const excluded = RoutingNode(
        kind: RoutingNodeKind.input,
        index: 1,
        label: 'In 2',
        excluded: true,
      );
      expect(RoutingEdit.forTarget(track, excluded), isNull);
    });

    test('a track target resolves to nothing', () {
      const trackNode = RoutingNode(
        kind: RoutingNodeKind.track,
        index: 0,
        label: 'Track 1',
      );
      expect(RoutingEdit.forTarget(track, trackNode), isNull);
    });
  });
}
