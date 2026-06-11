import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';
import 'package:loopy/common/routing_graph/graph_edge_painter.dart';
import 'package:loopy/theme/surface_theme.dart';

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

/// The routing change clicking a target channel while a track is armed
/// resolves to: which mask of which track [channel] to set to [mask].
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

/// A whole-system diagram of the current audio routing: hardware inputs on the
/// left, tracks in the middle, hardware outputs on the right, with an edge for
/// every wired input→track and track→output connection. Loopback inputs are
/// shown dimmed and never wired.
///
/// The wires are drawn by the shared routing-graph kit's [GraphEdgePainter];
/// this view keeps its own all-tracks node model, responsive column layout, and
/// arm/hover/target interaction (a different graph from the per-track lane and
/// monitor views, so its rich affordances stay here).
///
/// Read-only by default. Pass [onInputMaskChanged] / [onOutputMaskChanged] to
/// make it editable: click a track to arm it (its connections light up and the
/// channels become targets), then click an input or output to connect or
/// disconnect it. Hovering a node highlights its connections.
class TracksRoutingGraphView extends StatefulWidget {
  /// Creates a [TracksRoutingGraphView].
  const TracksRoutingGraphView({
    required this.tracks,
    required this.inputChannels,
    required this.outputChannels,
    this.excludedInputMask = 0,
    this.trackLabels,
    this.onInputMaskChanged,
    this.onOutputMaskChanged,
    this.initialArmed,
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

  /// Called with `(channel, newMask)` when a click toggles a track's input
  /// routing. When both this and [onOutputMaskChanged] are null the graph is
  /// read-only.
  final void Function(int channel, int mask)? onInputMaskChanged;

  /// Called with `(channel, newMask)` when a click toggles a track's output
  /// routing.
  final void Function(int channel, int mask)? onOutputMaskChanged;

  /// Index in [tracks] to arm initially (e.g. the only track in a single-track
  /// view), so its channels are immediately clickable. `null` starts unarmed.
  final int? initialArmed;

  /// Node box width.
  static const double nodeWidth = 92;

  /// Node box height.
  static const double nodeHeight = 32;

  static const double _rowHeight = 50;
  static const double _topPad = 10;

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

  /// The routing change clicking [target] resolves to for the armed [track], or
  /// null if [target] is not a connectable channel (a track, or an excluded
  /// loopback input). Toggles the corresponding mask bit.
  @visibleForTesting
  static RoutingEdit? editForTarget(Track track, RoutingNode target) {
    final bit = 1 << target.index;
    return switch (target.kind) {
      RoutingNodeKind.input =>
        target.excluded
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
  State<TracksRoutingGraphView> createState() => _TracksRoutingGraphViewState();
}

class _TracksRoutingGraphViewState extends State<TracksRoutingGraphView> {
  /// The armed track's index in [TracksRoutingGraphView.tracks], or null.
  int? _armed;

  @override
  void initState() {
    super.initState();
    _armed = widget.initialArmed;
  }

  /// The node currently under the pointer (drives connection highlighting).
  RoutingNode? _hovered;

  bool get _editable =>
      widget.onInputMaskChanged != null || widget.onOutputMaskChanged != null;

  void _onTrackTap(RoutingNode node) {
    setState(() => _armed = _armed == node.index ? null : node.index);
  }

  void _onChannelTap(RoutingNode node) {
    final armed = _armed;
    if (armed == null || armed >= widget.tracks.length) return;
    if (node.excluded) return;
    final edit = TracksRoutingGraphView.editForTarget(
      widget.tracks[armed],
      node,
    );
    if (edit == null) return;
    if (edit.isInput) {
      widget.onInputMaskChanged?.call(edit.channel, edit.mask);
    } else {
      widget.onOutputMaskChanged?.call(edit.channel, edit.mask);
    }
  }

  void _setHovered(RoutingNode? node) {
    if (_hovered == node) return;
    setState(() => _hovered = node);
  }

  @override
  Widget build(BuildContext context) {
    final graph = RoutingGraph.fromTracks(
      tracks: widget.tracks,
      inputChannels: widget.inputChannels,
      outputChannels: widget.outputChannels,
      excludedInputMask: widget.excludedInputMask,
      trackLabels: widget.trackLabels,
    );
    final height =
        graph.maxColumnLength * TracksRoutingGraphView._rowHeight +
        TracksRoutingGraphView._topPad * 2;

    final armed = _armed;
    final armedNode = (armed != null && armed < graph.tracks.length)
        ? graph.tracks[armed]
        : null;
    // Edges touching the armed track (or, failing that, the hovered node) are
    // drawn bright; everything else dims so the focus stands out.
    final focus = armedNode ?? _hovered;
    final highlighted = focus == null
        ? null
        : graph.edges.where((e) => e.from == focus || e.to == focus).toSet();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, height);
        return SizedBox(
          key: const Key('routingGraph_view'),
          width: double.infinity,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: GraphEdgePainter(_wires(graph, size, highlighted)),
                ),
              ),
              for (final node in [
                ...graph.inputs,
                ...graph.tracks,
                ...graph.outputs,
              ])
                _positionedNode(node, size, graph, armed),
            ],
          ),
        );
      },
    );
  }

  /// Translates the graph's directed connections into kit [GraphEdge]s, fading
  /// any edge that is not in [highlighted] (when a node is armed/hovered).
  List<GraphEdge> _wires(
    RoutingGraph graph,
    Size size,
    Set<RoutingEdge>? highlighted,
  ) {
    Offset center(RoutingNode node) =>
        TracksRoutingGraphView.nodeCenter(node, size, graph);
    const half = TracksRoutingGraphView.nodeWidth / 2;
    return [
      for (final edge in graph.edges)
        GraphEdge(
          Offset(center(edge.from).dx + half, center(edge.from).dy),
          Offset(center(edge.to).dx - half, center(edge.to).dy),
          color: context.surface.accent,
          faded: highlighted != null && !highlighted.contains(edge),
        ),
    ];
  }

  Widget _positionedNode(
    RoutingNode node,
    Size size,
    RoutingGraph graph,
    int? armed,
  ) {
    final center = TracksRoutingGraphView.nodeCenter(node, size, graph);
    final isTrack = node.kind == RoutingNodeKind.track;
    final isArmedTrack = isTrack && node.index == armed;

    // While a track is armed, channels become targets showing their connection
    // state to that track.
    bool? connected;
    var isTarget = false;
    if (armed != null && armed < widget.tracks.length && !isTrack) {
      isTarget = !node.excluded;
      final track = widget.tracks[armed];
      connected = node.kind == RoutingNodeKind.input
          ? track.inputMask & (1 << node.index) != 0
          : track.outputMask & (1 << node.index) != 0;
    }

    return Positioned(
      left: center.dx - TracksRoutingGraphView.nodeWidth / 2,
      top: center.dy - TracksRoutingGraphView.nodeHeight / 2,
      width: TracksRoutingGraphView.nodeWidth,
      height: TracksRoutingGraphView.nodeHeight,
      child: _GraphNode(
        node: node,
        interactive: _editable,
        armed: isArmedTrack,
        isTarget: isTarget,
        connected: connected,
        hovered: _hovered == node,
        onTap: !_editable || node.excluded
            ? null
            : () => isTrack ? _onTrackTap(node) : _onChannelTap(node),
        onHover: _editable && !node.excluded ? _setHovered : null,
      ),
    );
  }
}

/// A single routing-graph node rendered as an interactive widget so it can show
/// hover/armed/target states and a connect/disconnect affordance.
class _GraphNode extends StatelessWidget {
  const _GraphNode({
    required this.node,
    required this.interactive,
    required this.armed,
    required this.isTarget,
    required this.connected,
    required this.hovered,
    required this.onTap,
    required this.onHover,
  });

  final RoutingNode node;
  final bool interactive;
  final bool armed;
  final bool isTarget;
  final bool? connected;
  final bool hovered;
  final VoidCallback? onTap;
  final ValueChanged<RoutingNode?>? onHover;

  @override
  Widget build(BuildContext context) {
    final isTrack = node.kind == RoutingNodeKind.track;

    Color fill;
    Color border;
    var borderWidth = 1.0;
    var textColor = context.surface.textPrimary;

    if (node.excluded) {
      fill = context.surface.cardHigh;
      border = context.surface.line;
      textColor = context.surface.textTertiary;
    } else if (isTrack) {
      fill = context.surface.accent.withValues(alpha: armed ? 0.34 : 0.18);
      border = armed
          ? context.surface.accent
          : context.surface.accent.withValues(alpha: 0.6);
      borderWidth = armed ? 2 : 1;
    } else if (isTarget) {
      // A channel that can be wired to the armed track.
      fill = connected ?? false
          ? context.surface.accent.withValues(alpha: 0.30)
          : context.surface.card;
      border = connected ?? false
          ? context.surface.accent
          : context.surface.accent.withValues(alpha: 0.7);
    } else {
      fill = context.surface.card;
      border = context.surface.line;
      textColor = context.surface.textSecondary;
    }
    if (hovered) {
      border = Color.alphaBlend(Colors.white.withValues(alpha: 0.18), border);
    }

    // On a target while armed, hint the action: + to connect, ✕ to remove.
    final hint = isTarget && hovered
        ? (connected ?? false ? Icons.close : Icons.add)
        : null;

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: borderWidth),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isTrack ? FontWeight.w600 : FontWeight.w500,
                decoration: node.excluded ? TextDecoration.lineThrough : null,
                decorationColor: context.surface.textTertiary,
              ),
            ),
          ),
          if (hint != null)
            Positioned(
              right: 5,
              child: Icon(hint, size: 13, color: textColor),
            ),
        ],
      ),
    );

    if (!interactive || onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover?.call(node),
      onExit: (_) => onHover?.call(null),
      child: GestureDetector(
        key: Key('routingNode_${node.kind.name}_${node.index}'),
        onTap: onTap,
        child: content,
      ),
    );
  }
}
