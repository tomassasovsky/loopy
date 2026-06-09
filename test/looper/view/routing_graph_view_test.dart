import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';

void main() {
  group('RoutingGraph.fromTracks', () {
    test('builds a node per channel and per track', () {
      final graph = RoutingGraph.fromTracks(
        tracks: const [Track(), Track(channel: 1)],
        inputChannels: 4,
        outputChannels: 2,
      );

      expect(graph.inputs, hasLength(4));
      expect(graph.outputs, hasLength(2));
      expect(graph.tracks, hasLength(2));
    });

    test('wires one edge per set input/output bit', () {
      final graph = RoutingGraph.fromTracks(
        tracks: const [
          // in 1 -> track, track -> out 1 & 2
          Track(),
          // in 1 & 2 -> track, track -> out 2
          Track(channel: 1, inputMask: 0x3, outputMask: 0x2),
        ],
        inputChannels: 4,
        outputChannels: 2,
      );

      // Track 0: 1 input edge + 2 output edges = 3.
      // Track 1: 2 input edges + 1 output edge = 3.
      expect(graph.edges, hasLength(6));
    });

    test('never wires an excluded (loopback) input', () {
      final graph = RoutingGraph.fromTracks(
        // Track records from inputs 1 and 2; input 2 (bit 1) is loopback.
        tracks: const [Track(inputMask: 0x3, outputMask: 0x1)],
        inputChannels: 2,
        outputChannels: 1,
        excludedInputMask: 0x2,
      );

      expect(graph.inputs[1].excluded, isTrue);
      // Only in 1 -> track (the loopback bit is dropped); never from input 2.
      final inputEdges = graph.edges
          .where((e) => e.from.kind == RoutingNodeKind.input)
          .toList();
      expect(inputEdges, hasLength(1));
      expect(inputEdges.single.from.index, 0);
    });

    test('derives channel counts from masks when the engine is stopped', () {
      final graph = RoutingGraph.fromTracks(
        // Uses input bit 2 and output bit 3 with no reported channels.
        tracks: const [Track(inputMask: 0x4, outputMask: 0x8)],
        inputChannels: 0,
        outputChannels: 0,
      );

      expect(graph.inputs, hasLength(3));
      expect(graph.outputs, hasLength(4));
    });

    test('uses provided track labels', () {
      final graph = RoutingGraph.fromTracks(
        tracks: const [Track(), Track(channel: 1)],
        inputChannels: 1,
        outputChannels: 2,
        trackLabels: const ['GUITAR', 'VOX'],
      );

      expect(graph.tracks.map((n) => n.label), ['GUITAR', 'VOX']);
    });
  });

  group('RoutingGraphView', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.bigPicture,
        home: Scaffold(body: child),
      ),
    );

    testWidgets('renders a CustomPaint for the diagram', (tester) async {
      await pump(
        tester,
        const RoutingGraphView(
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
        const RoutingGraphView(
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
        RoutingGraphView(
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
        RoutingGraphView(
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
        RoutingGraphView(
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
        RoutingGraphView(
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
        const RoutingGraphView(
          tracks: [Track()],
          inputChannels: 2,
          outputChannels: 2,
        ),
      );

      expect(find.byKey(const Key('routingNode_track_0')), findsNothing);
    });
  });

  group('RoutingGraphView.editForTarget', () {
    const track = Track(); // inputMask 0x1, outputMask 0x3
    const in0 = RoutingNode(
      kind: RoutingNodeKind.input,
      index: 0,
      label: 'In 1',
    );
    const in1 = RoutingNode(
      kind: RoutingNodeKind.input,
      index: 1,
      label: 'In 2',
    );
    const out1 = RoutingNode(
      kind: RoutingNodeKind.output,
      index: 1,
      label: 'Out 2',
    );

    test('adds an unset input bit', () {
      expect(
        RoutingGraphView.editForTarget(track, in1),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x3),
      );
    });

    test('clears an already-set input bit', () {
      expect(
        RoutingGraphView.editForTarget(track, in0),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x0),
      );
    });

    test('toggles an output bit', () {
      expect(
        RoutingGraphView.editForTarget(track, out1),
        const RoutingEdit(isInput: false, channel: 0, mask: 0x1),
      );
    });

    test('an excluded input resolves to nothing', () {
      const excluded = RoutingNode(
        kind: RoutingNodeKind.input,
        index: 1,
        label: 'In 2',
        excluded: true,
      );
      expect(RoutingGraphView.editForTarget(track, excluded), isNull);
    });

    test('a track target resolves to nothing', () {
      const trackNode = RoutingNode(
        kind: RoutingNodeKind.track,
        index: 0,
        label: 'Track 1',
      );
      expect(RoutingGraphView.editForTarget(track, trackNode), isNull);
    });
  });
}
