import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('buildEffectDropZones', () {
    test(
      'builds one zone per gap around the cards (before each + after last)',
      () {
        final zones = buildEffectDropZones(
          keyPrefix: 'laneGraph',
          rowId: 0,
          cardXs: const [100, 230],
          emptyStartX: 0,
          rowCenterY: 50,
          accentColor: const Color(0xFF3B82F6),
          onMove: (_, _) {},
        );
        // Two cards -> a zone before each + one after the last = 3.
        expect(zones, hasLength(3));
      },
    );

    test('builds a single zone at emptyStartX for an empty chain', () {
      final zones = buildEffectDropZones(
        keyPrefix: 'laneGraph',
        rowId: 1,
        cardXs: const [],
        emptyStartX: 42,
        rowCenterY: 50,
        accentColor: const Color(0xFF3B82F6),
        onMove: (_, _) {},
      );
      expect(zones, hasLength(1));
      expect((zones.single as Positioned).left, 42);
    });
  });

  group('EffectDropZone', () {
    testWidgets('accepts a same-row card and reports its index', (
      tester,
    ) async {
      var accepted = -1;
      await tester.pumpApp(
        EffectDropZone(
          dropKey: const Key('laneGraph_drop_0_0'),
          rowId: 0,
          accentColor: const Color(0xFF3B82F6),
          onAccept: (from) => accepted = from,
        ),
      );
      final target = tester.widget<DragTarget<GraphCardRef>>(
        find.byType(DragTarget<GraphCardRef>),
      );
      // Same row is accepted; a different row is rejected.
      expect(
        target.onWillAcceptWithDetails!(
          DragTargetDetails(
            data: const GraphCardRef(0, 3),
            offset: Offset.zero,
          ),
        ),
        isTrue,
      );
      expect(
        target.onWillAcceptWithDetails!(
          DragTargetDetails(
            data: const GraphCardRef(1, 3),
            offset: Offset.zero,
          ),
        ),
        isFalse,
      );
      target.onAcceptWithDetails!(
        DragTargetDetails(
          data: const GraphCardRef(0, 3),
          offset: Offset.zero,
        ),
      );
      expect(accepted, 3);
    });
  });
}
