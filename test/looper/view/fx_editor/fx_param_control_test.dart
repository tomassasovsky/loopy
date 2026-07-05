import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/fx_editor/fx_param_control.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('FxParamControl (built-in)', () {
    testWidgets('shows the param label and a percent readout', (tester) async {
      await tester.pumpApp(
        Scaffold(
          body: FxParamControl(
            controlKey: const Key('slider'),
            fx: BuiltInEffect(
              type: TrackEffectType.drive,
              params: const [0.5, 1],
            ),
            param: 0,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
    });

    testWidgets('reports a normalized value as the slider moves', (
      tester,
    ) async {
      double? value;
      await tester.pumpApp(
        Scaffold(
          body: FxParamControl(
            controlKey: const Key('slider'),
            fx: BuiltInEffect(
              type: TrackEffectType.drive,
              params: const [0, 0],
            ),
            param: 0,
            onChanged: (v) => value = v,
          ),
        ),
      );

      await tester.drag(find.byType(Slider), const Offset(200, 0));
      expect(value, isNotNull);
      expect(value, greaterThan(0));
      expect(value, lessThanOrEqualTo(1));
    });
  });

  group('FxPluginParamControl', () {
    const gain = PluginParamInfo(
      id: 7,
      name: 'Gain',
      unit: 'dB',
      min: -12,
      max: 12,
      def: 0,
      stepCount: 0,
      flags: 0x01,
    );

    testWidgets('labels with the plugin param name', (tester) async {
      await tester.pumpApp(
        Scaffold(
          body: FxPluginParamControl(
            controlKey: const Key('slider'),
            spec: gain,
            value: 0,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Gain'), findsOneWidget);
    });

    testWidgets('prefers the plugin-provided readout when available', (
      tester,
    ) async {
      await tester.pumpApp(
        Scaffold(
          body: FxPluginParamControl(
            controlKey: const Key('slider'),
            spec: gain,
            value: 0,
            onChanged: (_) {},
            onFormatValue: (id, v) => '$id:${v.toStringAsFixed(0)} dB',
          ),
        ),
      );

      expect(find.text('7:0 dB'), findsOneWidget);
    });

    testWidgets('de-normalizes the slider back into the plain range', (
      tester,
    ) async {
      double? plain;
      await tester.pumpApp(
        Scaffold(
          body: FxPluginParamControl(
            controlKey: const Key('slider'),
            spec: gain,
            value: 0,
            onChanged: (v) => plain = v,
          ),
        ),
      );

      // Drag toward the maximum — the reported plain value climbs above 0
      // (its normalized midpoint) toward +12.
      await tester.drag(find.byType(Slider), const Offset(300, 0));
      expect(plain, isNotNull);
      expect(plain, greaterThan(0));
      expect(plain, lessThanOrEqualTo(12));
    });
  });
}
