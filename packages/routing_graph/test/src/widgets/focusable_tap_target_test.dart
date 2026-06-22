import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../helpers/pump_app.dart';

void main() {
  group('FocusableTapTarget', () {
    testWidgets('activates on tap', (tester) async {
      var taps = 0;
      await tester.pumpApp(
        FocusableTapTarget(
          onTap: () => taps++,
          semanticLabel: 'Port In 1',
          child: const SizedBox(width: 40, height: 24),
        ),
      );
      await tester.tap(find.byType(FocusableTapTarget));
      expect(taps, 1);
    });

    testWidgets('is keyboard-focusable and activates on Enter and Space', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpApp(
        FocusableTapTarget(
          autofocus: true,
          onTap: () => taps++,
          semanticLabel: 'Port In 1',
          child: const SizedBox(width: 40, height: 24),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 1, reason: 'Enter should activate');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(taps, 2, reason: 'Space should activate');
    });

    testWidgets('exposes button role, label and selected state', (
      tester,
    ) async {
      await tester.pumpApp(
        FocusableTapTarget(
          onTap: () {},
          semanticLabel: 'Port In 1',
          selected: true,
          child: const SizedBox(width: 40, height: 24),
        ),
      );
      expect(
        tester.getSemantics(find.byType(FocusableTapTarget).first),
        isSemantics(
          label: 'Port In 1',
          isButton: true,
          isSelected: true,
          isEnabled: true,
        ),
      );
    });

    testWidgets('exposes a tap semantics action under its label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpApp(
        FocusableTapTarget(
          onTap: () {},
          semanticLabel: 'Port In 1',
          child: const SizedBox(width: 40, height: 24),
        ),
      );
      // The label override must NOT strip the tap action — VoiceOver/TalkBack
      // activation depends on it (the regression a plain excludeSemantics on
      // the whole subtree would reintroduce).
      expect(
        tester.getSemantics(find.byType(FocusableTapTarget)),
        isSemantics(label: 'Port In 1', isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('is inert and not focusable when onTap is null', (
      tester,
    ) async {
      await tester.pumpApp(
        const FocusableTapTarget(
          onTap: null,
          semanticLabel: 'Port In 1',
          child: SizedBox(width: 40, height: 24),
        ),
      );
      final detector = tester.widget<FocusableActionDetector>(
        find.byType(FocusableActionDetector),
      );
      expect(detector.enabled, isFalse);
    });
  });
}
