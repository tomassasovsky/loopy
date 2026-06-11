import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

/// A representative [RoutingGraphTheme] for widget tests. Distinct, opaque
/// colours so a test can assert which token a widget resolved.
const testRoutingGraphTheme = RoutingGraphTheme(
  background: Color(0xFF08080A),
  surface: Color(0xFF0D0D11),
  card: Color(0xFF16161B),
  cardHigh: Color(0xFF1C1C22),
  line: Color(0xFF272730),
  textPrimary: Color(0xFFF3F4F7),
  textSecondary: Color(0xFF989AA4),
  textTertiary: Color(0xFF5B5D67),
);

/// Pumps [widget] under a [MaterialApp] whose theme registers
/// [testRoutingGraphTheme], so package widgets that read `context.routingGraph`
/// resolve their neutral tokens under test.
extension PumpApp on WidgetTester {
  /// Pumps [widget] inside a themed [MaterialApp] scaffold.
  Future<void> pumpApp(Widget widget) {
    return pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testRoutingGraphTheme]),
        home: Scaffold(body: widget),
      ),
    );
  }
}
