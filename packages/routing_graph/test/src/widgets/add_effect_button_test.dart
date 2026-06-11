import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('AddEffectButton', () {
    const key = Key('laneGraph_addFx_0');

    testWidgets('calls onAdd when tapped and not full', (tester) async {
      var adds = 0;
      await tester.pumpApp(
        AddEffectButton(
          buttonKey: key,
          accentColor: const Color(0xFF3B82F6),
          full: false,
          onAdd: () => adds++,
          tooltip: 'Add effect',
        ),
      );
      await tester.tap(find.byKey(key));
      expect(adds, 1);
    });

    testWidgets('is disabled when the chain is full', (tester) async {
      var adds = 0;
      await tester.pumpApp(
        AddEffectButton(
          buttonKey: key,
          accentColor: const Color(0xFF3B82F6),
          full: true,
          onAdd: () => adds++,
          tooltip: 'Add effect',
        ),
      );
      final button = tester.widget<IconButton>(find.byKey(key));
      expect(button.onPressed, isNull);
      await tester.tap(find.byKey(key));
      expect(adds, 0);
    });
  });
}
