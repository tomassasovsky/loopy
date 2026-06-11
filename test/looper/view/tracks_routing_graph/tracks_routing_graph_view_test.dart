import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/tracks_routing_graph/tracks_routing_graph_view.dart';
import 'package:loopy/theme/theme.dart';

void main() {
  group('TracksRoutingGraphView', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.bigPicture,
        home: Scaffold(body: child),
      ),
    );

    testWidgets('renders a CustomPaint for the diagram', (tester) async {
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 2,
          outputChannels: 2,
        ),
      );

      expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('routingGraph_view')),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('paints a diagram with an excluded loopback input', (
      tester,
    ) async {
      // Exercises the dimmed/struck-through excluded-node paint path.
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 4,
          outputChannels: 2,
          excludedInputMask: 0x8, // input 4 is loopback
        ),
      );

      expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('arm a track then click an input to connect it', (
      tester,
    ) async {
      int? channel;
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // inputMask 0x1
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      // Clicking a channel before arming a track does nothing.
      await tester.tap(find.byKey(const Key('routingNode_input_1')));
      await tester.pump();
      expect(channel, isNull);

      // Arm the track, then click input 2 (bit 1) to add it.
      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_input_1')));
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x3); // 0x1 | (1 << 1)
    });

    testWidgets('clicking an already-connected channel disconnects it', (
      tester,
    ) async {
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // inputMask 0x1 (input 1 wired)
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (_, m) => mask = m,
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_input_0')));
      await tester.pump();

      expect(mask, 0x0); // 0x1 & ~(1 << 0)
    });

    testWidgets('arm a track then click an output toggles its output', (
      tester,
    ) async {
      int? channel;
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // outputMask 0x3 (out 1 & 2)
          inputChannels: 2,
          outputChannels: 2,
          onOutputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_output_1')));
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x1); // 0x3 & ~(1 << 1)
    });

    testWidgets('a loopback input is not clickable', (tester) async {
      var called = false;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()],
          inputChannels: 2,
          outputChannels: 2,
          excludedInputMask: 0x2, // input 2 is loopback
          onInputMaskChanged: (_, _) => called = true,
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      // The excluded input has no tappable node key.
      expect(find.byKey(const Key('routingNode_input_1')), findsNothing);
      await tester.tap(find.byKey(const Key('routingNode_input_0')));
      await tester.pump();
      // Input 1 (not loopback) still works; the loopback one never fires.
      expect(called, isTrue);
    });

    testWidgets('read-only graph exposes no interactive node keys', (
      tester,
    ) async {
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 2,
          outputChannels: 2,
        ),
      );

      expect(find.byKey(const Key('routingNode_track_0')), findsNothing);
    });
  });
}
