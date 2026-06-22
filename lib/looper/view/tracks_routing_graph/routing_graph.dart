import 'package:flutter/foundation.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/gen/app_localizations.dart';

/// Which column of the routing graph a node belongs to.
enum RoutingNodeKind {
  /// A hardware input channel (left column).
  input,

  /// A looper track (middle column).
  track,

  /// A hardware output channel (right column).
  output,
}

/// A single node in the routing graph: an input channel, a track, or an output
/// channel.
@immutable
class RoutingNode {
  /// Creates a [RoutingNode].
  const RoutingNode({
    required this.kind,
    required this.index,
    required this.label,
    this.excluded = false,
  });

  /// Which column this node belongs to.
  final RoutingNodeKind kind;

  /// Channel index (for inputs/outputs) or track index (for tracks).
  final int index;

  /// Display label, e.g. `In 1`, `Track 2`, `Out 3`.
  final String label;

  /// Whether this is an excluded (loopback) input: shown dimmed, never wired.
  final bool excluded;

  @override
  bool operator ==(Object other) =>
      other is RoutingNode &&
      other.kind == kind &&
      other.index == index &&
      other.label == label &&
      other.excluded == excluded;

  @override
  int get hashCode => Object.hash(kind, index, label, excluded);
}

/// A directed connection between two [RoutingNode]s (input→track or track→
/// output).
@immutable
class RoutingEdge {
  /// Creates a [RoutingEdge].
  const RoutingEdge({required this.from, required this.to});

  /// Source node.
  final RoutingNode from;

  /// Destination node.
  final RoutingNode to;

  @override
  bool operator ==(Object other) =>
      other is RoutingEdge && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// The routing graph derived from the tracks' input/output masks: hardware
/// inputs (left) → tracks (middle) → hardware outputs (right).
@immutable
class RoutingGraph {
  /// Creates a [RoutingGraph] from already-built columns and edges.
  const RoutingGraph({
    required this.inputs,
    required this.tracks,
    required this.outputs,
    required this.edges,
  });

  /// Builds the graph from [tracks] and the available hardware channel counts.
  ///
  /// When the engine is stopped the channel counts are `0`; the counts are then
  /// derived from the bits actually used by the tracks (and the excluded mask)
  /// so the diagram still reflects the routing.
  factory RoutingGraph.fromTracks({
    required List<Track> tracks,
    required int inputChannels,
    required int outputChannels,
    int excludedInputMask = 0,
    int outputEnabledMask = 0xFFFFFFFF,
    List<String>? trackLabels,
    AppLocalizations? l10n,
  }) {
    final inCount = inputChannels > 0
        ? inputChannels
        : _bitsNeeded([for (final t in tracks) t.inputMask, excludedInputMask]);
    final outCount = outputChannels > 0
        ? outputChannels
        : _bitsNeeded([for (final t in tracks) t.outputMask], min: 2);

    final inputNodes = [
      for (var c = 0; c < inCount; c++)
        RoutingNode(
          kind: RoutingNodeKind.input,
          index: c,
          label: l10n?.inputChannelLabel(c + 1) ?? 'In ${c + 1}',
          excluded: excludedInputMask & (1 << c) != 0,
        ),
    ];
    final outputNodes = [
      for (var c = 0; c < outCount; c++)
        RoutingNode(
          kind: RoutingNodeKind.output,
          index: c,
          label: l10n?.outputChannelLabel(c + 1) ?? 'Out ${c + 1}',
          // A structurally-gated-off output reuses the `excluded` render
          // (greyed, line-through, non-targetable). Its stored route edges are
          // still drawn (below) so a lane routed only here stays discoverable.
          excluded: outputEnabledMask & (1 << c) == 0,
        ),
    ];
    final trackNodes = [
      for (var i = 0; i < tracks.length; i++)
        RoutingNode(
          kind: RoutingNodeKind.track,
          index: i,
          // Labels (e.g. user track names) are channel-indexed, so look them up
          // by the track's channel rather than its position in the list.
          label: trackLabels != null && tracks[i].channel < trackLabels.length
              ? trackLabels[tracks[i].channel]
              : l10n?.trackNumberLabel(tracks[i].channel + 1) ??
                    'Track ${tracks[i].channel + 1}',
        ),
    ];

    final edges = <RoutingEdge>[];
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final trackNode = trackNodes[i];
      for (final input in inputNodes) {
        // Loopback inputs are never a record source, so never an edge.
        if (input.excluded) continue;
        if (track.inputMask & (1 << input.index) != 0) {
          edges.add(RoutingEdge(from: input, to: trackNode));
        }
      }
      for (final output in outputNodes) {
        if (track.outputMask & (1 << output.index) != 0) {
          edges.add(RoutingEdge(from: trackNode, to: output));
        }
      }
    }

    return RoutingGraph(
      inputs: inputNodes,
      tracks: trackNodes,
      outputs: outputNodes,
      edges: edges,
    );
  }

  /// Input channel nodes (left column).
  final List<RoutingNode> inputs;

  /// Track nodes (middle column).
  final List<RoutingNode> tracks;

  /// Output channel nodes (right column).
  final List<RoutingNode> outputs;

  /// Directed connections between nodes.
  final List<RoutingEdge> edges;

  /// Tallest column, used to size the diagram.
  int get maxColumnLength => [
    inputs.length,
    tracks.length,
    outputs.length,
  ].reduce((a, b) => a > b ? a : b);

  @override
  bool operator ==(Object other) =>
      other is RoutingGraph &&
      listEquals(other.inputs, inputs) &&
      listEquals(other.tracks, tracks) &&
      listEquals(other.outputs, outputs) &&
      listEquals(other.edges, edges);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(inputs),
    Object.hashAll(tracks),
    Object.hashAll(outputs),
    Object.hashAll(edges),
  );

  static int _bitsNeeded(List<int> masks, {int min = 1}) {
    var bits = min;
    for (final mask in masks) {
      if (mask.bitLength > bits) bits = mask.bitLength;
    }
    return bits;
  }
}
