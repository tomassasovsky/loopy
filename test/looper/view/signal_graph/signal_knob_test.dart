import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';

import '../../../helpers/helpers.dart';

/// Fires a screen-reader "increase" on the knob — the deterministic public
/// path into [SignalKnob]'s nudge (and so its snap), without simulating a drag.
void _increase(WidgetTester tester) {
  final node = tester.getSemantics(find.byType(SignalKnob));
  // The canonical way to drive a semantics action from a widget test; there is
  // no non-deprecated equivalent yet.
  // ignore: deprecated_member_use
  tester.binding.pipelineOwner.semanticsOwner!.performAction(
    node.id,
    SemanticsAction.increase,
  );
}

void main() {
  group('SignalKnob', () {
    Widget build({
      required double value,
      required ValueChanged<double> onChanged,
      double max = 1,
      double? resetValue,
      List<double> snapTargets = const [],
    }) => Scaffold(
      body: Center(
        child: SignalKnob(
          knobKey: const Key('knob'),
          value: value,
          max: max,
          resetValue: resetValue,
          snapTargets: snapTargets,
          onChanged: onChanged,
          label: 'VOL',
          color: const Color(0xFF4DA6FF),
        ),
      ),
    );

    testWidgets('reads unity as 0.0 dB and +6 dB ceiling to one decimal', (
      tester,
    ) async {
      await tester.pumpApp(
        build(value: 1, max: 2, onChanged: (_) {}),
      );
      expect(find.text('0.0 dB'), findsOneWidget);

      await tester.pumpApp(
        build(value: 2, max: 2, onChanged: (_) {}),
      );
      expect(find.text('+6.0 dB'), findsOneWidget);
    });

    testWidgets('arrow keys nudge the focused knob', (tester) async {
      double? changed;
      await tester.pumpApp(build(value: 0.5, onChanged: (v) => changed = v));

      // Focus the knob (a tap requests focus), then drive it from the keyboard.
      await tester.tap(find.byKey(const Key('knob')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(changed, greaterThan(0.5));

      changed = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(changed, lessThan(0.5));
    });

    testWidgets('double-tap restores the reset value', (tester) async {
      double? changed;
      await tester.pumpApp(
        build(
          value: 1.6,
          max: 2,
          resetValue: 1,
          onChanged: (v) => changed = v,
        ),
      );

      final knob = find.byKey(const Key('knob'));
      await tester.tap(knob);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(knob);
      // Drain the double-tap recognizer's countdown timer.
      await tester.pump(const Duration(milliseconds: 300));

      expect(changed, 1);
    });

    testWidgets('without a reset value, double-tap is inert', (tester) async {
      double? changed;
      await tester.pumpApp(
        build(value: 0.5, onChanged: (v) => changed = v),
      );

      final knob = find.byKey(const Key('knob'));
      await tester.tap(knob);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(knob);
      // Drain the double-tap recognizer's countdown timer.
      await tester.pump(const Duration(milliseconds: 300));

      expect(changed, isNull);
    });

    testWidgets('a nudge that lands near a detent snaps to it', (tester) async {
      double? changed;
      // Step is 0.05 of full travel; from 0.46 a single increase lands at
      // 0.51, within tolerance of the 0.5 detent — so it catches at exactly
      // 0.5 rather than 0.51.
      await tester.pumpApp(
        build(
          value: 0.46,
          snapTargets: const [0.5],
          onChanged: (v) => changed = v,
        ),
      );

      _increase(tester);
      await tester.pump();

      expect(changed, 0.5);
    });

    testWidgets('a nudge clear of every detent is left untouched', (
      tester,
    ) async {
      double? changed;
      await tester.pumpApp(
        build(
          value: 0.2,
          snapTargets: const [0.5],
          onChanged: (v) => changed = v,
        ),
      );

      _increase(tester);
      await tester.pump();

      expect(changed, closeTo(0.25, 1e-9));
    });

    testWidgets('a drag leaves a detent freely; the catch lands on release', (
      tester,
    ) async {
      // A stateful host so the knob's value tracks the drag, like the app.
      var value = 0.5;
      await tester.pumpApp(
        StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: SignalKnob(
                knobKey: const Key('knob'),
                value: value,
                snapTargets: const [0.5],
                onChanged: (v) => setState(() => value = v),
                label: 'X',
                color: const Color(0xFF4DA6FF),
              ),
            ),
          ),
        ),
      );

      final knob = tester.getCenter(find.byKey(const Key('knob')));
      final gesture = await tester.startGesture(knob);
      await tester.pump();
      // Drag up and off the 0.5 detent: while dragging it must move freely.
      // Two moves: the first clears the gesture's touch-slop, the second turns.
      await gesture.moveBy(const Offset(0, -30));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(value, greaterThan(0.5), reason: 'detent must not trap the drag');

      // Release while clear of the detent — the value is left where it is.
      await gesture.up();
      await tester.pump();
      expect(value, greaterThan(0.5));
    });
  });
}
