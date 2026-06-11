import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/lane_graph/lane_channel_chip.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('LaneChannelChip', () {
    late SurfaceTheme surface;

    // Pumps a chip and returns the underlying [ChannelChip] so its
    // caller-resolved colour/emphasis can be asserted directly.
    Future<ChannelChip> pumpChip(
      WidgetTester tester, {
      required int channel,
      required List<Lane> lanes,
      required bool output,
      int? focused,
      bool excluded = false,
    }) async {
      await tester.pumpApp(
        Builder(
          builder: (context) {
            surface = context.surface;
            return LaneChannelChip(
              label: output ? 'Out ${channel + 1}' : 'In ${channel + 1}',
              channel: channel,
              lanes: lanes,
              focused: focused,
              output: output,
              excluded: excluded,
              onWire: () {},
            );
          },
        ),
      );
      return tester.widget<ChannelChip>(find.byType(ChannelChip));
    }

    testWidgets('an unused port is neutral accent, not strong, not wired', (
      tester,
    ) async {
      final chip = await pumpChip(
        tester,
        channel: 2,
        lanes: const [Lane(inputChannel: 0)],
        output: false,
      );
      expect(chip.wired, isFalse);
      expect(chip.strong, isFalse);
      expect(chip.color, surface.accent);
    });

    testWidgets('a port used by one unfocused lane wears that lane colour', (
      tester,
    ) async {
      final chip = await pumpChip(
        tester,
        channel: 1,
        lanes: const [Lane(inputChannel: 1)],
        output: false,
      );
      expect(chip.wired, isTrue);
      expect(chip.strong, isFalse);
      expect(chip.color, surface.laneColor(0));
    });

    testWidgets('the focused lane port is strong and lane-coloured', (
      tester,
    ) async {
      final chip = await pumpChip(
        tester,
        channel: 1,
        lanes: const [Lane(inputChannel: 1)],
        focused: 0,
        output: false,
      );
      expect(chip.strong, isTrue);
      expect(chip.color, surface.laneColor(0));
    });

    testWidgets('a port shared by two unfocused lanes is neutral accent', (
      tester,
    ) async {
      // Both lanes route to output 0 (bit 0): shared, so no single owner.
      final chip = await pumpChip(
        tester,
        channel: 0,
        lanes: const [Lane(outputMask: 0x1), Lane(outputMask: 0x1)],
        output: true,
      );
      expect(chip.wired, isTrue);
      expect(chip.strong, isFalse);
      expect(chip.color, surface.accent);
    });

    testWidgets('an excluded port is never wired even when a lane uses it', (
      tester,
    ) async {
      final chip = await pumpChip(
        tester,
        channel: 1,
        lanes: const [Lane(inputChannel: 1)],
        output: false,
        excluded: true,
      );
      expect(chip.excluded, isTrue);
      expect(chip.wired, isFalse);
    });
  });
}
