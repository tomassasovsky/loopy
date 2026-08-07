import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/theme/theme.dart';

void main() {
  Future<void> pumpRows(WidgetTester tester, List<Widget> rows) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: Scaffold(body: ConsoleCard(children: rows)),
        ),
      );

  group('ConsoleRow semantics', () {
    // A row announces itself as one composed label, so its visible words are
    // hidden from semantics or they would be read twice. What must NOT be
    // hidden with them is a control the row is holding: a row with no tap of
    // its own is exactly the row whose only control is its `leading` or
    // `trailing`, and silencing that takes the control away entirely rather
    // than removing an echo.
    testWidgets('a readout-only row keeps its trailing control', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var toggled = false;
      await pumpRows(tester, [
        ConsoleRow(
          key: const Key('row'),
          title: 'Sync tempo',
          subtitle: 'Take the tempo from the host',
          showDivider: false,
          trailing: ConsoleSwitch(
            key: const Key('row_switch'),
            value: false,
            semanticLabel: 'Sync tempo',
            onChanged: (_) => toggled = true,
          ),
        ),
      ]);

      // The toggle is still a thing assistive tech can see and name. Asserted
      // through the finder rather than the flag bits, which Flutter has been
      // reshaping: this is the guarantee that matters, and it reads 0 the
      // moment the row silences the control along with its own text.
      expect(find.bySemanticsLabel('Sync tempo'), findsOneWidget);

      // ...and still operable.
      await tester.tap(find.byKey(const Key('row_switch')));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);

      handle.dispose();
    });

    testWidgets('a readout-only row does not announce its text twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRows(tester, const [
        ConsoleRow(
          key: Key('row'),
          title: 'Buffer',
          state: '128',
          showDisclosure: false,
        ),
      ]);

      expect(
        tester.getSemantics(find.byKey(const Key('row'))).label,
        'Buffer, 128',
      );

      handle.dispose();
    });
  });
}
