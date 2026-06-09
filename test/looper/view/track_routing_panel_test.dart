import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/track_routing_panel.dart';

import '../../helpers/helpers.dart';

void main() {
  group('TrackRoutingPanel', () {
    testWidgets('renders an output chip per channel reflecting the mask', (
      tester,
    ) async {
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(outputMask: 0x1),
            inputChannels: 2,
            outputChannels: 4,
            onInputMaskChanged: (_) {},
            onOutputMaskChanged: (_) {},
          ),
        ),
      );

      // One chip per output channel.
      for (var c = 0; c < 4; c++) {
        expect(find.byKey(Key('trackRouting_output_chip_$c')), findsOneWidget);
      }
      // Only channel 0 is selected (mask 0x1).
      final chip0 = tester.widget<FilterChip>(
        find.byKey(const Key('trackRouting_output_chip_0')),
      );
      final chip1 = tester.widget<FilterChip>(
        find.byKey(const Key('trackRouting_output_chip_1')),
      );
      expect(chip0.selected, isTrue);
      expect(chip1.selected, isFalse);
    });

    testWidgets('selecting an output chip adds its bit to the mask', (
      tester,
    ) async {
      int? mask;
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(outputMask: 0x1),
            inputChannels: 2,
            outputChannels: 4,
            onInputMaskChanged: (_) {},
            onOutputMaskChanged: (m) => mask = m,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trackRouting_output_chip_1')));
      await tester.pump();

      // Adding channel 1 to mask 0x1 yields 0x3.
      expect(mask, 0x3);
    });

    testWidgets('renders an input chip per channel reflecting the mask', (
      tester,
    ) async {
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(inputMask: 0x2),
            inputChannels: 2,
            outputChannels: 2,
            onInputMaskChanged: (_) {},
            onOutputMaskChanged: (_) {},
          ),
        ),
      );

      for (var c = 0; c < 2; c++) {
        expect(find.byKey(Key('trackRouting_input_chip_$c')), findsOneWidget);
      }
      // Only input channel 1 is selected (mask 0x2).
      final in0 = tester.widget<FilterChip>(
        find.byKey(const Key('trackRouting_input_chip_0')),
      );
      final in1 = tester.widget<FilterChip>(
        find.byKey(const Key('trackRouting_input_chip_1')),
      );
      expect(in0.selected, isFalse);
      expect(in1.selected, isTrue);
    });

    testWidgets('selecting a second input adds its bit to the input mask', (
      tester,
    ) async {
      int? mask;
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(),
            inputChannels: 2,
            outputChannels: 2,
            onInputMaskChanged: (m) => mask = m,
            onOutputMaskChanged: (_) {},
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trackRouting_input_chip_1')));
      await tester.pump();

      // Adding input 1 to mask 0x1 yields 0x3 (record both inputs).
      expect(mask, 0x3);
    });
  });
}
