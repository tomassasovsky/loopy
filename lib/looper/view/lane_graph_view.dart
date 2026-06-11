import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/common/routing_graph/channel_chip.dart';
import 'package:loopy/common/routing_graph/effect_chain_card.dart';
import 'package:loopy/common/routing_graph/effect_params_editor.dart';
import 'package:loopy/common/routing_graph/graph_canvas.dart';
import 'package:loopy/common/routing_graph/graph_colors.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';
import 'package:loopy/common/routing_graph/graph_edge_painter.dart';
import 'package:loopy/common/routing_graph/graph_geometry.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The whole track as one wired graph: hardware inputs on the left, the track's
/// **lanes** stacked in the middle (each a node + its own effect chain), and
/// hardware outputs on the right. Bezier edges show how every lane is wired.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph kit (`lib/common/routing_graph`); this view owns only the lane-specific
/// assembly: the layout geometry, the lane node body (with its vol/mute), the
/// add/remove-lane controls, the per-port colour rule, and the bottom panel.
/// Selection is **parent-owned** ([selectedEffect] + [onSelectEffect]); the
/// widget holds only view-local state (zoom, focus). Every edit is a callback.
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

  // ---- geometry ----
  static const double _chW = 54;
  static const double _chH = 24;
  static const double _laneW = 120;
  static const double _laneH = 50;
  static const double _cardW = 116;
  static const double _cardH = 40;
  static const double _gap = 16;
  static const double _fan = 92;
  static const double _addW = 30;
  static const double _laneRowH = 84;
  static const double _chRowH = 32;
  static const double _pad = 16;

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
    return Column(
      children: [
        Expanded(child: _canvas()),
        _panel(context),
      ],
    );
  }

  // ---- canvas ----

  Widget _canvas() {
    const g = LaneGraphView._gap;
    const chW = LaneGraphView._chW;
    const laneW = LaneGraphView._laneW;
    const cardW = LaneGraphView._cardW;
    const addW = LaneGraphView._addW;
    const inX = LaneGraphView._pad;
    const laneX = inX + chW + LaneGraphView._fan;
    const cardStartX = laneX + laneW + g;

    final cardXs = [
      for (final lane in widget.lanes)
        cardColumnXs(
          startX: cardStartX,
          count: lane.effects.length,
          cardW: cardW,
          gap: g,
        ),
    ];
    double addBtnX(int l) =>
        cardXs[l].isEmpty ? cardStartX : cardXs[l].last + cardW + g;
    var widestRight = cardStartX;
    for (var l = 0; l < _laneCount; l++) {
      if (addBtnX(l) + addW > widestRight) widestRight = addBtnX(l) + addW;
    }
    final outX = widestRight + LaneGraphView._fan;
    final railX = outX - LaneGraphView._fan;
    final canvasW = outX + chW + LaneGraphView._pad;

    final lanesBlockH = _laneCount * LaneGraphView._laneRowH;
    final channelsH =
        (_inCount > _outCount ? _inCount : _outCount) * LaneGraphView._chRowH;
    final canvasH =
        (lanesBlockH > channelsH ? lanesBlockH : channelsH) +
        LaneGraphView._pad * 2;
    final lanesTop = (canvasH - lanesBlockH) / 2;

    double laneY(int l) =>
        lanesTop + l * LaneGraphView._laneRowH + LaneGraphView._laneRowH / 2;
    double chY(int i, int count) => canvasH / count * (i + 0.5);

    final edges = _edges(
      laneX: laneX,
      cardXs: cardXs,
      railX: railX,
      outX: outX,
      inX: inX,
      laneY: laneY,
      chY: chY,
    );

    return GraphCanvas(
      width: canvasW,
      height: canvasH,
      fitIdentity: [
        _laneCount,
        for (final l in widget.lanes) l.effects.length,
        _inCount,
        _outCount,
      ],
      children: [
        Positioned.fill(child: CustomPaint(painter: GraphEdgePainter(edges))),
        for (var c = 0; c < _inCount; c++)
          _positioned(
            inX,
            chY(c, _inCount),
            chW,
            LaneGraphView._chH,
            _inChip(c),
          ),
        for (var c = 0; c < _outCount; c++)
          _positioned(
            outX,
            chY(c, _outCount),
            chW,
            LaneGraphView._chH,
            _outChip(c),
          ),
        for (var l = 0; l < _laneCount; l++) ...[
          _positioned(
            laneX,
            laneY(l),
            laneW,
            LaneGraphView._laneH,
            _laneBody(l),
          ),
          ..._dropZones(l, cardXs[l], cardStartX, laneY(l)),
          for (var k = 0; k < cardXs[l].length; k++)
            _positioned(
              cardXs[l][k],
              laneY(l),
              cardW,
              LaneGraphView._cardH,
              _card(l, k),
            ),
          _positioned(addBtnX(l), laneY(l), addW, addW, _addBtn(l)),
        ],
      ],
    );
  }

  Positioned _positioned(
    double x,
    double y,
    double w,
    double h,
    Widget child,
  ) => Positioned(left: x, top: y - h / 2, width: w, height: h, child: child);

  List<GraphEdge> _edges({
    required double laneX,
    required List<List<double>> cardXs,
    required double railX,
    required double outX,
    required double inX,
    required double Function(int) laneY,
    required double Function(int, int) chY,
  }) {
    const chW = LaneGraphView._chW;
    const laneW = LaneGraphView._laneW;
    const cardW = LaneGraphView._cardW;
    final edges = <GraphEdge>[];
    for (var l = 0; l < _laneCount; l++) {
      final lane = widget.lanes[l];
      final y = laneY(l);
      final color = laneColor(l);
      final faded = _focused != null && _focused != l;
      // input -> lane
      final c = lane.inputChannel;
      if (c >= 0 && c < _inCount && widget.excludedInputMask & (1 << c) == 0) {
        edges.add(
          GraphEdge(
            Offset(inX + chW, chY(c, _inCount)),
            Offset(laneX, y),
            color: color,
            faded: faded,
          ),
        );
      }
      // lane -> first card -> ... -> last
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
      // last -> shared output rail -> outputs (one send per lane).
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
          outCount: _outCount,
          outY: chY,
          faded: faded,
        ),
      );
    }
    return edges;
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
  Color _portColor(List<int> users, {required bool strong}) => strong
      ? laneColor(_focused!)
      : users.length == 1
      ? laneColor(users.first)
      : SetupSurfaceColors.accent;

  Widget _inChip(int c) {
    final excluded = widget.excludedInputMask & (1 << c) != 0;
    final users = excluded ? const <int>[] : _lanesUsing(c, output: false);
    final strong = _focused != null && users.contains(_focused);
    return ChannelChip(
      key: Key('laneGraph_in_$c'),
      label: 'In ${c + 1}',
      color: _portColor(users, strong: strong),
      strong: strong,
      wired: users.isNotEmpty,
      excluded: excluded,
      onTap: excluded || _focused == null
          ? null
          : () {
              final cur = widget.lanes[_focused!].inputChannel;
              widget.onInputChanged(_focused!, cur == c ? -1 : c);
            },
    );
  }

  Widget _outChip(int c) {
    final users = _lanesUsing(c, output: true);
    final strong = _focused != null && users.contains(_focused);
    return ChannelChip(
      key: Key('laneGraph_out_$c'),
      label: 'Out ${c + 1}',
      color: _portColor(users, strong: strong),
      strong: strong,
      wired: users.isNotEmpty,
      excluded: false,
      onTap: _focused == null
          ? null
          : () => widget.onOutputMaskChanged(
              _focused!,
              widget.lanes[_focused!].outputMask ^ (1 << c),
            ),
    );
  }

  Widget _laneBody(int l) {
    final lane = widget.lanes[l];
    final focused = _focused == l;
    final dim = _focused != null && !focused;
    final color = laneColor(l);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('laneGraph_laneNode_$l'),
        onTap: () => setState(() => _focused = focused ? null : l),
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
                        ? SetupSurfaceColors.t3
                        : SetupSurfaceColors.t2,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Lane ${l + 1}',
                    style: const TextStyle(
                      color: SetupSurfaceColors.t1,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              // Read-only volume level; editing is in the panel below.
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: LinearProgressIndicator(
                    value: lane.muted ? 0 : lane.volume.clamp(0.0, 1.0),
                    backgroundColor: SetupSurfaceColors.line,
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

  Widget _card(int l, int k) {
    final fx = widget.lanes[l].effects[k];
    final selected =
        widget.selectedEffect?.lane == l && widget.selectedEffect?.index == k;
    return EffectChainCard(
      cardKey: Key('laneGraph_fx_${l}_$k'),
      handleKey: Key('laneGraph_fx_handle_${l}_$k'),
      labelKey: Key('laneGraph_fxLabel_${l}_$k'),
      deleteKey: Key('laneGraph_fxDelete_${l}_$k'),
      label: fx.type.label,
      accentColor: laneColor(l),
      selected: selected,
      dragging: _dragging?.rowId == l && _dragging?.index == k,
      rowId: l,
      index: k,
      cardW: LaneGraphView._cardW,
      cardH: LaneGraphView._cardH,
      onTap: () {
        setState(() => _focused = l);
        widget.onSelectEffect(l, selected ? null : k);
      },
      onDelete: () => widget.onRemoveEffect(l, k),
      onDragStart: () => setState(() => _dragging = GraphCardRef(l, k)),
      onDragEnd: () => setState(() => _dragging = null),
    );
  }

  /// Drop targets between/around lane `l`'s cards, accepting only that lane's
  /// effects (so a card never jumps lanes). The gap index is the insertion 
  /// slot.
  List<Widget> _dropZones(int l, List<double> xs, double startX, double y) {
    const g = LaneGraphView._gap;
    const cardW = LaneGraphView._cardW;
    final spots = <double>[];
    if (xs.isEmpty) {
      spots.add(startX);
    } else {
      for (final x in xs) {
        spots.add(x - g);
      }
      spots.add(xs.last + cardW);
    }
    return [
      for (var pos = 0; pos < spots.length; pos++)
        Positioned(
          left: spots[pos],
          top: y - LaneGraphView._cardH / 2 - 6,
          width: g + 10,
          height: LaneGraphView._cardH + 12,
          child: EffectDropZone(
            dropKey: Key('laneGraph_drop_${l}_$pos'),
            rowId: l,
            accentColor: SetupSurfaceColors.accent,
            caretHeight: LaneGraphView._cardH,
            onAccept: (from) => widget.onMoveEffect(l, from, pos),
          ),
        ),
    ];
  }

  Widget _addBtn(int l) {
    return AddEffectButton(
      buttonKey: Key('laneGraph_addFx_$l'),
      accentColor: SetupSurfaceColors.accent,
      full: widget.lanes[l].effects.length >= kTrackEffectMax,
      tooltip: 'Add effect to lane ${l + 1}',
      onAdd: () {
        setState(() => _focused = l);
        widget.onAddEffect(l);
      },
    );
  }

  // ---- bottom panel ----

  Widget _panel(BuildContext context) {
    final focused = _focused;
    final sel = widget.selectedEffect;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: SetupSurfaceColors.card,
        border: Border(top: BorderSide(color: SetupSurfaceColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (focused != null && focused < _laneCount)
            _laneControls(focused)
          else
            const Text(
              'Tap a lane to focus it, then tap inputs/outputs to wire it.',
              style: TextStyle(color: SetupSurfaceColors.t2, fontSize: 13),
            ),
          if (sel != null &&
              sel.lane < _laneCount &&
              sel.index < widget.lanes[sel.lane].effects.length) ...[
            const SizedBox(height: 10),
            EffectParamsEditor(
              editorKey: const Key('laneGraph_fxEditor'),
              typeKey: const Key('laneGraph_fxType'),
              removeKey: const Key('laneGraph_fxRemove'),
              paramKey: (p) => Key('laneGraph_fxParam$p'),
              fx: widget.lanes[sel.lane].effects[sel.index],
              accentColor: SetupSurfaceColors.accent,
              onSetType: (t) => widget.onSetType(sel.lane, sel.index, t),
              onSetParam: (p, v) =>
                  widget.onSetParam(sel.lane, sel.index, p, v),
              onRemove: () => widget.onRemoveEffect(sel.lane, sel.index),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('laneGraph_addLane'),
              onPressed: _laneCount >= kMaxLanes ? null : widget.onAddLane,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add lane'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _laneControls(int l) {
    final lane = widget.lanes[l];
    final canRemove = _laneCount > 1;
    return Row(
      children: [
        Text(
          'Lane ${l + 1}',
          style: const TextStyle(
            color: SetupSurfaceColors.t1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          key: const Key('laneGraph_mute'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          color: lane.muted ? SetupSurfaceColors.accent : SetupSurfaceColors.t2,
          tooltip: lane.muted ? 'Unmute lane' : 'Mute lane',
          icon: Icon(lane.muted ? Icons.volume_off : Icons.volume_up),
          onPressed: () => widget.onMuteToggled(l),
        ),
        Expanded(
          child: SliderTheme(
            data: setupSliderTheme,
            child: Slider(
              key: const Key('laneGraph_vol'),
              value: lane.volume.clamp(0.0, 1.0),
              onChanged: (v) => widget.onVolumeChanged(l, v),
            ),
          ),
        ),
        if (canRemove)
          IconButton(
            key: const Key('laneGraph_removeLane'),
            iconSize: 18,
            color: SetupSurfaceColors.t2,
            tooltip: 'Remove lane',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => widget.onRemoveLane(l),
          ),
      ],
    );
  }
}
