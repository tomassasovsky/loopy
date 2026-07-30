import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_rack.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';
import 'package:loopy/theme/surface_theme.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('SignalFxRack', () {
    Widget build({
      required List<TrackEffect> effects,
      void Function(int index, int param, double value)? onSetParam,
      void Function(int index, int paramId, double value)? onSetPluginParam,
      void Function(int index)? onOpenPluginEditor,
      void Function(int oldIndex, int newIndex)? onReorder,
      ValueChanged<TrackEffectType>? onAddEffect,
      void Function(int index, TrackEffectType type)? onSetType,
      void Function(int index)? onRemoveEffect,
      void Function(int index, {required bool enabled})? onSetEffectEnabled,
    }) => Scaffold(
      body: SignalFxRack(
        keyPrefix: 'signalGraph_lane',
        effects: effects,
        onAddEffect: onAddEffect ?? (_) {},
        onAddPlugin: () {},
        onRemoveEffect: onRemoveEffect ?? (_) {},
        onSetType: onSetType ?? (_, _) {},
        onSetParam: onSetParam ?? (_, _, _) {},
        onSetPluginParam: onSetPluginParam ?? (_, _, _) {},
        onOpenPluginEditor: onOpenPluginEditor ?? (_) {},
        onRelinkPlugin: (_) {},
        onReorder: onReorder ?? (_, _) {},
        onSetEffectEnabled: onSetEffectEnabled ?? (_, {required enabled}) {},
      ),
    );

    testWidgets('the power control turns a built-in device off and on', (
      tester,
    ) async {
      final calls = <(int, bool)>[];
      await tester.pumpApp(
        build(
          effects: [
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb, enabled: false),
          ],
          onSetEffectEnabled: (i, {required enabled}) =>
              calls.add((i, enabled)),
        ),
      );

      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_power')),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_1_power')),
      );
      await tester.pump();

      expect(calls, [(0, false), (1, true)]);
    });

    testWidgets('a powered-off device dims its body, not its header', (
      tester,
    ) async {
      await tester.pumpApp(
        build(
          effects: [
            BuiltInEffect(type: TrackEffectType.delay, enabled: false),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // R26: the dim comes from the SurfaceTheme token...
      final dim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(const Key('signalGraph_lane_device_0')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(dim.opacity, SurfaceTheme.dark.disabledOpacity);
      // ...and the header stays outside it, so the card is still workable.
      expect(
        find.descendant(
          of: find.byType(AnimatedOpacity),
          matching: find.byKey(const Key('signalGraph_lane_device_0_power')),
        ),
        findsNothing,
      );
    });

    testWidgets('an engaged device is not dimmed', (tester) async {
      await tester.pumpApp(
        build(effects: [BuiltInEffect(type: TrackEffectType.delay)]),
      );
      await tester.pumpAndSettle();

      final dim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(const Key('signalGraph_lane_device_0')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(dim.opacity, 1.0);
    });

    testWidgets('the power control announces its state', (tester) async {
      await tester.pumpApp(
        build(effects: [BuiltInEffect(type: TrackEffectType.delay)]),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const Key('signalGraph_lane_device_0_power')),
            )
            .label,
        contains('Effect on'),
      );
    });

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

    testWidgets('the device browser adds the picked type as ONE action', (
      tester,
    ) async {
      final added = <TrackEffectType>[];
      final retypes = <(int, TrackEffectType)>[];
      await tester.pumpApp(
        build(
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
          onAddEffect: added.add,
          onSetType: (i, t) => retypes.add((i, t)),
        ),
      );

      // The "+" now opens an Ableton-style device browser; pick a type.
      await tester.tap(find.byKey(const Key('signalGraph_addEffect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reverb').last);
      await tester.pumpAndSettle();

      // The pick travels as one intent — the rack never appends a default and
      // then retypes an index it had to guess, which cannot compose on a
      // backing store that applies the append a frame later.
      expect(added, [TrackEffectType.reverb]);
      expect(retypes, isEmpty);
    });

    testWidgets('the add-device "Add plugin…" button fires onAddPlugin', (
      tester,
    ) async {
      var addedPlugin = 0;
      await tester.pumpApp(
        Scaffold(
          body: SignalFxRack(
            keyPrefix: 'signalGraph_lane',
            effects: [BuiltInEffect(type: TrackEffectType.delay)],
            onAddEffect: (_) {},
            onAddPlugin: () => addedPlugin++,
            onRemoveEffect: (_) {},
            onSetType: (_, _) {},
            onSetParam: (_, _, _) {},
            onSetPluginParam: (_, _, _) {},
            onOpenPluginEditor: (_) {},
            onRelinkPlugin: (_) {},
            onReorder: (_, _) {},
            onSetEffectEnabled: (_, {required enabled}) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('signalGraph_addPlugin')));
      await tester.pumpAndSettle();
      expect(addedPlugin, 1);
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
      int stepCount = 0,
      List<String> valueTexts = const [],
    }) => PluginParamInfo(
      id: id,
      name: name,
      unit: '',
      min: min,
      max: max,
      def: def,
      stepCount: stepCount,
      flags: flags,
      valueTexts: valueTexts,
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
      String? Function(int index, int paramId, double value)?
      onFormatPluginValue,
      void Function(int index, {required bool enabled})? onSetEffectEnabled,
    }) => Scaffold(
      body: SignalFxRack(
        keyPrefix: 'signalGraph_lane',
        effects: [fx],
        onAddEffect: (_) {},
        onAddPlugin: () {},
        onRemoveEffect: onRemoveEffect ?? (_) {},
        onSetType: (_, _) {},
        onSetParam: (_, _, _) {},
        onSetPluginParam: onSetPluginParam ?? (_, _, _) {},
        onOpenPluginEditor: onOpenPluginEditor ?? (_) {},
        onRelinkPlugin: onRelinkPlugin ?? (_) {},
        onReorder: (_, _) {},
        onSetEffectEnabled: onSetEffectEnabled ?? (_, {required enabled}) {},
        onFormatPluginValue: onFormatPluginValue,
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

    testWidgets('renders a knob for every user-visible param, uncapped', (
      tester,
    ) async {
      await tester.pumpApp(
        build(
          fx: plugin(
            params: [for (var i = 0; i < 12; i++) param(i, 'P$i')],
          ),
        ),
      );
      // Every automatable param gets a knob — they wrap into rows and the card
      // grows taller rather than truncating (no cap, no horizontal scroll).
      expect(find.byType(SignalKnob), findsNWidgets(12));
      final params = find.byKey(const Key('signalGraph_lane_device_0_params'));
      expect(params, findsOneWidget);
      // 12 knobs at 60px in a 360px body = 6 per row -> a second row, so the
      // control area is taller than a single row.
      expect(tester.getSize(params).height, greaterThan(100));
    });

    testWidgets('a boolean param renders a switch, not a knob', (tester) async {
      var lastSet = -1.0;
      await tester.pumpApp(
        build(
          fx: plugin(
            // stepCount 1 = on/off; seeded off (def 0).
            params: [param(10, 'Sync', stepCount: 1, def: 0)],
          ),
          onSetPluginParam: (_, _, v) => lastSet = v,
        ),
      );
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(SignalKnob), findsNothing);

      // Flipping the switch drives the param to its max (on).
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_param_0')),
      );
      expect(lastSet, 1.0);
    });

    testWidgets('a discrete enum param renders a dropdown of its labels', (
      tester,
    ) async {
      var lastSet = -1.0;
      await tester.pumpApp(
        build(
          fx: plugin(
            params: [
              param(
                10,
                'Filter',
                flags: 0x01 | 0x10, // automatable + stepped
                max: 2,
                def: 0,
                stepCount: 2,
                valueTexts: const ['Lowpass', 'Highpass', 'Bandpass'],
              ),
            ],
          ),
          onSetPluginParam: (_, _, v) => lastSet = v,
        ),
      );
      expect(find.byType(SignalKnob), findsNothing);
      // The current step label shows; the others appear on open.
      expect(find.text('Lowpass'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_param_0')),
      );
      await tester.pumpAndSettle();
      // Picking 'Bandpass' (step 2 over [0, 2]) sets the plain value to 2.0.
      await tester.tap(find.text('Bandpass').last);
      await tester.pumpAndSettle();
      expect(lastSet, 2.0);
    });

    testWidgets('the knob readout uses the plugin format when provided', (
      tester,
    ) async {
      await tester.pumpApp(
        build(
          fx: plugin(params: [param(10, 'Gain')]),
          onFormatPluginValue: (_, _, _) => '-6.0 dB',
        ),
      );
      // The live plugin-formatted readout wins over the bare number.
      expect(find.text('-6.0 dB'), findsOneWidget);
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

    testWidgets('the plugin card carries the power control, not a bypass', (
      tester,
    ) async {
      final calls = <(int, bool)>[];
      final params = <(int, int, double)>[];
      await tester.pumpApp(
        build(
          // A plugin exposing its OWN bypass param (automatable + bypass flag).
          fx: plugin(
            params: [param(99, 'Bypass', flags: 0x01 | 0x04, def: 0)],
          ),
          onSetPluginParam: (i, id, v) => params.add((i, id, v)),
          onSetEffectEnabled: (i, {required enabled}) =>
              calls.add((i, enabled)),
        ),
      );

      // D-POWER (R23): the retired bypass toggle is gone, exactly one power
      // control is present, and the plugin's own bypass param earns no control
      // of its own (it stays in the plugin's native editor).
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_bypass')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_power')),
        findsOneWidget,
      );
      expect(find.byType(SignalKnob), findsNothing);

      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_power')),
      );
      await tester.pump();
      // The host enable flipped; the plugin's bypass param was never touched.
      expect(calls, [(0, false)]);
      expect(params, isEmpty);
    });

    testWidgets('a powered-off plugin toggles back on', (tester) async {
      final calls = <(int, bool)>[];
      await tester.pumpApp(
        build(
          fx: plugin().copyWith(enabled: false),
          onSetEffectEnabled: (i, {required enabled}) =>
              calls.add((i, enabled)),
        ),
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_power')),
      );
      await tester.pump();
      expect(calls, [(0, true)]);
    });

    testWidgets('an unavailable plugin keeps its power control', (
      tester,
    ) async {
      final calls = <(int, bool)>[];
      await tester.pumpApp(
        build(
          fx: plugin().copyWith(unavailable: true),
          onSetEffectEnabled: (i, {required enabled}) =>
              calls.add((i, enabled)),
        ),
      );
      // The D-MISS placeholder is still a card, so it still powers off.
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_reason')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_0_power')),
      );
      await tester.pump();
      expect(calls, [(0, false)]);
    });

    testWidgets('a powered-off plugin card dims its body, not its header', (
      tester,
    ) async {
      await tester.pumpApp(
        build(
          fx: plugin(params: [param(10, 'A')]).copyWith(enabled: false),
        ),
      );
      await tester.pumpAndSettle();

      final dim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(const Key('signalGraph_lane_device_0')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(dim.opacity, SurfaceTheme.dark.disabledOpacity);
      // The header — name, editor, power, remove — stays at full strength.
      expect(
        find.descendant(
          of: find.byType(AnimatedOpacity),
          matching: find.byKey(const Key('signalGraph_lane_device_0_power')),
        ),
        findsNothing,
      );
    });

    testWidgets('an engaged plugin card is not dimmed', (tester) async {
      await tester.pumpApp(build(fx: plugin(params: [param(10, 'A')])));
      await tester.pumpAndSettle();

      final dim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(const Key('signalGraph_lane_device_0')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(dim.opacity, 1.0);
    });

    testWidgets('a powered-off placeholder keeps its warning dominant', (
      tester,
    ) async {
      await tester.pumpApp(
        build(fx: plugin().copyWith(unavailable: true, enabled: false)),
      );
      await tester.pumpAndSettle();

      // R26: the disabled dim never buries the state the user must act on, so
      // the placeholder card is deliberately not dimmed.
      expect(
        find.descendant(
          of: find.byKey(const Key('signalGraph_lane_device_0')),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
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

    testWidgets(
      'a loading plugin shows a spinner + "Loading…", no relink (F5)',
      (tester) async {
        await tester.pumpApp(
          build(
            fx: plugin(id: 'scanning', name: 'My Reverb').copyWith(
              loading: true,
            ),
          ),
        );
        // The still-resolving entry reads as loading, not a genuine failure.
        expect(find.text('Loading…'), findsOneWidget);
        expect(find.text('Plugin unavailable'), findsNothing);
        expect(
          find.byKey(const Key('signalGraph_lane_device_0_spinner')),
          findsOneWidget,
        );
        // No relink — it is expected to bind on its own once the scan lands.
        expect(
          find.byKey(const Key('signalGraph_lane_device_0_relink')),
          findsNothing,
        );
        // The saved display name still shows so the slot is identifiable.
        expect(find.text('My Reverb'), findsOneWidget);
      },
    );

    testWidgets('loading takes precedence over unavailable', (tester) async {
      // A restored entry can carry a stale unavailable from a prior apply while
      // the fresh scan is pending; loading wins so it never flashes the
      // "unavailable" message.
      await tester.pumpApp(
        build(
          fx: plugin(id: 'scanning').copyWith(loading: true, unavailable: true),
        ),
      );
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.text('Plugin unavailable'), findsNothing);
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_relink')),
        findsNothing,
      );
    });

    testWidgets('an unsupported plugin shows the distinct reason', (
      tester,
    ) async {
      await tester.pumpApp(
        build(
          fx: plugin(
            id: 'synth',
          ).copyWith(unavailable: true, unsupported: true),
        ),
      );
      // The placeholder distinguishes "unsupported" (installed but rejected)
      // from the plain "unavailable" (missing) message.
      expect(find.text('Plugin unsupported'), findsOneWidget);
      expect(find.text('Plugin unavailable'), findsNothing);
      // Still relinkable.
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_relink')),
        findsOneWidget,
      );
    });

    testWidgets('a version-changed plugin shows the drift badge', (
      tester,
    ) async {
      await tester.pumpApp(
        build(fx: plugin(id: 'My Plugin').copyWith(versionChanged: true)),
      );
      // The plugin still loads (live controls present) but flags the drift.
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_versionChanged')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_openEditor')),
        findsOneWidget,
      );
    });

    testWidgets('a current-version plugin shows no drift badge', (
      tester,
    ) async {
      await tester.pumpApp(build(fx: plugin(id: 'My Plugin')));
      expect(
        find.byKey(const Key('signalGraph_lane_device_0_versionChanged')),
        findsNothing,
      );
    });
  });
}
