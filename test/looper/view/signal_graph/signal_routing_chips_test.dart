import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/view/signal_graph/signal_routing_chips.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('SignalRoutingChips', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<int> routes,
      required ValueChanged<int> onToggle,
    }) => tester.pumpApp(
      Scaffold(
        body: SignalRoutingChips(
          routes: routes,
          outputCount: 3,
          onToggle: onToggle,
        ),
      ),
    );

    testWidgets('renders a lit chip per routed output + the add button', (
      tester,
    ) async {
      await pump(tester, routes: const [0, 2], onToggle: (_) {});
      expect(find.byKey(const Key('signalRoutes_chip_0')), findsOneWidget);
      expect(find.byKey(const Key('signalRoutes_chip_2')), findsOneWidget);
      expect(find.byKey(const Key('signalRoutes_chip_1')), findsNothing);
      expect(find.byKey(const Key('signalRoutes_add')), findsOneWidget);
    });

    testWidgets('shows "not routed" when there are no routes', (tester) async {
      await pump(tester, routes: const [], onToggle: (_) {});
      expect(find.text('not routed'), findsOneWidget);
    });

    testWidgets('tapping a lit chip toggles that output off', (tester) async {
      int? toggled;
      await pump(tester, routes: const [1], onToggle: (o) => toggled = o);
      await tester.tap(find.byKey(const Key('signalRoutes_chip_1')));
      expect(toggled, 1);
    });

    testWidgets('the add picker lists every output and toggles one', (
      tester,
    ) async {
      int? toggled;
      await pump(tester, routes: const [0], onToggle: (o) => toggled = o);
      await tester.tap(find.byKey(const Key('signalRoutes_add')));
      await tester.pumpAndSettle();
      // The menu lists all outputs (0 checked, 1 and 2 unchecked).
      expect(find.byKey(const Key('signalRoutes_menu_2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('signalRoutes_menu_2')));
      await tester.pumpAndSettle();
      expect(toggled, 2);
    });
  });
}
