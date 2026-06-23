import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';

import '../helpers/pump_app.dart';

void main() {
  Widget editorFor(BuiltInEffect fx, {double addedLatencyMs = 0}) => Scaffold(
    body: EffectParamsEditor(
      keyPrefix: 'laneGraph',
      fx: fx,
      accentColor: Colors.blue,
      addedLatencyMs: addedLatencyMs,
      onSetType: (_) {},
      onSetParam: (_, _) {},
      onRemove: () {},
    ),
  );

  // A PV-mode octaver keeps the default Mode (0.0); a PSOLA octaver sets it to
  // 1.0. (Shift, Tone, Mix are irrelevant to the latency hint.)
  BuiltInEffect octaver({required bool psola}) {
    final mode = psola ? 1.0 : 0.0;
    return BuiltInEffect(
      type: TrackEffectType.octaver,
      params: [0.25, 0.5, 0.5, mode],
    );
  }

  const hintKey = Key('laneGraph_octaverLatencyHint');

  group('EffectParamsEditor', () {
    testWidgets('octaver renders a discrete two-state Mode control', (
      tester,
    ) async {
      await tester.pumpApp(
        editorFor(BuiltInEffect(type: TrackEffectType.octaver)),
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
      await tester.pumpApp(
        editorFor(BuiltInEffect(type: TrackEffectType.drive)),
      );

      expect(find.byKey(const Key('laneGraph_fxParam0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam1')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam2')), findsNothing);
      expect(find.byKey(const Key('laneGraph_fxParam3')), findsNothing);
    });

    testWidgets('a three-param effect shows exactly three sliders', (
      tester,
    ) async {
      // Delay uses three params; the widening must not surface the inert p3.
      await tester.pumpApp(
        editorFor(BuiltInEffect(type: TrackEffectType.delay)),
      );

      expect(find.byKey(const Key('laneGraph_fxParam2')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxParam3')), findsNothing);
    });

    group('phase-vocoder latency hint', () {
      testWidgets('shows for a PV octaver when the engine reports latency', (
        tester,
      ) async {
        await tester.pumpApp(
          editorFor(octaver(psola: false), addedLatencyMs: 21.3),
        );

        expect(find.byKey(hintKey), findsOneWidget);
        // The hint names PSOLA as the low-latency alternative and rounds the
        // reported ms for display (21.3 -> "21").
        final hint = tester.widget<Text>(find.byKey(hintKey));
        expect(hint.data, contains('21'));
        expect(hint.data, contains('PSOLA'));
      });

      testWidgets('hides when the engine reports no added latency', (
        tester,
      ) async {
        // A PV octaver that the engine has not engaged (e.g. stopped) reports
        // 0 ms — no lag to warn about.
        await tester.pumpApp(editorFor(octaver(psola: false)));

        expect(find.byKey(hintKey), findsNothing);
      });

      testWidgets('hides for a PSOLA octaver (the low-latency choice)', (
        tester,
      ) async {
        await tester.pumpApp(
          editorFor(octaver(psola: true), addedLatencyMs: 21.3),
        );

        expect(find.byKey(hintKey), findsNothing);
      });

      testWidgets('hides for a non-octaver effect', (tester) async {
        await tester.pumpApp(
          editorFor(
            BuiltInEffect(type: TrackEffectType.delay),
            addedLatencyMs: 21.3,
          ),
        );

        expect(find.byKey(hintKey), findsNothing);
      });
    });
  });
}
