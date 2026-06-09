import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

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

/// The read-only routing graph derived from the tracks' input/output masks:
/// hardware inputs (left) → tracks (middle) → hardware outputs (right).
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
    List<String>? trackLabels,
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
          label: 'In ${c + 1}',
          excluded: excludedInputMask & (1 << c) != 0,
        ),
    ];
    final outputNodes = [
      for (var c = 0; c < outCount; c++)
        RoutingNode(
          kind: RoutingNodeKind.output,
          index: c,
          label: 'Out ${c + 1}',
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
              : 'Track ${tracks[i].channel + 1}',
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

/// A read-only diagram of the current audio routing: hardware inputs on the
/// left, tracks in the middle, hardware outputs on the right, with an edge for
/// every wired input→track and track→output connection. Loopback inputs are
/// shown dimmed and never wired. Drawn with [CustomPaint] — no editing.
class RoutingGraphView extends StatelessWidget {
  /// Creates a [RoutingGraphView].
  const RoutingGraphView({
    required this.tracks,
    required this.inputChannels,
    required this.outputChannels,
    this.excludedInputMask = 0,
    this.trackLabels,
    super.key,
  });

  /// The tracks whose routing is drawn.
  final List<Track> tracks;

  /// Number of available hardware input channels (`0` when stopped).
  final int inputChannels;

  /// Number of available hardware output channels (`0` when stopped).
  final int outputChannels;

  /// Bitmask of loopback input channels, drawn dimmed and never wired.
  final int excludedInputMask;

  /// Optional per-track labels (e.g. user track names); defaults to `Track N`.
  final List<String>? trackLabels;

  static const double _rowHeight = 46;
  static const double _topPad = 8;

  @override
  Widget build(BuildContext context) {
    final graph = RoutingGraph.fromTracks(
      tracks: tracks,
      inputChannels: inputChannels,
      outputChannels: outputChannels,
      excludedInputMask: excludedInputMask,
      trackLabels: trackLabels,
    );
    final height = graph.maxColumnLength * _rowHeight + _topPad * 2;
    return SizedBox(
      key: const Key('routingGraph_view'),
      width: double.infinity,
      height: height,
      child: CustomPaint(painter: _RoutingGraphPainter(graph)),
    );
  }
}

class _RoutingGraphPainter extends CustomPainter {
  _RoutingGraphPainter(this.graph);

  final RoutingGraph graph;

  static const double _nodeWidth = 84;
  static const double _nodeHeight = 30;

  @override
  void paint(Canvas canvas, Size size) {
    Offset center(RoutingNode node) {
      // Nodes are built in index order, so node.index is its row in the column.
      final (x, length) = switch (node.kind) {
        RoutingNodeKind.input => (_nodeWidth / 2, graph.inputs.length),
        RoutingNodeKind.track => (size.width / 2, graph.tracks.length),
        RoutingNodeKind.output => (
          size.width - _nodeWidth / 2,
          graph.outputs.length,
        ),
      };
      final slot = size.height / length;
      return Offset(x, slot * (node.index + 0.5));
    }

    // Edges behind the nodes.
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = SetupSurfaceColors.accent.withValues(alpha: 0.65);
    for (final edge in graph.edges) {
      final from = center(edge.from);
      final to = center(edge.to);
      final start = Offset(from.dx + _nodeWidth / 2, from.dy);
      final end = Offset(to.dx - _nodeWidth / 2, to.dy);
      final dx = (end.dx - start.dx) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx + dx, start.dy, end.dx - dx, end.dy, end.dx, end.dy);
      canvas.drawPath(path, edgePaint);
    }

    for (final node in [...graph.inputs, ...graph.tracks, ...graph.outputs]) {
      _paintNode(canvas, center(node), node);
    }
  }

  void _paintNode(Canvas canvas, Offset center, RoutingNode node) {
    final rect = Rect.fromCenter(
      center: center,
      width: _nodeWidth,
      height: _nodeHeight,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    final isTrack = node.kind == RoutingNodeKind.track;
    final fill = node.excluded
        ? SetupSurfaceColors.cardHi
        : isTrack
        ? SetupSurfaceColors.accent.withValues(alpha: 0.18)
        : SetupSurfaceColors.card;
    canvas
      ..drawRRect(rrect, Paint()..color = fill)
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = node.excluded
              ? SetupSurfaceColors.line
              : isTrack
              ? SetupSurfaceColors.accent.withValues(alpha: 0.6)
              : SetupSurfaceColors.line,
      );

    final painter = TextPainter(
      text: TextSpan(
        text: node.label,
        style: TextStyle(
          color: node.excluded ? SetupSurfaceColors.t3 : SetupSurfaceColors.t1,
          fontSize: 12,
          fontWeight: isTrack ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: _nodeWidth - 10);
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );

    // A struck-through node marks an excluded (loopback) input — never wired.
    if (node.excluded) {
      canvas.drawLine(
        Offset(rect.left + 8, center.dy),
        Offset(rect.right - 8, center.dy),
        Paint()
          ..strokeWidth = 1
          ..color = SetupSurfaceColors.t3,
      );
    }
  }

  @override
  bool shouldRepaint(_RoutingGraphPainter oldDelegate) =>
      oldDelegate.graph != graph;
}
