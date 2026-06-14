import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';

import '../helpers/pump_app.dart';

void main() {
  Widget editorFor(TrackEffect fx) => Scaffold(
    body: EffectParamsEditor(
      keyPrefix: 'laneGraph',
      fx: fx,
      accentColor: Colors.blue,
      onSetType: (_) {},
      onSetParam: (_, _) {},
      onRemove: () {},
    ),
  );

  group('EffectParamsEditor', () {
    testWidgets('octaver renders a discrete two-state Mode control', (
      tester,
    ) async {
      await tester.pumpApp(
        editorFor(TrackEffect(type: TrackEffectType.octaver)),
      );

      // The octaver exposes four param rows; the last is Mode.
      expect(find.byKey(const Key('laneGraph_fxParam3')), findsOneWidget);
      expect(find.text('Mode'), findsOneWidget);

      // The Mode default (0.0) reads out as the phase vocoder, and the control
      // snaps to two states.
      expect(find.text('Phase Vocoder'), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('laneGraph_fxParam3')),
      );
      expect(slider.divisions, 1);
    });

    testWidgets('a non-octaver effect keeps its original slider count', (
      tester,
    ) async {
      // Drive uses two params; the widening must not add a slider for the inert
      // trailing slots.
      await tester.pumpApp(editorFor(TrackEffect(type: TrackEffectType.drive)));

      expect(find.byKey(const Key('laneGraph_fxParam0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam1')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam2')), findsNothing);
      expect(find.byKey(const Key('laneGraph_fxParam3')), findsNothing);
    });

    testWidgets('a three-param effect shows exactly three sliders', (
      tester,
    ) async {
      // Delay uses three params; the widening must not surface the inert p3.
      await tester.pumpApp(editorFor(TrackEffect(type: TrackEffectType.delay)));

      expect(find.byKey(const Key('laneGraph_fxParam2')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam3')), findsNothing);
    });
  });
}
