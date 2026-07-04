import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_summary.dart';

import '../../../helpers/helpers.dart';

void main() {
  Widget summary({
    required List<TrackEffect> effects,
    VoidCallback? onEdit,
  }) => Scaffold(
    body: Center(
      child: SignalFxSummary(
        summaryKey: const Key('sum'),
        effects: effects,
        onEdit: onEdit ?? () {},
      ),
    ),
  );

  testWidgets('names each block and opens the editor on tap', (tester) async {
    var edited = false;
    await tester.pumpApp(
      summary(
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          BuiltInEffect(type: TrackEffectType.reverb),
        ],
        onEdit: () => edited = true,
      ),
    );

    expect(find.text('Drive'), findsOneWidget);
    expect(find.text('Reverb'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sum')));
    expect(edited, isTrue);
  });

  testWidgets('an empty chain shows a No FX affordance that still edits', (
    tester,
  ) async {
    var edited = false;
    await tester.pumpApp(
      summary(effects: const [], onEdit: () => edited = true),
    );

    expect(find.text('No FX'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sum')));
    expect(edited, isTrue);
  });

  testWidgets('exposes an edit-FX button for a11y', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpApp(summary(effects: const []));

    final node = tester.getSemantics(find.byKey(const Key('sum')));
    expect(node, isSemantics(isButton: true));
    handle.dispose();
  });
}
