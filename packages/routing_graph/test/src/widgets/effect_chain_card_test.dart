import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('EffectChainCard', () {
    Widget card({
      VoidCallback? onTap,
      VoidCallback? onDelete,
      bool selected = false,
      VoidCallback? onMoveLeft,
      VoidCallback? onMoveRight,
    }) {
      return EffectChainCard(
        keyPrefix: 'laneGraph',
        label: 'Reverb',
        accentColor: const Color(0xFF3B82F6),
        selected: selected,
        dragging: false,
        rowId: 0,
        index: 1,
        onTap: onTap ?? () {},
        onDelete: onDelete ?? () {},
        onDragStart: () {},
        onDragEnd: () {},
        onMoveLeft: onMoveLeft,
        onMoveRight: onMoveRight,
      );
    }

    testWidgets('renders its label and namespaced keys', (tester) async {
      await tester.pumpApp(SizedBox(width: 140, child: card()));
      expect(find.text('Reverb'), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fx_0_1')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxLabel_0_1')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxDelete_0_1')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxHandle_0_1')), findsOneWidget);
    });

    testWidgets('tapping the label calls onTap', (tester) async {
      var taps = 0;
      await tester.pumpApp(
        SizedBox(width: 140, child: card(onTap: () => taps++)),
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxLabel_0_1')));
      expect(taps, 1);
    });

    testWidgets('tapping delete calls onDelete', (tester) async {
      var deletes = 0;
      await tester.pumpApp(
        SizedBox(width: 140, child: card(onDelete: () => deletes++)),
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxDelete_0_1')));
      expect(deletes, 1);
    });

    testWidgets('hides move buttons when no reorder callbacks are given', (
      tester,
    ) async {
      await tester.pumpApp(SizedBox(width: 200, child: card()));
      expect(find.byKey(const Key('laneGraph_fxMoveLeft_0_1')), findsNothing);
      expect(find.byKey(const Key('laneGraph_fxMoveRight_0_1')), findsNothing);
    });

    testWidgets('move buttons provide a non-drag reorder (WCAG 2.5.7)', (
      tester,
    ) async {
      var left = 0;
      var right = 0;
      await tester.pumpApp(
        SizedBox(
          width: 220,
          child: card(onMoveLeft: () => left++, onMoveRight: () => right++),
        ),
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxMoveLeft_0_1')));
      await tester.tap(find.byKey(const Key('laneGraph_fxMoveRight_0_1')));
      expect(left, 1);
      expect(right, 1);
    });

    testWidgets('delete target meets the 24dp minimum (WCAG 2.5.8)', (
      tester,
    ) async {
      await tester.pumpApp(SizedBox(width: 200, child: card()));
      final size = tester.getSize(
        find
            .descendant(
              of: find.byKey(const Key('laneGraph_fxDelete_0_1')),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(size.width, greaterThanOrEqualTo(24));
      expect(size.height, greaterThanOrEqualTo(24));
    });
  });
}
