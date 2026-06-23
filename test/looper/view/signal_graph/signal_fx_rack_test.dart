import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_rack.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('SignalFxRack', () {
    Widget build({
      required List<TrackEffect> effects,
      void Function(int index, int param, double value)? onSetParam,
      void Function(int oldIndex, int newIndex)? onReorder,
      VoidCallback? onAddEffect,
      void Function(int index, TrackEffectType type)? onSetType,
    }) => Scaffold(
      body: SignalFxRack(
        keyPrefix: 'signalGraph_lane',
        effects: effects,
        onAddEffect: onAddEffect ?? () {},
        onRemoveEffect: (_) {},
        onSetType: onSetType ?? (_, _) {},
        onSetParam: onSetParam ?? (_, _, _) {},
        onReorder: onReorder ?? (_, _) {},
      ),
    );

    testWidgets('renders one knob per continuous param', (tester) async {
      await tester.pumpApp(
        build(effects: [TrackEffect(type: TrackEffectType.delay)]),
      );
      // Delay has three continuous params — all knobs, no mode switch.
      expect(find.byType(SignalKnob), findsNWidgets(3));
    });

    testWidgets('octaver mode is a named two-state switch, not a knob', (
      tester,
    ) async {
      await tester.pumpApp(
        build(effects: [TrackEffect(type: TrackEffectType.octaver)]),
      );
      // Shift, Tone, Mix stay knobs; Mode is the switch.
      expect(find.byType(SignalKnob), findsNWidgets(3));
      expect(find.text('Phase Vocoder'), findsOneWidget);
      expect(find.text('PSOLA'), findsOneWidget);
    });

    testWidgets('tapping the inactive mode option dispatches its value', (
      tester,
    ) async {
      final calls = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          // Default octaver mode is 0 (Phase Vocoder).
          effects: [TrackEffect(type: TrackEffectType.octaver)],
          onSetParam: (i, p, v) => calls.add((i, p, v)),
        ),
      );

      await tester.tap(find.text('PSOLA'));
      // Mode is the 4th param (index 3) of the only device (index 0).
      expect(calls, [(0, 3, 1.0)]);

      await tester.tap(find.text('Phase Vocoder'));
      expect(calls, [(0, 3, 1.0), (0, 3, 0.0)]);
    });

    testWidgets('no drag-handle button — the whole card is the grab area', (
      tester,
    ) async {
      await tester.pumpApp(
        build(effects: [TrackEffect(type: TrackEffectType.delay)]),
      );
      // The old grip handle is gone; the card itself is the drag target.
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_grip')),
        findsNothing,
      );
    });

    testWidgets('dragging a card onto a drop zone reorders the chain', (
      tester,
    ) async {
      final reorders = <(int, int)>[];
      await tester.pumpApp(
        build(
          effects: [
            TrackEffect(type: TrackEffectType.delay),
            TrackEffect(type: TrackEffectType.reverb),
          ],
          onReorder: (from, to) => reorders.add((from, to)),
        ),
      );

      // Grab the card at its centre (over a knob) and drag it sideways onto the
      // trailing drop zone — the reorder works even though the press lands on a
      // knob, because a vertical knob drag and a horizontal card drag differ.
      final card = find.byKey(const Key('signalGraph_lane_device_0'));
      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(25, 0)); // engage the horizontal drag
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('signalGraph_lane_drop_2'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Gap 2 (after Reverb) with from 0 normalises to post-removal index 1.
      expect(reorders, [(0, 1)]);
    });

    testWidgets('dropping a card back into its own gap does nothing', (
      tester,
    ) async {
      final reorders = <(int, int)>[];
      await tester.pumpApp(
        build(
          effects: [
            TrackEffect(type: TrackEffectType.delay),
            TrackEffect(type: TrackEffectType.reverb),
          ],
          onReorder: (from, to) => reorders.add((from, to)),
        ),
      );

      final card = find.byKey(const Key('signalGraph_lane_device_0'));
      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      // Gap 1 sits right after card 0 — dropping there is a no-op.
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('signalGraph_lane_drop_1'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reorders, isEmpty);
    });

    testWidgets('dragging a card left onto an earlier zone reorders back', (
      tester,
    ) async {
      final reorders = <(int, int)>[];
      await tester.pumpApp(
        build(
          effects: [
            TrackEffect(type: TrackEffectType.delay),
            TrackEffect(type: TrackEffectType.reverb),
            TrackEffect(type: TrackEffectType.drive),
          ],
          onReorder: (from, to) => reorders.add((from, to)),
        ),
      );

      // Drag the last card onto the leading zone — it lands at index 0.
      final card = find.byKey(const Key('signalGraph_lane_device_2'));
      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('signalGraph_lane_drop_0'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reorders, [(2, 0)]);
    });

    testWidgets('the add-device card fires onAddEffect', (tester) async {
      var added = 0;
      await tester.pumpApp(
        build(
          effects: [TrackEffect(type: TrackEffectType.delay)],
          onAddEffect: () => added++,
        ),
      );
      await tester.tap(find.byKey(const Key('signalGraph_lane_addDevice')));
      await tester.pumpAndSettle();
      expect(added, 1);
    });

    testWidgets('picking a type from the header dispatches onSetType', (
      tester,
    ) async {
      final calls = <(int, TrackEffectType)>[];
      await tester.pumpApp(
        build(
          effects: [TrackEffect(type: TrackEffectType.delay)],
          onSetType: (i, t) => calls.add((i, t)),
        ),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_type')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reverb').last);
      await tester.pumpAndSettle();
      expect(calls, [(0, TrackEffectType.reverb)]);
    });

    testWidgets('a vertical drag on a knob turns it, never reorders', (
      tester,
    ) async {
      final reorders = <(int, int)>[];
      final params = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          effects: [
            TrackEffect(type: TrackEffectType.delay),
            TrackEffect(type: TrackEffectType.reverb),
          ],
          onReorder: (from, to) => reorders.add((from, to)),
          onSetParam: (i, p, v) => params.add((i, p, v)),
        ),
      );

      // A vertical drag on the first knob must fall through to the knob.
      final knob = find.byKey(const Key('signalGraph_lane_device_0_param_0'));
      final gesture = await tester.startGesture(tester.getCenter(knob));
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveBy(const Offset(0, -30));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reorders, isEmpty);
      expect(params, isNotEmpty);
    });

    testWidgets('the type picker offers real effects, never "None"', (
      tester,
    ) async {
      await tester.pumpApp(
        build(effects: [TrackEffect(type: TrackEffectType.delay)]),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_type')),
      );
      await tester.pumpAndSettle();

      // The menu lists pickable effects but not the "do nothing" None type —
      // dropping a device is the × button's job.
      expect(find.text('Reverb'), findsOneWidget);
      expect(find.text('None'), findsNothing);
    });
  });
}
