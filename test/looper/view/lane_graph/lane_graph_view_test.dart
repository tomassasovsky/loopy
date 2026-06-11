import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/lane_graph/lane_graph_view.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('LaneGraphView', () {
    Future<_Rec> pump(
      WidgetTester tester, {
      required List<Lane> lanes,
      ({int lane, int index})? selectedEffect,
      int excludedInputMask = 0,
    }) async {
      final rec = _Rec();
      await tester.pumpApp(
        Scaffold(
          body: LaneGraphView(
            lanes: lanes,
            inputChannels: 3,
            outputChannels: 2,
            excludedInputMask: excludedInputMask,
            selectedEffect: selectedEffect,
            onInputChanged: (l, c) => rec.input = (l, c),
            onOutputMaskChanged: (l, m) => rec.outputMask = (l, m),
            onVolumeChanged: (l, v) => rec.volume = (l, v),
            onMuteToggled: (l) => rec.muteToggled = l,
            onAddEffect: (l) => rec.addedEffect = l,
            onSelectEffect: (l, i) => rec.selected = (l, i),
            onMoveEffect: (l, f, t) => rec.moved = (l, f, t),
            onSetType: (l, i, t) => rec.setType = (l, i, t),
            onSetParam: (l, i, p, v) => rec.setParam = (l, i, p, v),
            onRemoveEffect: (l, i) => rec.removedEffect = (l, i),
            onAddLane: () => rec.addedLane = true,
            onRemoveLane: (l) => rec.removedLane = l,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return rec;
    }

    testWidgets('wiring an input needs a focused lane', (tester) async {
      final rec = await pump(tester, lanes: const [Lane()]);

      // No lane focused yet: tapping an input does nothing.
      await tester.tap(find.byKey(const Key('laneGraph_in_1')));
      await tester.pump();
      expect(rec.input, isNull);

      // Focus lane 0, then wire In 2 (channel index 1).
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_in_1')));
      await tester.pump();
      expect(rec.input, (0, 1));
    });

    testWidgets('tapping a wired input again clears it', (tester) async {
      final rec = await pump(tester, lanes: const [Lane(inputChannel: 1)]);
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_in_1')));
      await tester.pump();
      expect(rec.input, (0, -1));
    });

    testWidgets('toggling an output on the focused lane reports the mask', (
      tester,
    ) async {
      final rec = await pump(tester, lanes: const [Lane()]);
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      // Default mask 0x3; toggling Out 1 (index 0) -> 0x2.
      await tester.tap(find.byKey(const Key('laneGraph_out_0')));
      await tester.pump();
      expect(rec.outputMask, (0, 0x2));
    });

    testWidgets('the focused lane panel mutes and sets volume', (tester) async {
      final rec = await pump(tester, lanes: const [Lane(volume: 0.6)]);
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('laneGraph_mute')));
      expect(rec.muteToggled, 0);

      await tester.drag(
        find.byKey(const Key('laneGraph_vol')),
        const Offset(-80, 0),
      );
      expect(rec.volume, isNotNull);
      expect(rec.volume!.$1, 0);
      expect(rec.volume!.$2 < 0.6, isTrue);
    });

    testWidgets('the add-effect button reports its lane', (tester) async {
      final rec = await pump(tester, lanes: const [Lane()]);
      await tester.tap(find.byKey(const Key('laneGraph_addFx_0')));
      expect(rec.addedEffect, 0);
    });

    testWidgets('the add-effect button is disabled when the chain is full', (
      tester,
    ) async {
      final full = Lane(
        effects: [
          for (var i = 0; i < kTrackEffectMax; i++)
            TrackEffect(type: TrackEffectType.drive),
        ],
      );
      final rec = await pump(tester, lanes: [full]);
      await tester.tap(find.byKey(const Key('laneGraph_addFx_0')));
      expect(rec.addedEffect, isNull);
    });

    testWidgets('tapping an effect chip selects it', (tester) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(effects: [TrackEffect(type: TrackEffectType.delay)]),
        ],
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxLabel_0_0')));
      await tester.pump();
      expect(rec.selected, (0, 0));
    });

    testWidgets('the selected effect opens an editor in the panel', (
      tester,
    ) async {
      await pump(
        tester,
        lanes: [
          Lane(effects: [TrackEffect(type: TrackEffectType.delay)]),
        ],
        selectedEffect: (lane: 0, index: 0),
      );
      expect(find.byKey(const Key('laneGraph_fxEditor')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxType')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam0')), findsOneWidget);
    });

    testWidgets('changing the effect type reports it', (tester) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(effects: [TrackEffect(type: TrackEffectType.drive)]),
        ],
        selectedEffect: (lane: 0, index: 0),
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxType')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delay').last);
      await tester.pumpAndSettle();
      expect(rec.setType, (0, 0, TrackEffectType.delay));
    });

    testWidgets('dragging a param slider reports a higher value', (
      tester,
    ) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(
            effects: [
              TrackEffect(type: TrackEffectType.drive, params: const [0, 0, 0]),
            ],
          ),
        ],
        selectedEffect: (lane: 0, index: 0),
      );
      await tester.drag(
        find.byKey(const Key('laneGraph_fxParam0')),
        const Offset(120, 0),
      );
      expect(rec.setParam, isNotNull);
      expect(rec.setParam!.$1, 0);
      expect(rec.setParam!.$2, 0);
      expect(rec.setParam!.$4 > 0, isTrue);
    });

    testWidgets('removing the selected effect reports it', (tester) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(effects: [TrackEffect(type: TrackEffectType.drive)]),
        ],
        selectedEffect: (lane: 0, index: 0),
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxRemove')));
      expect(rec.removedEffect, (0, 0));
    });

    testWidgets('dragging an effect handle reports a move within the lane', (
      tester,
    ) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(
            effects: [
              TrackEffect(type: TrackEffectType.drive),
              TrackEffect(type: TrackEffectType.delay),
            ],
          ),
        ],
      );
      final handle = find.byKey(const Key('laneGraph_fxHandle_0_0'));
      final target = find.byKey(const Key('laneGraph_drop_0_2'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rec.moved, isNotNull);
      expect(rec.moved!.$1, 0); // lane
      expect(rec.moved!.$2, 0); // from
    });

    testWidgets('the add-lane button reports', (tester) async {
      final rec = await pump(tester, lanes: const [Lane()]);
      await tester.tap(find.byKey(const Key('laneGraph_addLane')));
      expect(rec.addedLane, isTrue);
    });

    testWidgets('any lane can be removed when more than one exists', (
      tester,
    ) async {
      final rec = await pump(tester, lanes: const [Lane(), Lane()]);

      // Focus lane 0 (not the last) and remove it directly.
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_removeLane')));
      expect(rec.removedLane, 0);
    });

    testWidgets('a single lane cannot be removed', (tester) async {
      await pump(tester, lanes: const [Lane()]);
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('laneGraph_removeLane')), findsNothing);
    });

    testWidgets('the per-card delete button removes that effect', (
      tester,
    ) async {
      final rec = await pump(
        tester,
        lanes: [
          Lane(
            effects: [
              TrackEffect(type: TrackEffectType.drive),
              TrackEffect(type: TrackEffectType.delay),
            ],
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('laneGraph_fxDelete_0_1')));
      expect(rec.removedEffect, (0, 1));
    });

    testWidgets('an excluded input cannot be wired', (tester) async {
      final rec = await pump(
        tester,
        lanes: const [Lane()],
        excludedInputMask: 0x2, // In 2 is loopback
      );
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_in_1')));
      await tester.pump();
      expect(rec.input, isNull);
    });
  });
}

/// Mutable bag recording the callbacks a [LaneGraphView] fires.
class _Rec {
  (int, int)? input;
  (int, int)? outputMask;
  (int, double)? volume;
  int? muteToggled;
  int? addedEffect;
  (int, int?)? selected;
  (int, int, int)? moved;
  (int, int, TrackEffectType)? setType;
  (int, int, int, double)? setParam;
  (int, int)? removedEffect;
  bool? addedLane;
  int? removedLane;
}
