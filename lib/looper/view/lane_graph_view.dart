import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/effect_params_editor.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// The whole track as one wired graph: hardware inputs on the left, the track's
/// **lanes** stacked in the middle (each a node + its own effect chain), and
/// hardware outputs on the right. Bezier edges show how every lane is wired.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph package (`package:routing_graph`); this view owns only the
/// lane-specific
/// assembly: the layout geometry ([_LaneLayout]), the lane node body
/// ([_LaneNode]), and the bottom panel ([_LanePanel]). Selection is
/// **parent-owned** ([selectedEffect] + [onSelectEffect]); the widget holds
/// only view-local state (zoom, focus). Every edit is a callback.
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
    super.key,
  });

  /// The track's lanes, in lane order.
  final List<Lane> lanes;

  /// Hardware input/output channel counts (`0` when stopped).
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, drawn dimmed and never wired.
  final int excludedInputMask;

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
    final surface = context.surface;
    final layout = _LaneLayout.compute(
      lanes: widget.lanes,
      inCount: _inCount,
      outCount: _outCount,
      excludedMask: widget.excludedInputMask,
      focused: _focused,
      palette: surface.lanePalette,
    );
    return Column(
      children: [
        Expanded(child: _canvas(layout, surface)),
        _LanePanel(
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
        ),
      ],
    );
  }

  // ---- canvas ----

  Widget _canvas(_LaneLayout layout, SurfaceTheme surface) {
    return GraphCanvas(
      width: layout.canvasW,
      height: layout.canvasH,
      fitIdentity: layout.fitIdentity,
      children: [
        Positioned.fill(
          child: CustomPaint(painter: GraphEdgePainter(layout.edges)),
        ),
        for (var c = 0; c < _inCount; c++) _inChip(layout, c, surface),
        for (var c = 0; c < _outCount; c++) _outChip(layout, c, surface),
        for (var l = 0; l < _laneCount; l++) ...[
          positionedNode(
            left: layout.laneX,
            centerY: layout.laneY(l),
            width: _LaneLayout.laneW,
            height: _LaneLayout.laneH,
            child: _LaneNode(
              index: l,
              lane: widget.lanes[l],
              color: surface.laneColor(l),
              focused: _focused == l,
              dim: _focused != null && _focused != l,
              onTap: () => setState(() => _focused = _focused == l ? null : l),
            ),
          ),
          ...buildEffectDropZones(
            keyPrefix: 'laneGraph',
            rowId: l,
            cardXs: layout.cardXs[l],
            emptyStartX: _LaneLayout.cardStartX,
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
              child: _card(l, k, surface),
            ),
          positionedNode(
            left: layout.addBtnX(l),
            centerY: layout.laneY(l),
            width: kRoutingAddSlot,
            height: kRoutingAddSlot,
            child: _addBtn(l, surface),
          ),
        ],
      ],
    );
  }

  // ---- nodes ----

  /// Lanes recording hardware input [c] / playing to hardware output [c].
  List<int> _lanesUsing(int c, {required bool output}) => [
    for (var l = 0; l < _laneCount; l++)
      if (output
          ? widget.lanes[l].outputMask & (1 << c) != 0
          : widget.lanes[l].inputChannel == c)
        l,
  ];

  /// Strong when the focused lane uses this port; coloured by its single user
  /// (or neutral accent if shared); dim when unused.
  Color _portColor(
    List<int> users,
    SurfaceTheme surface, {
    required bool strong,
  }) => strong
      ? surface.laneColor(_focused!)
      : users.length == 1
      ? surface.laneColor(users.first)
      : surface.accent;

  Widget _inChip(_LaneLayout layout, int c, SurfaceTheme surface) {
    final excluded = widget.excludedInputMask & (1 << c) != 0;
    final users = excluded ? const <int>[] : _lanesUsing(c, output: false);
    final strong = _focused != null && users.contains(_focused);
    return positionedNode(
      left: layout.inX,
      centerY: layout.inY(c),
      width: _LaneLayout.chW,
      height: _LaneLayout.chH,
      child: ChannelChip(
        key: Key('laneGraph_in_$c'),
        label: 'In ${c + 1}',
        color: _portColor(users, surface, strong: strong),
        strong: strong,
        wired: users.isNotEmpty,
        excluded: excluded,
        onTap: excluded || _focused == null
            ? null
            : () {
                final cur = widget.lanes[_focused!].inputChannel;
                widget.onInputChanged(_focused!, cur == c ? -1 : c);
              },
      ),
    );
  }

  Widget _outChip(_LaneLayout layout, int c, SurfaceTheme surface) {
    final users = _lanesUsing(c, output: true);
    final strong = _focused != null && users.contains(_focused);
    return positionedNode(
      left: layout.outX,
      centerY: layout.outY(c),
      width: _LaneLayout.chW,
      height: _LaneLayout.chH,
      child: ChannelChip(
        key: Key('laneGraph_out_$c'),
        label: 'Out ${c + 1}',
        color: _portColor(users, surface, strong: strong),
        strong: strong,
        wired: users.isNotEmpty,
        excluded: false,
        onTap: _focused == null
            ? null
            : () => widget.onOutputMaskChanged(
                _focused!,
                widget.lanes[_focused!].outputMask ^ (1 << c),
              ),
      ),
    );
  }

  Widget _card(int l, int k, SurfaceTheme surface) {
    final fx = widget.lanes[l].effects[k];
    final selected =
        widget.selectedEffect?.lane == l && widget.selectedEffect?.index == k;
    return EffectChainCard(
      keyPrefix: 'laneGraph',
      label: fx.type.label,
      accentColor: surface.laneColor(l),
      selected: selected,
      dragging: _dragging?.rowId == l && _dragging?.index == k,
      rowId: l,
      index: k,
      onTap: () {
        setState(() => _focused = l);
        widget.onSelectEffect(l, selected ? null : k);
      },
      onDelete: () => widget.onRemoveEffect(l, k),
      onDragStart: () => setState(() => _dragging = GraphCardRef(l, k)),
      onDragEnd: () => setState(() => _dragging = null),
    );
  }

  Widget _addBtn(int l, SurfaceTheme surface) {
    return AddEffectButton(
      buttonKey: Key('laneGraph_addFx_$l'),
      accentColor: surface.accent,
      full: widget.lanes[l].effects.length >= kTrackEffectMax,
      tooltip: 'Add effect to lane ${l + 1}',
      onAdd: () {
        setState(() => _focused = l);
        widget.onAddEffect(l);
      },
    );
  }
}

// ===========================================================================
// Layout
// ===========================================================================

/// Pure geometry for one frame of the lane graph: node positions, card
/// positions, and the wires — computed once per build so the widget tree is
/// plain assembly.
@immutable
class _LaneLayout {
  const _LaneLayout._({
    required this.cardXs,
    required this.edges,
    required this.canvasW,
    required this.canvasH,
    required this.inX,
    required this.laneX,
    required this.outX,
    required int inCount,
    required int outCount,
    required int laneCount,
    required double lanesTop,
  }) : _inCount = inCount,
       _outCount = outCount,
       _laneCount = laneCount,
       _lanesTop = lanesTop;

  factory _LaneLayout.compute({
    required List<Lane> lanes,
    required int inCount,
    required int outCount,
    required int excludedMask,
    required int? focused,
    required List<Color> palette,
  }) {
    const inX = pad;
    const laneX = inX + chW + fan;
    const cardStartX = laneX + laneW + gap;
    final laneCount = lanes.length;

    final cardXs = [
      for (final lane in lanes)
        cardColumnXs(
          startX: cardStartX,
          count: lane.effects.length,
          cardW: cardW,
          gap: gap,
        ),
    ];
    double addBtnXFor(int l) =>
        cardXs[l].isEmpty ? cardStartX : cardXs[l].last + cardW + gap;
    var widestRight = cardStartX;
    for (var l = 0; l < laneCount; l++) {
      widestRight = widestRight > addBtnXFor(l) + addW
          ? widestRight
          : addBtnXFor(l) + addW;
    }
    final outX = widestRight + fan;
    final railX = outX - fan;
    final canvasW = outX + chW + pad;

    final lanesBlockH = laneCount * laneRowH;
    final channelsH = (inCount > outCount ? inCount : outCount) * chRowH;
    final canvasH =
        (lanesBlockH > channelsH ? lanesBlockH : channelsH) + pad * 2;
    final lanesTop = (canvasH - lanesBlockH) / 2;

    double laneYAt(int l) => lanesTop + l * laneRowH + laneRowH / 2;
    double chYAt(int i, int count) => canvasH / count * (i + 0.5);
    Color laneColorAt(int l) => palette[l % palette.length];

    final edges = <GraphEdge>[];
    for (var l = 0; l < laneCount; l++) {
      final lane = lanes[l];
      final y = laneYAt(l);
      final color = laneColorAt(l);
      final faded = focused != null && focused != l;
      // input -> lane
      final c = lane.inputChannel;
      if (c >= 0 && c < inCount && excludedMask & (1 << c) == 0) {
        edges.add(
          GraphEdge(
            Offset(inX + chW, chYAt(c, inCount)),
            Offset(laneX, y),
            color: color,
            faded: faded,
          ),
        );
      }
      final xs = cardXs[l];
      edges.addAll(
        chainEdges(
          nodeRight: laneX + laneW,
          y: y,
          cardXs: xs,
          cardW: cardW,
          color: color,
          faded: faded,
        ),
      );
      final rightX = xs.isEmpty ? laneX + laneW : xs.last + cardW;
      edges.addAll(
        fanEdges(
          sends: [
            GraphSend(
              originX: rightX,
              originY: y,
              mask: lane.outputMask,
              color: color,
            ),
          ],
          railX: railX,
          outX: outX,
          outCount: outCount,
          outY: chYAt,
          faded: faded,
        ),
      );
    }

    return _LaneLayout._(
      cardXs: cardXs,
      edges: edges,
      canvasW: canvasW,
      canvasH: canvasH,
      inX: inX,
      laneX: laneX,
      outX: outX,
      inCount: inCount,
      outCount: outCount,
      laneCount: laneCount,
      lanesTop: lanesTop,
    );
  }

  // Geometry constants. The card footprint comes from the shared kit metrics.
  static const double chW = 54;
  static const double chH = 24;
  static const double laneW = 120;
  static const double laneH = 50;
  static const double cardW = kRoutingCardWidth;
  static const double gap = kRoutingCardGap;
  static const double fan = 92;
  static const double addW = kRoutingAddSlot;
  static const double laneRowH = 84;
  static const double chRowH = 32;
  static const double pad = 16;

  /// The x of the first effect card (also the empty-chain drop spot).
  static const double cardStartX = pad + chW + fan + laneW + gap;

  /// Per lane: the x of each effect card.
  final List<List<double>> cardXs;

  /// The wires to paint.
  final List<GraphEdge> edges;

  final double canvasW;
  final double canvasH;
  final double inX;
  final double laneX;
  final double outX;

  final int _inCount;
  final int _outCount;
  final int _laneCount;
  final double _lanesTop;

  double laneY(int l) => _lanesTop + l * laneRowH + laneRowH / 2;
  double inY(int c) => canvasH / _inCount * (c + 0.5);
  double outY(int c) => canvasH / _outCount * (c + 0.5);
  double addBtnX(int l) =>
      cardXs[l].isEmpty ? cardStartX : cardXs[l].last + cardW + gap;

  /// Re-fit identity: a structural value list (compared with `listEquals`).
  List<Object?> get fitIdentity => [
    _laneCount,
    for (final xs in cardXs) xs.length,
    _inCount,
    _outCount,
  ];
}

// ===========================================================================
// Lane node + bottom panel
// ===========================================================================

/// A lane's node: its name, mute icon, and a read-only volume level. Tapping it
/// focuses the lane (so inputs/outputs become wirable).
class _LaneNode extends StatelessWidget {
  const _LaneNode({
    required this.index,
    required this.lane,
    required this.color,
    required this.focused,
    required this.dim,
    required this.onTap,
  });

  final int index;
  final Lane lane;
  final Color color;
  final bool focused;
  final bool dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('laneGraph_laneNode_$index'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: focused ? 0.30 : 0.16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: dim ? color.withValues(alpha: 0.5) : color,
              width: focused ? 2.5 : 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    lane.muted ? Icons.volume_off : Icons.volume_up,
                    size: 13,
                    color: lane.muted
                        ? surface.textTertiary
                        : surface.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Lane ${index + 1}',
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: LinearProgressIndicator(
                    value: lane.muted ? 0 : lane.volume.clamp(0.0, 1.0),
                    backgroundColor: surface.line,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The docked controls below the canvas: the focused lane's vol/mute/remove,
/// the selected effect's editor, and the add-lane button.
class _LanePanel extends StatelessWidget {
  const _LanePanel({
    required this.laneCount,
    required this.focused,
    required this.lanes,
    required this.selectedEffect,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onRemoveLane,
    required this.onAddLane,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
  });

  final int laneCount;
  final int? focused;
  final List<Lane> lanes;
  final ({int lane, int index})? selectedEffect;
  final void Function(int lane) onMuteToggled;
  final void Function(int lane, double volume) onVolumeChanged;
  final void Function(int lane) onRemoveLane;
  final VoidCallback onAddLane;
  final void Function(int lane, int index, TrackEffectType type) onSetType;
  final void Function(int lane, int index, int param, double value) onSetParam;
  final void Function(int lane, int index) onRemoveEffect;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final f = focused;
    final sel = selectedEffect;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: surface.card,
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (f != null && f < laneCount)
            _laneControls(f, surface)
          else
            Text(
              'Tap a lane to focus it, then tap inputs/outputs to wire it.',
              style: TextStyle(color: surface.textSecondary, fontSize: 13),
            ),
          if (sel != null &&
              sel.lane < laneCount &&
              sel.index < lanes[sel.lane].effects.length) ...[
            const SizedBox(height: 10),
            EffectParamsEditor(
              keyPrefix: 'laneGraph',
              fx: lanes[sel.lane].effects[sel.index],
              accentColor: surface.accent,
              onSetType: (t) => onSetType(sel.lane, sel.index, t),
              onSetParam: (p, v) => onSetParam(sel.lane, sel.index, p, v),
              onRemove: () => onRemoveEffect(sel.lane, sel.index),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('laneGraph_addLane'),
              onPressed: laneCount >= kMaxLanes ? null : onAddLane,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add lane'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _laneControls(int l, SurfaceTheme surface) {
    final lane = lanes[l];
    final canRemove = laneCount > 1;
    return Row(
      children: [
        Text(
          'Lane ${l + 1}',
          style: TextStyle(
            color: surface.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          key: const Key('laneGraph_mute'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          color: lane.muted ? surface.accent : surface.textSecondary,
          tooltip: lane.muted ? 'Unmute lane' : 'Mute lane',
          icon: Icon(lane.muted ? Icons.volume_off : Icons.volume_up),
          onPressed: () => onMuteToggled(l),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: surface.accent,
              inactiveTrackColor: surface.line,
              thumbColor: surface.accent,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              key: const Key('laneGraph_vol'),
              value: lane.volume.clamp(0.0, 1.0),
              onChanged: (v) => onVolumeChanged(l, v),
            ),
          ),
        ),
        if (canRemove)
          IconButton(
            key: const Key('laneGraph_removeLane'),
            iconSize: 18,
            color: surface.textSecondary,
            tooltip: 'Remove lane',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => onRemoveLane(l),
          ),
      ],
    );
  }
}
