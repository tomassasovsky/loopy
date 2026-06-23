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
      void Function(int index, int paramId, double value)? onSetPluginParam,
      void Function(int index)? onOpenPluginEditor,
      void Function(int oldIndex, int newIndex)? onReorder,
      VoidCallback? onAddEffect,
      void Function(int index, TrackEffectType type)? onSetType,
      void Function(int index)? onRemoveEffect,
    }) => Scaffold(
      body: SignalFxRack(
        keyPrefix: 'signalGraph_lane',
        effects: effects,
        onAddEffect: onAddEffect ?? () {},
        onRemoveEffect: onRemoveEffect ?? (_) {},
        onSetType: onSetType ?? (_, _) {},
        onSetParam: onSetParam ?? (_, _, _) {},
        onSetPluginParam: onSetPluginParam ?? (_, _, _) {},
        onOpenPluginEditor: onOpenPluginEditor ?? (_) {},
        onRelinkPlugin: (_) {},
        onReorder: onReorder ?? (_, _) {},
      ),
    );

    testWidgets('renders one knob per continuous param', (tester) async {
      await tester.pumpApp(
        build(effects: [BuiltInEffect(type: TrackEffectType.delay)]),
      );
      // Delay has three continuous params — all knobs, no mode switch.
      expect(find.byType(SignalKnob), findsNWidgets(3));
    });

    testWidgets('octaver mode is a named two-state switch, not a knob', (
      tester,
    ) async {
      await tester.pumpApp(
        build(effects: [BuiltInEffect(type: TrackEffectType.octaver)]),
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
          effects: [BuiltInEffect(type: TrackEffectType.octaver)],
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
        build(effects: [BuiltInEffect(type: TrackEffectType.delay)]),
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
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
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
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
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
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.drive),
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
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
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
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
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
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
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
        build(effects: [BuiltInEffect(type: TrackEffectType.delay)]),
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

  group('SignalFxRack plugin card', () {
    PluginParamInfo param(
      int id,
      String name, {
      int flags = 0x01, // automatable
      double min = 0,
      double max = 1,
      double def = 0.5,
    }) => PluginParamInfo(
      id: id,
      name: name,
      unit: '',
      min: min,
      max: max,
      def: def,
      stepCount: 0,
      flags: flags,
    );

    PluginEffect plugin({
      String id = 'com.acme.reverb',
      List<PluginParamInfo> params = const [],
      Map<int, double> values = const {},
      String name = '',
    }) => PluginEffect(
      ref: PluginRef(format: PluginFormat.clap, id: id),
      params: params,
      paramValues: values,
      name: name,
    );

    Widget build({
      required PluginEffect fx,
      void Function(int index, int paramId, double value)? onSetPluginParam,
      void Function(int index)? onOpenPluginEditor,
      void Function(int index)? onRelinkPlugin,
      void Function(int index)? onRemoveEffect,
    }) => Scaffold(
      body: SignalFxRack(
        keyPrefix: 'signalGraph_lane',
        effects: [fx],
        onAddEffect: () {},
        onRemoveEffect: onRemoveEffect ?? (_) {},
        onSetType: (_, _) {},
        onSetParam: (_, _, _) {},
        onSetPluginParam: onSetPluginParam ?? (_, _, _) {},
        onOpenPluginEditor: onOpenPluginEditor ?? (_) {},
        onRelinkPlugin: onRelinkPlugin ?? (_) {},
        onReorder: (_, _) {},
      ),
    );

    testWidgets('renders the plugin name and Open Editor button', (
      tester,
    ) async {
      await tester.pumpApp(build(fx: plugin(id: 'My Plugin')));
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_name')),
        findsOneWidget,
      );
      expect(find.text('My Plugin'), findsOneWidget);
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_openEditor')),
        findsOneWidget,
      );
    });

    testWidgets('the Open Editor button dispatches for the entry', (
      tester,
    ) async {
      final opened = <int>[];
      await tester.pumpApp(
        build(fx: plugin(), onOpenPluginEditor: opened.add),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_openEditor')),
      );
      expect(opened, [0]);
    });

    testWidgets('shows the resolved display name over the id', (tester) async {
      await tester.pumpApp(
        build(
          fx: plugin(id: 'ABCDEF0123', name: 'Spoton'),
        ),
      );
      expect(find.text('Spoton'), findsOneWidget);
      expect(find.text('ABCDEF0123'), findsNothing);
    });

    testWidgets('falls back to a generic name for an unresolved plugin', (
      tester,
    ) async {
      await tester.pumpApp(build(fx: plugin(id: '')));
      expect(find.text('Plugin'), findsOneWidget);
    });

    testWidgets('a 0-param plugin shows just chrome, no knobs', (tester) async {
      await tester.pumpApp(build(fx: plugin()));
      expect(find.byType(SignalKnob), findsNothing);
      // The empty-body placeholder (em dash) stands in for the knob row.
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('renders one knob per user-visible param', (tester) async {
      await tester.pumpApp(
        build(
          fx: plugin(
            params: [param(10, 'A'), param(20, 'B'), param(30, 'C')],
          ),
        ),
      );
      expect(find.byType(SignalKnob), findsNWidgets(3));
    });

    testWidgets('caps the in-app knobs at kPluginKnobs', (tester) async {
      await tester.pumpApp(
        build(
          fx: plugin(
            params: [for (var i = 0; i < 8; i++) param(i, 'P$i')],
          ),
        ),
      );
      expect(find.byType(SignalKnob), findsNWidgets(kPluginKnobs));
    });

    testWidgets('hidden and read-only params get no knob', (tester) async {
      await tester.pumpApp(
        build(
          fx: plugin(
            params: [
              param(10, 'Visible'),
              param(20, 'Hidden', flags: 0x01 | 0x08),
              param(30, 'ReadOnly', flags: 0x02),
            ],
          ),
        ),
      );
      // Only the automatable, non-hidden param earns a knob.
      expect(find.byType(SignalKnob), findsOneWidget);
    });

    testWidgets('turning a knob dispatches the plain value by param id', (
      tester,
    ) async {
      final calls = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          fx: plugin(params: [param(42, 'Gain', max: 10, def: 5)]),
          onSetPluginParam: (i, id, v) => calls.add((i, id, v)),
        ),
      );

      final knob = find.byKey(const Key('signalGraph_lane_device_0_param_0'));
      final gesture = await tester.startGesture(tester.getCenter(knob));
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveBy(const Offset(0, -30));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(calls, isNotEmpty);
      // Routed by the stable param id, on entry 0.
      expect(calls.last.$1, 0);
      expect(calls.last.$2, 42);
      // The dispatched value is plain (in [min=0, max=10]) — a normalized value
      // would never exceed 1, so a value above 1 proves the de-normalization.
      expect(calls.last.$3, greaterThan(1));
      expect(calls.last.$3, lessThanOrEqualTo(10));
    });

    testWidgets('a bypass param drives the header toggle', (tester) async {
      final calls = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          // A bypass control (automatable + bypass flag), currently off.
          fx: plugin(
            params: [param(99, 'Bypass', flags: 0x01 | 0x04, def: 0)],
          ),
          onSetPluginParam: (i, id, v) => calls.add((i, id, v)),
        ),
      );

      // The bypass param has its own header toggle, not a knob.
      expect(find.byType(SignalKnob), findsNothing);
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_bypass')),
      );
      await tester.pump();
      expect(calls, [(0, 99, 1.0)]);
    });

    testWidgets('an already-bypassed plugin toggles back on', (tester) async {
      final calls = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          // Bypass param present and currently engaged (value 1 >= 0.5).
          fx: plugin(
            params: [param(99, 'Bypass', flags: 0x01 | 0x04, def: 0)],
            values: {99: 1},
          ),
          onSetPluginParam: (i, id, v) => calls.add((i, id, v)),
        ),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_bypass')),
      );
      await tester.pump();
      // Tapping a bypassed plugin clears the bypass (0).
      expect(calls, [(0, 99, 0.0)]);
    });

    testWidgets('the bypass toggle is disabled without a bypass param', (
      tester,
    ) async {
      await tester.pumpApp(build(fx: plugin(params: [param(10, 'A')])));
      final toggle = tester.widget<IconButton>(
        find.byKey(const Key('signalGraph_lane_device_0_bypass')),
      );
      expect(toggle.onPressed, isNull);
    });

    testWidgets('the × button removes the plugin entry', (tester) async {
      final removed = <int>[];
      await tester.pumpApp(
        build(fx: plugin(), onRemoveEffect: removed.add),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_remove')),
      );
      expect(removed, [0]);
    });

    testWidgets('an unavailable plugin renders the D-MISS placeholder', (
      tester,
    ) async {
      await tester.pumpApp(
        build(fx: plugin(id: 'gone').copyWith(unavailable: true)),
      );
      // No controls — just the placeholder + relink + remove.
      expect(find.byType(SignalKnob), findsNothing);
      expect(find.text('Plugin unavailable'), findsOneWidget);
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_relink')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_openEditor')),
        findsNothing,
      );
    });

    testWidgets('the relink button dispatches for the entry', (tester) async {
      final relinked = <int>[];
      await tester.pumpApp(
        build(
          fx: plugin(id: 'gone').copyWith(unavailable: true),
          onRelinkPlugin: relinked.add,
        ),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_relink')),
      );
      expect(relinked, [0]);
    });
  });
}
