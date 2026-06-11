import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/view/tracks_routing_graph/graph_node.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';
import 'package:loopy/theme/theme.dart';

void main() {
  group('RoutingGraphNode', () {
    const target = RoutingNode(
      kind: RoutingNodeKind.input,
      index: 0,
      label: 'In 1',
    );

    Future<void> pumpNode(
      WidgetTester tester, {
      required bool hovered,
      required bool isTarget,
      required bool? connected,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.bigPicture,
          home: Scaffold(
            body: RoutingGraphNode(
              node: target,
              interactive: true,
              armed: false,
              isTarget: isTarget,
              connected: connected,
              hovered: hovered,
              onTap: () {},
              onHover: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('a hovered unconnected target hints "+" to connect', (
      tester,
    ) async {
      await pumpNode(tester, hovered: true, isTarget: true, connected: false);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('a hovered connected target hints "✕" to disconnect', (
      tester,
    ) async {
      await pumpNode(tester, hovered: true, isTarget: true, connected: true);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.add), findsNothing);
    });

    testWidgets('shows no hint icon when not hovered', (tester) async {
      await pumpNode(tester, hovered: false, isTarget: true, connected: false);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });
}
