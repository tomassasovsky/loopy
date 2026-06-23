import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/tracks_routing_graph/graph_node.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_edit.dart';
import 'package:loopy/looper/view/tracks_routing_graph/routing_graph.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// A whole-system diagram of the current audio routing: hardware inputs on the
/// left, tracks in the middle, hardware outputs on the right, with an edge for
/// every wired input→track and track→output connection. Loopback inputs are
/// shown dimmed and never wired.
///
/// The wires are drawn by the shared routing-graph kit's [GraphEdgePainter];
/// this view keeps its own all-tracks node model ([RoutingGraph]), responsive
/// column layout, and arm/hover/target interaction (a different graph from the
/// per-track lane and monitor views, so its rich affordances stay here).
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
    this.outputEnabledMask = 0xFFFFFFFF,
    this.trackLabels,
    this.onInputMaskChanged,
    this.onOutputMaskChanged,
    this.onOutputEnabledToggled,
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

  /// Structural output gate: bit c set => output c is enabled. A gated-off
  /// output is drawn greyed (line-through) and is not a wiring target, but its
  /// stored route edges still draw so a lane routed only there is discoverable.
  final int outputEnabledMask;

  /// Optional per-track labels (e.g. user track names); defaults to `Track N`.
  final List<String>? trackLabels;

  /// Called with `(channel, newMask)` when a click toggles a track's input
  /// routing. When both this and [onOutputMaskChanged] are null the graph is
  /// read-only.
  final void Function(int channel, int mask)? onInputMaskChanged;

  /// Called with `(channel, newMask)` when a click toggles a track's output
  /// routing.
  final void Function(int channel, int mask)? onOutputMaskChanged;

  /// Called with `(output, enabled)` when a tap toggles an output's structural
  /// gate. With no track armed, tapping a live output disables it; tapping a
  /// gated-off (greyed) output always re-enables it. Null leaves the gate
  /// read-only.
  final void Function(int output, {required bool enabled})?
  onOutputEnabledToggled;

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
      widget.onInputMaskChanged != null ||
      widget.onOutputMaskChanged != null ||
      widget.onOutputEnabledToggled != null;

  /// Whether [node] is a structurally-gateable output (the toggle is wired).
  bool _gateable(RoutingNode node) =>
      node.kind == RoutingNodeKind.output &&
      widget.onOutputEnabledToggled != null;

  /// The tap handler for [node] given the current [armed] track, or null when
  /// the node is inert. Output gating takes precedence over wiring: a gated-off
  /// output re-enables on tap; a live output with no armed track toggles off;
  /// otherwise an armed track wires it.
  VoidCallback? _tapHandler(RoutingNode node, int? armed) {
    if (!_editable) return null;
    if (_gateable(node)) {
      if (node.excluded) {
        return () => widget.onOutputEnabledToggled!(node.index, enabled: true);
      }
      if (armed == null || armed >= widget.tracks.length) {
        return () => widget.onOutputEnabledToggled!(node.index, enabled: false);
      }
      return () => _onChannelTap(node);
    }
    if (node.excluded) return null; // loopback input: inert
    return () => node.kind == RoutingNodeKind.track
        ? _onTrackTap(node)
        : _onChannelTap(node);
  }

  void _onTrackTap(RoutingNode node) {
    setState(() => _armed = _armed == node.index ? null : node.index);
  }

  void _onChannelTap(RoutingNode node) {
    final armed = _armed;
    if (armed == null || armed >= widget.tracks.length) return;
    // Excluded nodes never reach here (the call site passes onTap: null), and
    // RoutingEdit.forTarget returns null for them anyway.
    final edit = RoutingEdit.forTarget(widget.tracks[armed], node);
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

  /// The armed/target/connected visual state of [node] (pure data; the node
  /// widget renders it). `connected` is null unless [node] is a channel target
  /// of the armed track.
  ({bool isArmedTrack, bool isTarget, bool? connected}) _nodeState(
    RoutingNode node,
    int? armed,
  ) {
    final isTrack = node.kind == RoutingNodeKind.track;
    final isArmedTrack = isTrack && node.index == armed;
    if (armed == null || armed >= widget.tracks.length || isTrack) {
      return (isArmedTrack: isArmedTrack, isTarget: false, connected: null);
    }
    // While a track is armed, channels become targets showing their connection
    // state to that track.
    final track = widget.tracks[armed];
    final connected = node.kind == RoutingNodeKind.input
        ? track.inputMask & (1 << node.index) != 0
        : track.outputMask & (1 << node.index) != 0;
    return (
      isArmedTrack: isArmedTrack,
      isTarget: !node.excluded,
      connected: connected,
    );
  }

  @override
  Widget build(BuildContext context) {
    final graph = RoutingGraph.fromTracks(
      tracks: widget.tracks,
      inputChannels: widget.inputChannels,
      outputChannels: widget.outputChannels,
      excludedInputMask: widget.excludedInputMask,
      outputEnabledMask: widget.outputEnabledMask,
      trackLabels: widget.trackLabels,
      l10n: context.l10n,
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

    final nodes = [...graph.inputs, ...graph.tracks, ...graph.outputs];
    final states = {for (final node in nodes) node: _nodeState(node, armed)};

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, height);
        final centers = {
          for (final node in nodes)
            node: TracksRoutingGraphView.nodeCenter(node, size, graph),
        };
        return SizedBox(
          key: const Key('routingGraph_view'),
          width: double.infinity,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: GraphEdgePainter(
                    _wires(graph, centers, highlighted),
                  ),
                ),
              ),
              for (final node in nodes)
                Positioned(
                  left:
                      centers[node]!.dx - TracksRoutingGraphView.nodeWidth / 2,
                  top:
                      centers[node]!.dy - TracksRoutingGraphView.nodeHeight / 2,
                  width: TracksRoutingGraphView.nodeWidth,
                  height: TracksRoutingGraphView.nodeHeight,
                  child: RoutingGraphNode(
                    node: node,
                    interactive: _editable,
                    armed: states[node]!.isArmedTrack,
                    isTarget: states[node]!.isTarget,
                    connected: states[node]!.connected,
                    hovered: _hovered == node,
                    gateLabel: _gateable(node)
                        ? (node.excluded
                              ? context.l10n.a11yOutputDisabledEnable(
                                  node.index + 1,
                                )
                              : context.l10n.a11yOutputEnabledDisable(
                                  node.index + 1,
                                ))
                        : null,
                    onTap: _tapHandler(node, armed),
                    onHover: _editable && (!node.excluded || _gateable(node))
                        ? _setHovered
                        : null,
                  ),
                ),
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
    Map<RoutingNode, Offset> centers,
    Set<RoutingEdge>? highlighted,
  ) {
    const half = TracksRoutingGraphView.nodeWidth / 2;
    return [
      for (final edge in graph.edges)
        GraphEdge(
          Offset(centers[edge.from]!.dx + half, centers[edge.from]!.dy),
          Offset(centers[edge.to]!.dx - half, centers[edge.to]!.dy),
          color: context.surface.accent,
          faded: highlighted != null && !highlighted.contains(edge),
        ),
    ];
  }
}
