import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';

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

    test('a gated-off output renders excluded but keeps its route edge (F-11)',
        () {
      // Track plays ONLY to output 1 (bit 1), which is structurally gated off.
      final graph = RoutingGraph.fromTracks(
        tracks: const [Track(outputMask: 0x2)],
        inputChannels: 2,
        outputChannels: 2,
        outputEnabledMask: 0x1, // output 1 disabled
      );

      // The disabled output reuses the excluded (greyed) render.
      expect(graph.outputs[1].excluded, isTrue);
      expect(graph.outputs[0].excluded, isFalse);
      // …yet the track→output edge is STILL drawn, so a lane routed only to a
      // gated output is discoverable rather than silently dropped (F-11).
      final outputEdges = graph.edges
          .where((e) => e.to.kind == RoutingNodeKind.output)
          .toList();
      expect(outputEdges, hasLength(1));
      expect(outputEdges.single.to.index, 1);
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
}
