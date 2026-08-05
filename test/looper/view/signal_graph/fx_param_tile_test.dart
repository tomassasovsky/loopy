import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/signal_graph/fx_param_tile.dart';

import '../../../helpers/helpers.dart';

PluginParamInfo _param({
  int id = 1,
  String name = 'Drive',
  String unit = '',
  double min = 0,
  double max = 10,
  double def = 5,
  int stepCount = 0,
  int flags = 0x01,
  List<String> valueTexts = const [],
}) => PluginParamInfo(
  id: id,
  name: name,
  unit: unit,
  min: min,
  max: max,
  def: def,
  stepCount: stepCount,
  flags: flags,
  valueTexts: valueTexts,
);

void main() {
  group('FxParamTile', () {
    testWidgets("prefers the plugin's own preformatted string", (
      tester,
    ) async {
      // The plugin hands value and unit over together ("-6.0 dB"); splitting
      // them would mean parsing its own formatting apart, so the unit slot
      // simply goes unused when it offers text.
      await tester.pumpApp(
        Scaffold(
          body: FxParamTile(
            spec: _param(unit: 'dB'),
            value: 5,
            valueText: '-6.0 dB',
            onTap: () {},
          ),
        ),
      );

      expect(find.text('-6.0 dB'), findsOneWidget);
      expect(find.text('dB'), findsNothing);
    });

    testWidgets('falls back to the number plus the unit field', (tester) async {
      await tester.pumpApp(
        Scaffold(
          body: FxParamTile(
            spec: _param(unit: 'dB'),
            value: 5,
            valueText: null,
            onTap: () {},
          ),
        ),
      );

      expect(find.text('5.00'), findsOneWidget);
      expect(find.text('dB'), findsOneWidget);
    });

    testWidgets('an empty plugin string is treated as no string', (
      tester,
    ) async {
      // A plugin that returns "" for a value must not blank the readout.
      await tester.pumpApp(
        Scaffold(
          body: FxParamTile(
            spec: _param(unit: 'dB'),
            value: 5,
            valueText: '',
            onTap: () {},
          ),
        ),
      );

      expect(find.text('5.00'), findsOneWidget);
    });

    testWidgets('the name is uppercased and ellipsizes, never wraps', (
      tester,
    ) async {
      await tester.pumpApp(
        Scaffold(
          body: FxParamTile(
            spec: _param(name: 'Extremely long parameter name'),
            value: 5,
            valueText: '5',
            onTap: () {},
          ),
        ),
      );

      final text = tester.widget<Text>(
        find.text('EXTREMELY LONG PARAMETER NAME'),
      );
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('a read-only tile is not tappable and is marked read-only', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpApp(
        Scaffold(
          body: FxParamTile(
            spec: _param(),
            value: 5,
            valueText: '5',
            onTap: null,
          ),
        ),
      );

      expect(find.byType(InkWell), findsNothing);
      expect(
        tester.getSemantics(find.byType(FxParamTile)),
        matchesSemantics(isReadOnly: true),
      );
      handle.dispose();
    });

    testWidgets('holds the DS skeleton size regardless of kind', (
      tester,
    ) async {
      // The whole point of the grid is that every kind wears one skeleton, so
      // columns stay aligned however the strip is composed.
      await tester.pumpApp(
        Scaffold(
          body: Row(
            children: [
              FxParamTile(
                spec: _param(),
                value: 5,
                valueText: '5',
                onTap: () {},
              ),
              FxParamSwitchCell(
                spec: _param(stepCount: 1, max: 1),
                value: 1,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      );

      for (final finder in [
        find.byType(FxParamTile),
        find.byType(FxParamSwitchCell),
      ]) {
        expect(tester.getSize(finder).width, FxParamTileMetrics.width);
        expect(tester.getSize(finder).height, FxParamTileMetrics.height);
      }
    });
  });

  group('FxParamSwitchCell', () {
    testWidgets('reads on from the midpoint up and drives to the extremes', (
      tester,
    ) async {
      final sent = <double>[];
      await tester.pumpApp(
        Scaffold(
          body: FxParamSwitchCell(
            spec: _param(stepCount: 1, min: -1, max: 1, def: -1),
            // Below the -1..1 midpoint of 0, so it reads off.
            value: -1,
            onChanged: sent.add,
          ),
        ),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.byType(Switch));
      expect(sent, [1.0]);
    });

    testWidgets('carries no caption — the switch position is the value', (
      tester,
    ) async {
      // The DS drops the redundant On/Off line the old control carried.
      await tester.pumpApp(
        Scaffold(
          body: FxParamSwitchCell(
            spec: _param(name: 'Vintage', stepCount: 1, max: 1),
            value: 1,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('VINTAGE'), findsOneWidget);
      expect(find.text('On'), findsNothing);
      expect(find.text('Off'), findsNothing);
    });
  });

  group('FxParamEnumCell', () {
    testWidgets('shows the current step label and picks by plain value', (
      tester,
    ) async {
      final sent = <double>[];
      await tester.pumpApp(
        Scaffold(
          body: FxParamEnumCell(
            spec: _param(
              name: 'Type',
              max: 2,
              stepCount: 2,
              valueTexts: const ['Lowpass', 'Highpass', 'Bandpass'],
            ),
            value: 0,
            onChanged: sent.add,
          ),
        ),
      );

      expect(find.text('Lowpass'), findsOneWidget);

      await tester.tap(find.byType(FxParamEnumCell));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bandpass').last);
      await tester.pumpAndSettle();

      // Step 2 over the [0, 2] range is the plain value 2.
      expect(sent, [2.0]);
    });

    testWidgets('a step past the label list falls back to its index', (
      tester,
    ) async {
      // Defensive: the plugin reports stepCount and labels separately, so a
      // short list must not throw a range error mid-render.
      await tester.pumpApp(
        Scaffold(
          body: FxParamEnumCell(
            spec: _param(
              max: 3,
              stepCount: 3,
              valueTexts: const ['Only one'],
            ),
            value: 3,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('3'), findsOneWidget);
    });
  });
}
