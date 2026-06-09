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
            track: const Track(inputChannel: 1, outputMask: 0x1),
            inputChannels: 2,
            outputChannels: 4,
            onInputChanged: (_) {},
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
            onInputChanged: (_) {},
            onOutputMaskChanged: (m) => mask = m,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trackRouting_output_chip_1')));
      await tester.pump();

      // Adding channel 1 to mask 0x1 yields 0x3.
      expect(mask, 0x3);
    });

    testWidgets('deselecting an output chip clears its bit', (tester) async {
      int? mask;
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(outputMask: 0x5),
            inputChannels: 2,
            outputChannels: 4,
            onInputChanged: (_) {},
            onOutputMaskChanged: (m) => mask = m,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trackRouting_output_chip_0')));
      await tester.pump();

      // Removing channel 0 from mask 0x5 (bits 0 and 2) yields 0x4.
      expect(mask, 0x4);
    });

    testWidgets('selecting an input source reports the new channel', (
      tester,
    ) async {
      int? input;
      await tester.pumpApp(
        Material(
          child: TrackRoutingPanel(
            track: const Track(),
            inputChannels: 2,
            outputChannels: 2,
            onInputChanged: (v) => input = v,
            onOutputMaskChanged: (_) {},
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trackRouting_input_dropdown')));
      await tester.pumpAndSettle();
      // Pick "Input 2" (channel index 1) from the opened menu.
      await tester.tap(find.text('Input 2').last);
      await tester.pumpAndSettle();

      expect(input, 1);
    });
  });
}
