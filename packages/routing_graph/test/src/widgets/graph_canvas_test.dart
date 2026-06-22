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

    testWidgets('a tap on empty canvas calls onTapBackground', (tester) async {
      var taps = 0;
      await tester.pumpApp(
        GraphCanvas(
          width: 400,
          height: 200,
          fitIdentity: const [1],
          onTapBackground: () => taps++,
          // The only child sits at the top-left, so the canvas centre is empty.
          children: const [
            Positioned(left: 10, top: 10, child: Text('node')),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(GraphCanvas));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('a tap on a child is absorbed, not a background tap', (
      tester,
    ) async {
      var background = 0;
      var child = 0;
      await tester.pumpApp(
        GraphCanvas(
          width: 400,
          height: 200,
          fitIdentity: const [1],
          onTapBackground: () => background++,
          children: [
            Positioned(
              left: 10,
              top: 10,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => child++,
                child: const Text('node'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('node'));
      await tester.pumpAndSettle();
      expect(child, 1);
      expect(background, 0);
    });

    testWidgets('exposes keyboard zoom/fit controls (WCAG 2.5.7)', (
      tester,
    ) async {
      await tester.pumpApp(
        const GraphCanvas(
          width: 400,
          height: 200,
          fitIdentity: [1],
          children: [Positioned(left: 10, top: 10, child: Text('node'))],
        ),
      );
      await tester.pumpAndSettle();

      for (final key in const [
        Key('graphCanvas_zoomIn'),
        Key('graphCanvas_zoomOut'),
        Key('graphCanvas_fit'),
      ]) {
        final control = find.byKey(key);
        expect(control, findsOneWidget);
        // The drag-free alternative must be a focusable, labelled target.
        expect(
          tester.widget(control),
          isA<FocusableTapTarget>().having(
            (t) => t.semanticLabel,
            'semanticLabel',
            isNotNull,
          ),
        );
        // Each control is operable without throwing (changes the transform).
        await tester.tap(control);
        await tester.pumpAndSettle();
      }
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
