import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/signal_dock.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('SignalInputDock', () {
    testWidgets('Stop, mute, and the volume knob are wired', (tester) async {
      var stopped = false;
      var muteToggled = false;
      double? volume;
      await tester.pumpApp(
        Scaffold(
          body: SignalInputDock(
            input: 0,
            monitor: const InputMonitor(input: 0, enabled: true),
            onMuteToggled: () => muteToggled = true,
            onVolumeChanged: (v) => volume = v,
            onStop: () => stopped = true,
            onAddEffect: () {},
            onSetType: (_, _) {},
            onSetParam: (_, _, _) {},
            onSetPluginParam: (_, _, _) {},
            onOpenPluginEditor: (_) {},
            onRelinkPlugin: (_) {},
            onRemoveEffect: (_) {},
            onReorderEffect: (_, _) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('signalGraph_stop')));
      expect(stopped, isTrue);
      await tester.tap(find.byKey(const Key('signalGraph_mute')));
      expect(muteToggled, isTrue);

      // Drag the VOL knob down — its onVolumeChanged must fire with a value.
      final knob = find.byKey(const Key('signalGraph_volume'));
      final gesture = await tester.startGesture(tester.getCenter(knob));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(volume, isNotNull);
    });
  });

  group('SignalLaneDock', () {
    Widget build({
      int inputNumber = 1,
      List<TrackEffect> effects = const [],
      bool canAddLane = true,
      bool canRemoveLane = true,
      VoidCallback? onAddLane,
      VoidCallback? onRemoveLane,
      ValueChanged<int>? onRemoveEffect,
      VoidCallback? onAddEffect,
    }) => Scaffold(
      body: SignalLaneDock(
        inputNumber: inputNumber,
        effects: effects,
        muted: false,
        volume: 1,
        canAddLane: canAddLane,
        canRemoveLane: canRemoveLane,
        onAddLane: onAddLane ?? () {},
        onRemoveLane: onRemoveLane ?? () {},
        onAddEffect: onAddEffect ?? () {},
        onRemoveEffect: onRemoveEffect ?? (_) {},
        onSetType: (_, _) {},
        onSetParam: (_, _, _) {},
        onSetPluginParam: (_, _, _) {},
        onOpenPluginEditor: (_) {},
        onRelinkPlugin: (_) {},
        onReorderEffect: (_, _) {},
        onMuteToggled: () {},
        onVolumeChanged: (_) {},
      ),
    );

    testWidgets('shows the "this take" snapshot badge naming the input', (
      tester,
    ) async {
      await tester.pumpApp(build(inputNumber: 2));
      expect(
        find.byKey(const Key('signalGraph_thisTakeBadge')),
        findsOneWidget,
      );
      expect(find.textContaining('In 2'), findsOneWidget);
    });

    testWidgets('a lane recording nothing shows no snapshot badge', (
      tester,
    ) async {
      await tester.pumpApp(build(inputNumber: 0));
      expect(find.byKey(const Key('signalGraph_thisTakeBadge')), findsNothing);
    });

    testWidgets('add/remove lane fire and respect their enabled flags', (
      tester,
    ) async {
      var added = false;
      var removed = false;
      await tester.pumpApp(
        build(
          onAddLane: () => added = true,
          onRemoveLane: () => removed = true,
        ),
      );
      await tester.tap(find.byKey(const Key('signalGraph_addLane')));
      await tester.tap(find.byKey(const Key('signalGraph_removeLane')));
      expect(added, isTrue);
      expect(removed, isTrue);
    });

    testWidgets('add lane is disabled at the cap', (tester) async {
      var added = false;
      await tester.pumpApp(
        build(canAddLane: false, onAddLane: () => added = true),
      );
      await tester.tap(find.byKey(const Key('signalGraph_addLane')));
      expect(added, isFalse);
    });

    testWidgets('each device card has its own remove', (tester) async {
      int? removedAt;
      await tester.pumpApp(
        build(
          effects: [
            BuiltInEffect(type: TrackEffectType.drive),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
          onRemoveEffect: (i) => removedAt = i,
        ),
      );
      // Removing the second device (index 1) reports that index.
      await tester.tap(
        find.byKey(const Key('signalGraph_lane_device_1_remove')),
      );
      expect(removedAt, 1);
    });
  });
}
