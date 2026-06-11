import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('EffectChainCard', () {
    Widget card({
      VoidCallback? onTap,
      VoidCallback? onDelete,
      bool selected = false,
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
  });
}
