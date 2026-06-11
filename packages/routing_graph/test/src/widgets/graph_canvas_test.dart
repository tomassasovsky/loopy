import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('GraphCanvas', () {
    testWidgets('renders its positioned children', (tester) async {
      await tester.pumpApp(
        const GraphCanvas(
          width: 400,
          height: 200,
          fitIdentity: [1, 2],
          children: [
            Positioned(
              left: 10,
              top: 10,
              child: Text('node'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('node'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('re-fits when fitIdentity changes', (tester) async {
      Widget canvas(List<Object?> identity) => GraphCanvas(
        width: 400,
        height: 200,
        fitIdentity: identity,
        children: const [
          Positioned(left: 10, top: 10, child: Text('node')),
        ],
      );

      await tester.pumpApp(canvas(const [1]));
      await tester.pumpAndSettle();

      // A structurally different identity takes the re-fit branch (rather than
      // the listEquals no-op guard) and keeps rendering.
      await tester.pumpApp(canvas(const [1, 2]));
      await tester.pumpAndSettle();
      expect(find.text('node'), findsOneWidget);
    });
  });
}
