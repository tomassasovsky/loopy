import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/lane_strip_view.dart';

import '../../helpers/helpers.dart';

void main() {
  group('LaneStripView', () {
    /// Pumps a [LaneStripView] for [lane], recording the callbacks it fires.
    Future<_Recorded> pumpStrip(
      WidgetTester tester, {
      required Lane lane,
      int? selectedEffect,
      bool canRemove = false,
    }) async {
      final recorded = _Recorded();
      await tester.pumpApp(
        Scaffold(
          body: LaneStripView(
            laneIndex: 0,
            lane: lane,
            inputChannels: 2,
            outputChannels: 2,
            selectedEffect: selectedEffect,
            canRemove: canRemove,
            onInputChanged: (c) => recorded.input = c,
            onOutputMaskChanged: (m) => recorded.outputMask = m,
            onVolumeChanged: (v) => recorded.volume = v,
            onMuteToggled: () => recorded.muteToggled = true,
            onAddEffect: () => recorded.addedEffect = true,
            onSelectEffect: (i) => recorded.selected = i,
            onMoveEffect: (f, t) => recorded.moved = (f, t),
            onSetType: (i, t) => recorded.setType = (i, t),
            onSetParam: (i, p, v) => recorded.setParam = (i, p, v),
            onRemoveEffect: (i) => recorded.removedEffect = i,
            onRemoveLane: () => recorded.removedLane = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return recorded;
    }

    testWidgets('selecting an input reports the channel', (tester) async {
      final r = await pumpStrip(tester, lane: const Lane());

      await tester.tap(find.byKey(const Key('lane_0_input')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 2').last);
      await tester.pumpAndSettle();

      expect(r.input, 1);
    });

    testWidgets('the input shows the lane channel and offers No input', (
      tester,
    ) async {
      await pumpStrip(tester, lane: const Lane(inputChannel: 1));
      expect(find.text('In 2'), findsOneWidget);
    });

    testWidgets('toggling an output chip reports the new mask', (tester) async {
      final r = await pumpStrip(tester, lane: const Lane());

      // Default mask 0x3; toggling out 1 (index 0) clears it -> 0x2.
      await tester.tap(find.byKey(const Key('lane_0_output_0')));
      expect(r.outputMask, 0x2);
    });

    testWidgets('dragging the volume slider reports the value', (tester) async {
      final r = await pumpStrip(tester, lane: const Lane(volume: 0.5));

      await tester.drag(
        find.byKey(const Key('lane_0_vol')),
        const Offset(-100, 0),
      );
      expect(r.volume, isNotNull);
      expect(r.volume! < 0.5, isTrue);
    });

    testWidgets('tapping mute fires the callback', (tester) async {
      final r = await pumpStrip(tester, lane: const Lane());
      await tester.tap(find.byKey(const Key('lane_0_mute')));
      expect(r.muteToggled, isTrue);
    });

    testWidgets('the add button fires onAddEffect', (tester) async {
      final r = await pumpStrip(tester, lane: const Lane());
      await tester.tap(find.byKey(const Key('lane_0_fx_add')));
      expect(r.addedEffect, isTrue);
    });

    testWidgets('the add button is disabled when the chain is full', (
      tester,
    ) async {
      final full = Lane(
        effects: [
          for (var i = 0; i < kTrackEffectMax; i++)
            TrackEffect(type: TrackEffectType.drive),
        ],
      );
      final r = await pumpStrip(tester, lane: full);
      await tester.tap(find.byKey(const Key('lane_0_fx_add')));
      expect(r.addedEffect, isNull);
    });

    testWidgets('tapping an effect chip selects it', (tester) async {
      final r = await pumpStrip(
        tester,
        lane: Lane(effects: [TrackEffect(type: TrackEffectType.delay)]),
      );
      await tester.tap(find.byKey(const Key('lane_0_fx_0')));
      expect(r.selected, 0);
    });

    testWidgets('the selected effect shows an editor with its params', (
      tester,
    ) async {
      await pumpStrip(
        tester,
        lane: Lane(effects: [TrackEffect(type: TrackEffectType.delay)]),
        selectedEffect: 0,
      );
      expect(find.byKey(const Key('lane_0_fx_editor')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_type')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_param0')), findsOneWidget);
    });

    testWidgets('dragging a param slider reports the change', (tester) async {
      final r = await pumpStrip(
        tester,
        lane: Lane(
          effects: [
            TrackEffect(type: TrackEffectType.drive, params: const [0, 0, 0]),
          ],
        ),
        selectedEffect: 0,
      );
      await tester.drag(
        find.byKey(const Key('lane_0_fx_param0')),
        const Offset(120, 0),
      );
      expect(r.setParam, isNotNull);
      expect(r.setParam!.$1, 0); // index
      expect(r.setParam!.$2, 0); // param
      expect(r.setParam!.$3 > 0, isTrue); // dragging right raises the value
    });

    testWidgets('changing the effect type fires onSetType', (tester) async {
      final r = await pumpStrip(
        tester,
        lane: Lane(effects: [TrackEffect(type: TrackEffectType.drive)]),
        selectedEffect: 0,
      );

      await tester.tap(find.byKey(const Key('lane_0_fx_type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delay').last);
      await tester.pumpAndSettle();

      expect(r.setType, isNotNull);
      expect(r.setType!.$1, 0);
      expect(r.setType!.$2, TrackEffectType.delay);
    });

    testWidgets('dragging an effect handle fires onMoveEffect', (tester) async {
      final r = await pumpStrip(
        tester,
        lane: Lane(
          effects: [
            TrackEffect(type: TrackEffectType.drive),
            TrackEffect(type: TrackEffectType.delay),
          ],
        ),
      );

      final handle = find.byKey(const Key('lane_0_fx_handle_0'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 200));
      // Drag the first chip to the right, past the second, then release.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(r.moved, isNotNull);
      expect(r.moved!.$1, 0); // moved the first entry
    });

    testWidgets('an excluded (loopback) input is offered disabled', (
      tester,
    ) async {
      final recorded = _Recorded();
      await tester.pumpApp(
        Scaffold(
          body: LaneStripView(
            laneIndex: 0,
            lane: const Lane(),
            inputChannels: 2,
            outputChannels: 2,
            excludedInputMask: 0x2, // input 2 is loopback
            selectedEffect: null,
            canRemove: false,
            onInputChanged: (c) => recorded.input = c,
            onOutputMaskChanged: (_) {},
            onVolumeChanged: (_) {},
            onMuteToggled: () {},
            onAddEffect: () {},
            onSelectEffect: (_) {},
            onMoveEffect: (_, _) {},
            onSetType: (_, _) {},
            onSetParam: (_, _, _) {},
            onRemoveEffect: (_) {},
            onRemoveLane: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lane_0_input')));
      await tester.pumpAndSettle();
      // Tapping the disabled In 2 item does nothing.
      await tester.tap(find.text('In 2').last);
      await tester.pumpAndSettle();
      expect(recorded.input, isNull);
    });

    testWidgets('removing the selected effect fires onRemoveEffect', (
      tester,
    ) async {
      final r = await pumpStrip(
        tester,
        lane: Lane(effects: [TrackEffect(type: TrackEffectType.drive)]),
        selectedEffect: 0,
      );
      await tester.tap(find.byKey(const Key('lane_0_fx_remove')));
      expect(r.removedEffect, 0);
    });

    testWidgets('the remove-lane button only shows when canRemove', (
      tester,
    ) async {
      await pumpStrip(tester, lane: const Lane());
      expect(find.byKey(const Key('lane_0_remove')), findsNothing);

      final r = await pumpStrip(tester, lane: const Lane(), canRemove: true);
      await tester.tap(find.byKey(const Key('lane_0_remove')));
      expect(r.removedLane, isTrue);
    });
  });
}

/// Mutable bag recording the callbacks a [LaneStripView] fires.
class _Recorded {
  int? input;
  int? outputMask;
  double? volume;
  bool? muteToggled;
  bool? addedEffect;
  int? selected;
  (int, int)? moved;
  (int, TrackEffectType)? setType;
  (int, int, double)? setParam;
  int? removedEffect;
  bool? removedLane;
}
