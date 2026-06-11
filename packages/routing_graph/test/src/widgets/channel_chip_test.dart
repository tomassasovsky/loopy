import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('ChannelChip', () {
    testWidgets('renders its label', (tester) async {
      await tester.pumpApp(
        const SizedBox(
          width: 80,
          height: 32,
          child: ChannelChip(
            label: 'In 1',
            color: Color(0xFF3B82F6),
            strong: false,
            wired: true,
            excluded: false,
            onTap: null,
          ),
        ),
      );
      expect(find.text('In 1'), findsOneWidget);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      var taps = 0;
      await tester.pumpApp(
        SizedBox(
          width: 80,
          height: 32,
          child: ChannelChip(
            label: 'Out 2',
            color: const Color(0xFF3B82F6),
            strong: true,
            wired: true,
            excluded: false,
            onTap: () => taps++,
          ),
        ),
      );
      await tester.tap(find.text('Out 2'));
      expect(taps, 1);
    });

    testWidgets('strikes through an excluded port', (tester) async {
      await tester.pumpApp(
        const SizedBox(
          width: 80,
          height: 32,
          child: ChannelChip(
            label: 'In 3',
            color: Color(0xFF3B82F6),
            strong: false,
            wired: false,
            excluded: true,
            onTap: null,
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('In 3'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });
  });
}
