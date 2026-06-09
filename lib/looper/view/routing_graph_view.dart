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

/// The routing change a drag between two nodes resolves to: which mask of which
/// track [channel] to set to [mask], on the input or output side.
@immutable
class RoutingEdit {
  /// Creates a [RoutingEdit].
  const RoutingEdit({
    required this.isInput,
    required this.channel,
    required this.mask,
  });

  /// Whether the input mask (`true`) or the output mask (`false`) changed.
  final bool isInput;

  /// The track channel whose routing changed.
  final int channel;

  /// The new bitmask value.
  final int mask;

  @override
  bool operator ==(Object other) =>
      other is RoutingEdit &&
      other.isInput == isInput &&
      other.channel == channel &&
      other.mask == mask;

  @override
  int get hashCode => Object.hash(isInput, channel, mask);
}

/// A diagram of the current audio routing: hardware inputs on the left, tracks
/// in the middle, hardware outputs on the right, with an edge for every wired
/// input→track and track→output connection. Loopback inputs are shown dimmed
/// and never wired. Drawn with [CustomPaint].
///
/// Read-only by default. Pass [onInputMaskChanged] / [onOutputMaskChanged] to
/// make it editable: dragging between a track and an input (or an output)
/// toggles that connection, reporting the track channel and its new bitmask.
class RoutingGraphView extends StatefulWidget {
  /// Creates a [RoutingGraphView].
  const RoutingGraphView({
    required this.tracks,
    required this.inputChannels,
    required this.outputChannels,
    this.excludedInputMask = 0,
    this.trackLabels,
    this.onInputMaskChanged,
    this.onOutputMaskChanged,
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

  /// Called with `(channel, newMask)` when a drag toggles a track's input
  /// routing. When both this and [onOutputMaskChanged] are null the graph is
  /// read-only.
  final void Function(int channel, int mask)? onInputMaskChanged;

  /// Called with `(channel, newMask)` when a drag toggles a track's output
  /// routing.
  final void Function(int channel, int mask)? onOutputMaskChanged;

  /// Node box width.
  static const double nodeWidth = 84;

  /// Node box height.
  static const double nodeHeight = 30;

  static const double _rowHeight = 46;
  static const double _topPad = 8;

  /// The center of [node] within a diagram of [size]. Nodes are built in index
  /// order, so `node.index` is its row within the column.
  @visibleForTesting
  static Offset nodeCenter(RoutingNode node, Size size, RoutingGraph graph) {
    final (x, length) = switch (node.kind) {
      RoutingNodeKind.input => (nodeWidth / 2, graph.inputs.length),
      RoutingNodeKind.track => (size.width / 2, graph.tracks.length),
      RoutingNodeKind.output => (
        size.width - nodeWidth / 2,
        graph.outputs.length,
      ),
    };
    final slot = size.height / length;
    return Offset(x, slot * (node.index + 0.5));
  }

  /// The routing change a drag from [a] to [b] resolves to, or null if the pair
  /// is not connectable (not exactly one track end, an excluded input, etc.).
  /// Direction-agnostic.
  @visibleForTesting
  static RoutingEdit? resolveEdit(
    RoutingNode a,
    RoutingNode b,
    List<Track> tracks,
  ) {
    final isTrackA = a.kind == RoutingNodeKind.track;
    final isTrackB = b.kind == RoutingNodeKind.track;
    if (isTrackA == isTrackB) return null; // need exactly one track end
    final trackNode = isTrackA ? a : b;
    final other = isTrackA ? b : a;
    if (trackNode.index >= tracks.length) return null;
    final track = tracks[trackNode.index];
    final bit = 1 << other.index;
    return switch (other.kind) {
      RoutingNodeKind.input =>
        other.excluded
            ? null
            : RoutingEdit(
                isInput: true,
                channel: track.channel,
                mask: track.inputMask ^ bit,
              ),
      RoutingNodeKind.output => RoutingEdit(
        isInput: false,
        channel: track.channel,
        mask: track.outputMask ^ bit,
      ),
      RoutingNodeKind.track => null,
    };
  }

  @override
  State<RoutingGraphView> createState() => _RoutingGraphViewState();
}

class _RoutingGraphViewState extends State<RoutingGraphView> {
  RoutingGraph? _graph;
  Size _size = Size.zero;

  // The in-progress drag: the node it started on and the current pointer.
  RoutingNode? _dragNode;
  Offset? _dragTo;

  bool get _editable =>
      widget.onInputMaskChanged != null || widget.onOutputMaskChanged != null;

  RoutingNode? _nodeAt(Offset position) {
    final graph = _graph;
    if (graph == null) return null;
    for (final node in [...graph.inputs, ...graph.tracks, ...graph.outputs]) {
      final center = RoutingGraphView.nodeCenter(node, _size, graph);
      final rect = Rect.fromCenter(
        center: center,
        width: RoutingGraphView.nodeWidth,
        height: RoutingGraphView.nodeHeight,
      );
      if (rect.contains(position)) return node;
    }
    return null;
  }

  void _onPanStart(DragStartDetails details) {
    final node = _nodeAt(details.localPosition);
    // Excluded inputs can never be wired, so don't start a drag from one.
    if (node == null || node.excluded) return;
    setState(() {
      _dragNode = node;
      _dragTo = details.localPosition;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragNode == null) return;
    setState(() => _dragTo = details.localPosition);
  }

  void _onPanEnd(DragEndDetails details) {
    final from = _dragNode;
    final to = _dragTo == null ? null : _nodeAt(_dragTo!);
    setState(() {
      _dragNode = null;
      _dragTo = null;
    });
    if (from == null || to == null) return;
    final edit = RoutingGraphView.resolveEdit(from, to, widget.tracks);
    if (edit == null) return;
    if (edit.isInput) {
      widget.onInputMaskChanged?.call(edit.channel, edit.mask);
    } else {
      widget.onOutputMaskChanged?.call(edit.channel, edit.mask);
    }
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph = RoutingGraph.fromTracks(
      tracks: widget.tracks,
      inputChannels: widget.inputChannels,
      outputChannels: widget.outputChannels,
      excludedInputMask: widget.excludedInputMask,
      trackLabels: widget.trackLabels,
    );
    final height =
        graph.maxColumnLength * RoutingGraphView._rowHeight +
        RoutingGraphView._topPad * 2;

    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, height);
        final pendingFrom = _dragNode == null
            ? null
            : RoutingGraphView.nodeCenter(_dragNode!, _size, graph);
        final painter = CustomPaint(
          size: _size,
          painter: _RoutingGraphPainter(
            graph: graph,
            pendingFrom: pendingFrom,
            pendingTo: _dragNode == null ? null : _dragTo,
          ),
        );
        return SizedBox(
          key: const Key('routingGraph_view'),
          width: double.infinity,
          height: height,
          child: _editable
              ? GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: painter,
                )
              : painter,
        );
      },
    );
  }
}

class _RoutingGraphPainter extends CustomPainter {
  _RoutingGraphPainter({
    required this.graph,
    this.pendingFrom,
    this.pendingTo,
  });

  final RoutingGraph graph;

  /// While a connection is being dragged, the source node center and the
  /// current pointer; a guide line is drawn between them.
  final Offset? pendingFrom;
  final Offset? pendingTo;

  static const double _nodeWidth = RoutingGraphView.nodeWidth;
  static const double _nodeHeight = RoutingGraphView.nodeHeight;

  @override
  void paint(Canvas canvas, Size size) {
    Offset center(RoutingNode node) =>
        RoutingGraphView.nodeCenter(node, size, graph);

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

    // The in-progress drag guide.
    if (pendingFrom != null && pendingTo != null) {
      canvas.drawLine(
        pendingFrom!,
        pendingTo!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = SetupSurfaceColors.accent,
      );
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
      oldDelegate.graph != graph ||
      oldDelegate.pendingFrom != pendingFrom ||
      oldDelegate.pendingTo != pendingTo;
}
