import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/lane_graph/lane_channel_chip.dart';
import 'package:loopy/looper/view/lane_graph/lane_graph_layout.dart';
import 'package:loopy/looper/view/lane_graph/lane_node.dart';
import 'package:loopy/looper/view/lane_graph/lane_panel.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The whole track as one wired graph: hardware inputs on the left, the track's
/// **lanes** stacked in the middle (each a node + its own effect chain), and
/// hardware outputs on the right. Bezier edges show how every lane is wired.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph package (`package:routing_graph`); this view owns only the
/// lane-specific assembly: the geometry ([LaneGraphLayout]), the hardware ports
/// ([LaneChannelChip]), the lane node body ([LaneNode]), and the bottom panel
/// ([LanePanel]). Selection is **parent-owned** ([selectedEffect] +
/// [onSelectEffect]); the widget holds only view-local state (the focused lane
/// and the card being dragged). Every edit is a callback.
class LaneGraphView extends StatefulWidget {
  /// Creates a [LaneGraphView].
  const LaneGraphView({
    required this.lanes,
    required this.inputChannels,
    required this.outputChannels,
    required this.selectedEffect,
    required this.onInputChanged,
    required this.onOutputMaskChanged,
    required this.onVolumeChanged,
    required this.onMuteToggled,
    required this.onAddEffect,
    required this.onSelectEffect,
    required this.onMoveEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    required this.onAddLane,
    required this.onRemoveLane,
    this.excludedInputMask = 0,
    this.addedLatencyMs = 0,
    super.key,
  });

  /// The track's lanes, in lane order.
  final List<Lane> lanes;

  /// Hardware input/output channel counts (`0` when stopped).
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, drawn dimmed and never wired.
  final int excludedInputMask;

  /// The engine's reported added latency (ms) for the octaver monitoring hint.
  final double addedLatencyMs;

  /// The selected (open-in-the-editor) effect, as `(lane, index)`, or null.
  final ({int lane, int index})? selectedEffect;

  /// Sets the single hardware input lane `lane` records (`-1` = none).
  final void Function(int lane, int inputChannel) onInputChanged;

  /// Toggles an output-routing connection for `lane` (reports the new mask).
  final void Function(int lane, int mask) onOutputMaskChanged;

  /// Per-lane mix.
  final void Function(int lane, double volume) onVolumeChanged;
  final void Function(int lane) onMuteToggled;

  /// Effect-chain edits for a lane.
  final void Function(int lane) onAddEffect;
  final void Function(int lane, int? index) onSelectEffect;
  final void Function(int lane, int from, int to) onMoveEffect;
  final void Function(int lane, int index, TrackEffectType type) onSetType;
  final void Function(int lane, int index, int param, double value) onSetParam;
  final void Function(int lane, int index) onRemoveEffect;

  /// Lane stack edits. Any lane can be removed while more than one exists.
  final VoidCallback onAddLane;
  final void Function(int lane) onRemoveLane;

  @override
  State<LaneGraphView> createState() => _LaneGraphViewState();
}

class _LaneGraphViewState extends State<LaneGraphView> {
  GraphCardRef? _dragging;

  /// The lane whose input/output nodes are currently being wired, or null.
  int? _focused;

  @override
  void didUpdateWidget(LaneGraphView old) {
    super.didUpdateWidget(old);
    // A removed lane leaves the focus index dangling past the shrunk list.
    if (_focused != null && _focused! >= widget.lanes.length) _focused = null;
  }

  int get _laneCount => widget.lanes.length;
  int get _inCount => widget.inputChannels > 0 ? widget.inputChannels : 4;
  int get _outCount => widget.outputChannels > 0 ? widget.outputChannels : 2;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final layout = LaneGraphLayout.compute(
      lanes: widget.lanes,
      inCount: _inCount,
      outCount: _outCount,
      excludedMask: widget.excludedInputMask,
      focused: _focused,
      palette: surface.lanePalette,
    );
    return Column(
      children: [
        Expanded(
          child: GraphCanvas(
            width: layout.canvasWidth,
            height: layout.canvasHeight,
            fitIdentity: layout.fitIdentity,
            onTapBackground: (_focused == null && widget.selectedEffect == null)
                ? null
                : () {
                    final selected = widget.selectedEffect;
                    if (selected != null) {
                      widget.onSelectEffect(selected.lane, null);
                    }
                    setState(() => _focused = null);
                  },
            children: [
              Positioned.fill(
                child: CustomPaint(painter: GraphEdgePainter(layout.edges)),
              ),
              for (var c = 0; c < _inCount; c++)
                positionedNode(
                  left: layout.inX,
                  centerY: layout.inY(c),
                  width: LaneGraphLayout.channelChipWidth,
                  height: LaneGraphLayout.channelChipHeight,
                  child: LaneChannelChip(
                    label: l10n.inputChannelLabel(c + 1),
                    channel: c,
                    lanes: widget.lanes,
                    focused: _focused,
                    output: false,
                    excluded: widget.excludedInputMask & (1 << c) != 0,
                    onWire:
                        widget.excludedInputMask & (1 << c) != 0 ||
                            _focused == null
                        ? null
                        : () {
                            final cur = widget.lanes[_focused!].inputChannel;
                            widget.onInputChanged(_focused!, cur == c ? -1 : c);
                          },
                  ),
                ),
              for (var c = 0; c < _outCount; c++)
                positionedNode(
                  left: layout.outX,
                  centerY: layout.outY(c),
                  width: LaneGraphLayout.channelChipWidth,
                  height: LaneGraphLayout.channelChipHeight,
                  child: LaneChannelChip(
                    label: l10n.outputChannelLabel(c + 1),
                    channel: c,
                    lanes: widget.lanes,
                    focused: _focused,
                    output: true,
                    excluded: false,
                    onWire: _focused == null
                        ? null
                        : () => widget.onOutputMaskChanged(
                            _focused!,
                            widget.lanes[_focused!].outputMask ^ (1 << c),
                          ),
                  ),
                ),
              for (var l = 0; l < _laneCount; l++) ...[
                positionedNode(
                  left: layout.laneX,
                  centerY: layout.laneY(l),
                  width: LaneGraphLayout.laneNodeWidth,
                  height: LaneGraphLayout.laneNodeHeight,
                  child: LaneNode(
                    index: l,
                    lane: widget.lanes[l],
                    color: surface.laneColor(l),
                    focused: _focused == l,
                    dim: _focused != null && _focused != l,
                    onTap: () =>
                        setState(() => _focused = _focused == l ? null : l),
                  ),
                ),
                ...buildEffectDropZones(
                  keyPrefix: 'laneGraph',
                  rowId: l,
                  cardXs: layout.cardXs[l],
                  emptyStartX: LaneGraphLayout.cardStartX,
                  rowCenterY: layout.laneY(l),
                  accentColor: surface.accent,
                  onMove: (from, gap) => widget.onMoveEffect(l, from, gap),
                ),
                for (var k = 0; k < layout.cardXs[l].length; k++)
                  positionedNode(
                    left: layout.cardXs[l][k],
                    centerY: layout.laneY(l),
                    width: kRoutingCardWidth,
                    height: kRoutingCardHeight,
                    child: EffectChainCard(
                      keyPrefix: 'laneGraph',
                      label: l10n.effectTypeLabel(
                        widget.lanes[l].effects[k].type,
                      ),
                      accentColor: surface.laneColor(l),
                      selected:
                          widget.selectedEffect?.lane == l &&
                          widget.selectedEffect?.index == k,
                      dragging: _dragging?.rowId == l && _dragging?.index == k,
                      rowId: l,
                      index: k,
                      onTap: () {
                        setState(() => _focused = l);
                        final selected =
                            widget.selectedEffect?.lane == l &&
                            widget.selectedEffect?.index == k;
                        widget.onSelectEffect(l, selected ? null : k);
                      },
                      onDelete: () => widget.onRemoveEffect(l, k),
                      // Keyboard/single-pointer reorder alternative to dragging
                      // (WCAG 2.5.7); hidden at the ends.
                      onMoveLeft: k > 0
                          ? () => widget.onMoveEffect(l, k, k - 1)
                          : null,
                      onMoveRight: k < widget.lanes[l].effects.length - 1
                          ? () => widget.onMoveEffect(l, k, k + 1)
                          : null,
                      onDragStart: () =>
                          setState(() => _dragging = GraphCardRef(l, k)),
                      onDragEnd: () => setState(() => _dragging = null),
                    ),
                  ),
                positionedNode(
                  left: layout.addBtnX(l),
                  centerY: layout.laneY(l),
                  width: kRoutingAddSlot,
                  height: kRoutingAddSlot,
                  child: AddEffectButton(
                    buttonKey: Key('laneGraph_addFx_$l'),
                    accentColor: surface.accent,
                    full: widget.lanes[l].effects.length >= kTrackEffectMax,
                    tooltip: l10n.addEffectToLaneTooltip(l + 1),
                    onAdd: () {
                      setState(() => _focused = l);
                      widget.onAddEffect(l);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        LanePanel(
          laneCount: _laneCount,
          focused: _focused,
          lanes: widget.lanes,
          selectedEffect: widget.selectedEffect,
          onMuteToggled: widget.onMuteToggled,
          onVolumeChanged: widget.onVolumeChanged,
          onRemoveLane: widget.onRemoveLane,
          onAddLane: widget.onAddLane,
          onSetType: widget.onSetType,
          onSetParam: widget.onSetParam,
          onRemoveEffect: widget.onRemoveEffect,
          addedLatencyMs: widget.addedLatencyMs,
        ),
      ],
    );
  }
}
