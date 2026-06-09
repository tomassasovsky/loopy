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

    testWidgets('dragging an input onto a track toggles its input routing', (
      tester,
    ) async {
      int? channel;
      int? mask;
      const tracks = [Track()]; // channel 0, inputMask 0x1, outputMask 0x3
      final graph = RoutingGraph.fromTracks(
        tracks: tracks,
        inputChannels: 2,
        outputChannels: 2,
      );

      await pump(
        tester,
        RoutingGraphView(
          tracks: tracks,
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      final rect = tester.getRect(find.byKey(const Key('routingGraph_view')));
      Offset globalOf(RoutingNode node) =>
          rect.topLeft + RoutingGraphView.nodeCenter(node, rect.size, graph);

      // Input 2 (bit 1) is not yet wired; dragging it onto the track adds it.
      final from = globalOf(graph.inputs[1]);
      await tester.dragFrom(from, globalOf(graph.tracks[0]) - from);
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x3); // 0x1 | (1 << 1)
    });

    testWidgets('dragging a track onto an output toggles its output routing', (
      tester,
    ) async {
      int? channel;
      int? mask;
      const tracks = [Track()]; // outputMask 0x3 (out 1 & 2)
      final graph = RoutingGraph.fromTracks(
        tracks: tracks,
        inputChannels: 2,
        outputChannels: 2,
      );

      await pump(
        tester,
        RoutingGraphView(
          tracks: tracks,
          inputChannels: 2,
          outputChannels: 2,
          onOutputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      final rect = tester.getRect(find.byKey(const Key('routingGraph_view')));
      Offset globalOf(RoutingNode node) =>
          rect.topLeft + RoutingGraphView.nodeCenter(node, rect.size, graph);

      // Output 2 (bit 1) is wired; dragging the track onto it removes it.
      final from = globalOf(graph.tracks[0]);
      await tester.dragFrom(from, globalOf(graph.outputs[1]) - from);
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x1); // 0x3 & ~(1 << 1)
    });

    testWidgets('dragging from a loopback input does nothing', (tester) async {
      var called = false;
      const tracks = [Track()];
      final graph = RoutingGraph.fromTracks(
        tracks: tracks,
        inputChannels: 2,
        outputChannels: 2,
        excludedInputMask: 0x2, // input 2 is loopback
      );

      await pump(
        tester,
        RoutingGraphView(
          tracks: tracks,
          inputChannels: 2,
          outputChannels: 2,
          excludedInputMask: 0x2,
          onInputMaskChanged: (_, _) => called = true,
        ),
      );

      final rect = tester.getRect(find.byKey(const Key('routingGraph_view')));
      Offset globalOf(RoutingNode node) =>
          rect.topLeft + RoutingGraphView.nodeCenter(node, rect.size, graph);

      final from = globalOf(graph.inputs[1]); // the loopback input
      await tester.dragFrom(from, globalOf(graph.tracks[0]) - from);
      await tester.pump();

      expect(called, isFalse);
    });
  });

  group('RoutingGraphView.resolveEdit', () {
    const track0 = RoutingNode(
      kind: RoutingNodeKind.track,
      index: 0,
      label: 'Track 1',
    );
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
    const tracks = [Track()]; // inputMask 0x1, outputMask 0x3

    test('input→track adds an unset input bit', () {
      expect(
        RoutingGraphView.resolveEdit(in1, track0, tracks),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x3),
      );
    });

    test('input→track clears an already-set input bit', () {
      expect(
        RoutingGraphView.resolveEdit(in0, track0, tracks),
        const RoutingEdit(isInput: true, channel: 0, mask: 0x0),
      );
    });

    test('is direction-agnostic (track→input resolves the same)', () {
      expect(
        RoutingGraphView.resolveEdit(track0, in1, tracks),
        RoutingGraphView.resolveEdit(in1, track0, tracks),
      );
    });

    test('track→output toggles the output bit', () {
      expect(
        RoutingGraphView.resolveEdit(track0, out1, tracks),
        const RoutingEdit(isInput: false, channel: 0, mask: 0x1),
      );
    });

    test('an excluded input never resolves to an edit', () {
      const excluded = RoutingNode(
        kind: RoutingNodeKind.input,
        index: 1,
        label: 'In 2',
        excluded: true,
      );
      expect(RoutingGraphView.resolveEdit(excluded, track0, tracks), isNull);
    });

    test('a non-track pair (input↔output) resolves to nothing', () {
      expect(RoutingGraphView.resolveEdit(in0, out1, tracks), isNull);
    });

    test('two tracks resolve to nothing', () {
      const track1 = RoutingNode(
        kind: RoutingNodeKind.track,
        index: 1,
        label: 'Track 2',
      );
      expect(RoutingGraphView.resolveEdit(track0, track1, tracks), isNull);
    });

    test('a track index out of range resolves to nothing', () {
      const ghost = RoutingNode(
        kind: RoutingNodeKind.track,
        index: 9,
        label: 'Track 10',
      );
      expect(RoutingGraphView.resolveEdit(ghost, in0, tracks), isNull);
    });
  });
}
