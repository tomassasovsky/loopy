import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

/// A reference to one effect within a lane, used as the drag payload when
/// reordering a lane's chain (so a drop only lands within the same lane).
@immutable
class _FxRef {
  const _FxRef(this.lane, this.index);
  final int lane;
  final int index;
}

/// The whole track as one wired graph: hardware inputs on the left, the track's
/// **lanes** stacked in the middle (each a node + its own effect chain), and
/// hardware outputs on the right. Bezier edges show how every lane is wired.
///
/// The canvas zooms/pans and fits to view. Tap a lane node to *focus* it, then
/// tap an input or output node to (re)wire that lane; effects are dragged by
/// their handle to reorder and tapped to edit in the docked panel below. Mix,
/// add/remove lane, and the selected effect's editor live in that panel. The
/// widget holds only view-local state (zoom, focus); every edit is a callback.
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

  /// Lane stack edits. Only the last lane is removable.
  final VoidCallback onAddLane;
  final void Function(int lane) onRemoveLane;

  // ---- geometry ----
  static const double _chW = 58;
  static const double _chH = 28;
  static const double _laneW = 120;
  static const double _laneH = 50;
  static const double _cardW = 96;
  static const double _cardH = 40;
  static const double _gap = 16;
  static const double _fan = 70;
  static const double _addW = 30;
  static const double _laneRowH = 84;
  static const double _chRowH = 44;
  static const double _pad = 16;

  @override
  State<LaneGraphView> createState() => _LaneGraphViewState();
}

class _LaneGraphViewState extends State<LaneGraphView> {
  final TransformationController _tc = TransformationController();
  _FxRef? _dragging;

  /// The lane whose input/output nodes are currently being wired, or null.
  int? _focused;

  /// Re-fit when the lane count or any chain length changes (not on focus).
  int _fittedKey = -1;

  @override
  void didUpdateWidget(LaneGraphView old) {
    super.didUpdateWidget(old);
    // A removed lane leaves the focus index dangling past the shrunk list.
    if (_focused != null && _focused! >= widget.lanes.length) _focused = null;
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  int get _laneCount => widget.lanes.length;
  int get _inCount => widget.inputChannels > 0 ? widget.inputChannels : 4;
  int get _outCount => widget.outputChannels > 0 ? widget.outputChannels : 2;

  int get _layoutKey => Object.hashAll([
    _laneCount,
    for (final l in widget.lanes) l.effects.length,
    _inCount,
    _outCount,
  ]);

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

    // Each lane's card x positions + its right edge (after the add button).
    final cardXs = <List<double>>[];
    var widestRight = cardStartX;
    for (final lane in widget.lanes) {
      final xs = <double>[];
      var x = cardStartX;
      for (var k = 0; k < lane.effects.length; k++) {
        xs.add(x);
        x += cardW + g;
      }
      cardXs.add(xs);
      final right = x + addW; // add-effect button sits at the chain end
      if (right > widestRight) widestRight = right;
    }
    final outX = widestRight + LaneGraphView._fan;
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
      inX: inX,
      outX: outX,
      laneY: laneY,
      chY: chY,
    );

    return ColoredBox(
      color: SetupSurfaceColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _maybeFit(
            constraints.maxWidth,
            constraints.maxHeight,
            canvasW,
            canvasH,
          );
          return ClipRect(
            child: InteractiveViewer(
              transformationController: _tc,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.3,
              maxScale: 3,
              child: SizedBox(
                width: canvasW,
                height: canvasH,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _PathPainter(edges)),
                    ),
                    for (var c = 0; c < _inCount; c++)
                      _inNode(c, inX, chY(c, _inCount)),
                    for (var c = 0; c < _outCount; c++)
                      _outNode(c, outX, chY(c, _outCount)),
                    for (var l = 0; l < _laneCount; l++) ...[
                      _laneNode(l, laneX, laneY(l)),
                      ..._dropZones(l, cardXs[l], cardStartX, laneY(l)),
                      for (var k = 0; k < cardXs[l].length; k++)
                        _fxCard(l, k, cardXs[l][k], laneY(l)),
                      _addFxButton(
                        l,
                        cardXs[l].isEmpty
                            ? cardStartX
                            : cardXs[l].last + cardW + g,
                        laneY(l),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _maybeFit(double vw, double vh, double cw, double ch) {
    if (_fittedKey == _layoutKey || vw <= 0 || vh <= 0) return;
    _fittedKey = _layoutKey;
    var scale = vw / cw;
    if (ch * scale > vh) scale = vh / ch;
    if (scale > 1) scale = 1;
    final tx = (vw - cw * scale) / 2;
    final ty = (vh - ch * scale) / 2;
    final m = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }

  List<_Edge> _edges({
    required double laneX,
    required List<List<double>> cardXs,
    required double inX,
    required double outX,
    required double Function(int) laneY,
    required double Function(int, int) chY,
  }) {
    const chW = LaneGraphView._chW;
    const laneW = LaneGraphView._laneW;
    const cardW = LaneGraphView._cardW;
    final edges = <_Edge>[];
    for (var l = 0; l < _laneCount; l++) {
      final lane = widget.lanes[l];
      final y = laneY(l);
      // input -> lane
      final c = lane.inputChannel;
      if (c >= 0 && c < _inCount && widget.excludedInputMask & (1 << c) == 0) {
        edges.add(_Edge(Offset(inX + chW, chY(c, _inCount)), Offset(laneX, y)));
      }
      // lane -> first card -> ... -> last
      final xs = cardXs[l];
      var rightX = laneX + laneW;
      if (xs.isNotEmpty) {
        edges.add(_Edge(Offset(laneX + laneW, y), Offset(xs.first, y)));
        for (var k = 0; k < xs.length - 1; k++) {
          edges.add(_Edge(Offset(xs[k] + cardW, y), Offset(xs[k + 1], y)));
        }
        rightX = xs.last + cardW;
      }
      // last -> outputs
      for (var o = 0; o < _outCount; o++) {
        if (lane.outputMask & (1 << o) != 0) {
          edges.add(_Edge(Offset(rightX, y), Offset(outX, chY(o, _outCount))));
        }
      }
    }
    return edges;
  }

  // ---- nodes ----

  Widget _inNode(int c, double x, double y) {
    final excluded = widget.excludedInputMask & (1 << c) != 0;
    final wired = _focused != null && widget.lanes[_focused!].inputChannel == c;
    return _node(
      key: 'laneGraph_in_$c',
      label: 'In ${c + 1}',
      x: x,
      y: y,
      highlighted: wired,
      excluded: excluded,
      onTap: excluded || _focused == null
          ? null
          : () {
              final cur = widget.lanes[_focused!].inputChannel;
              widget.onInputChanged(_focused!, cur == c ? -1 : c);
            },
    );
  }

  Widget _outNode(int c, double x, double y) {
    final wired =
        _focused != null && widget.lanes[_focused!].outputMask & (1 << c) != 0;
    return _node(
      key: 'laneGraph_out_$c',
      label: 'Out ${c + 1}',
      x: x,
      y: y,
      highlighted: wired,
      excluded: false,
      onTap: _focused == null
          ? null
          : () => widget.onOutputMaskChanged(
              _focused!,
              widget.lanes[_focused!].outputMask ^ (1 << c),
            ),
    );
  }

  Widget _node({
    required String key,
    required String label,
    required double x,
    required double y,
    required bool highlighted,
    required bool excluded,
    required VoidCallback? onTap,
  }) {
    return Positioned(
      left: x,
      top: y - LaneGraphView._chH / 2,
      width: LaneGraphView._chW,
      height: LaneGraphView._chH,
      child: _Tappable(
        nodeKey: Key(key),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: excluded
                ? SetupSurfaceColors.cardHi
                : highlighted
                ? SetupSurfaceColors.accent.withValues(alpha: 0.30)
                : SetupSurfaceColors.card,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: highlighted
                  ? SetupSurfaceColors.accent
                  : SetupSurfaceColors.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: excluded
                  ? SetupSurfaceColors.t3
                  : highlighted
                  ? SetupSurfaceColors.t1
                  : SetupSurfaceColors.t2,
              decoration: excluded ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _laneNode(int l, double x, double y) {
    final lane = widget.lanes[l];
    final focused = _focused == l;
    return Positioned(
      left: x,
      top: y - LaneGraphView._laneH / 2,
      width: LaneGraphView._laneW,
      height: LaneGraphView._laneH,
      child: _Tappable(
        nodeKey: Key('laneGraph_laneNode_$l'),
        onTap: () => setState(() => _focused = focused ? null : l),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: SetupSurfaceColors.accent.withValues(
              alpha: focused ? 0.30 : 0.18,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: SetupSurfaceColors.accent,
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
                    valueColor: const AlwaysStoppedAnimation(
                      SetupSurfaceColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fxCard(int l, int k, double x, double y) {
    final fx = widget.lanes[l].effects[k];
    final selected =
        widget.selectedEffect?.lane == l && widget.selectedEffect?.index == k;
    final dragging = _dragging?.lane == l && _dragging?.index == k;
    final handle = Draggable<_FxRef>(
      key: Key('laneGraph_fx_handle_${l}_$k'),
      data: _FxRef(l, k),
      onDragStarted: () => setState(() => _dragging = _FxRef(l, k)),
      onDragEnd: (_) => setState(() => _dragging = null),
      feedback: Material(color: Colors.transparent, child: _chip(fx)),
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Icon(
          Icons.drag_indicator,
          size: 16,
          color: SetupSurfaceColors.t3,
        ),
      ),
    );
    return Positioned(
      left: x,
      top: y - LaneGraphView._cardH / 2,
      width: LaneGraphView._cardW,
      height: LaneGraphView._cardH,
      child: Container(
        key: Key('laneGraph_fx_${l}_$k'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: SetupSurfaceColors.cardHi.withValues(
            alpha: dragging ? 0.4 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? SetupSurfaceColors.accent
                : SetupSurfaceColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            handle,
            const SizedBox(width: 4),
            Expanded(
              child: _Tappable(
                nodeKey: Key('laneGraph_fxLabel_${l}_$k'),
                onTap: () {
                  setState(() => _focused = l);
                  widget.onSelectEffect(l, selected ? null : k);
                },
                child: Text(
                  fx.type.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SetupSurfaceColors.t1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(TrackEffect fx) => Container(
    width: LaneGraphView._cardW,
    height: LaneGraphView._cardH,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: SetupSurfaceColors.cardHi,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SetupSurfaceColors.accent),
    ),
    child: Text(
      fx.type.label,
      style: const TextStyle(color: SetupSurfaceColors.t1),
    ),
  );

  /// Drop targets between/around lane `l`'s cards, accepting only that lane's
  /// effects (so a card never jumps lanes).
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
          child: DragTarget<_FxRef>(
            onWillAcceptWithDetails: (d) => d.data.lane == l,
            onAcceptWithDetails: (d) =>
                widget.onMoveEffect(l, d.data.index, pos),
            builder: (_, candidate, _) => SizedBox.expand(
              key: Key('laneGraph_drop_${l}_$pos'),
              child: candidate.isEmpty
                  ? null
                  : Center(
                      child: Container(
                        width: 3,
                        height: LaneGraphView._cardH,
                        color: SetupSurfaceColors.accent,
                      ),
                    ),
            ),
          ),
        ),
    ];
  }

  Widget _addFxButton(int l, double x, double y) {
    final full = widget.lanes[l].effects.length >= kTrackEffectMax;
    return Positioned(
      left: x,
      top: y - LaneGraphView._addW / 2,
      width: LaneGraphView._addW,
      height: LaneGraphView._addW,
      child: IconButton(
        key: Key('laneGraph_addFx_$l'),
        padding: EdgeInsets.zero,
        iconSize: 24,
        color: SetupSurfaceColors.accent,
        tooltip: full ? 'Chain is full' : 'Add effect to lane ${l + 1}',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: full
            ? null
            : () {
                setState(() => _focused = l);
                widget.onAddEffect(l);
              },
      ),
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
            _fxEditor(
              sel.lane,
              sel.index,
              widget.lanes[sel.lane].effects[sel.index],
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
    final canRemove = _laneCount > 1 && l == _laneCount - 1;
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

  Widget _fxEditor(int l, int index, TrackEffect fx) {
    return Container(
      key: const Key('laneGraph_fxEditor'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SetupSurfaceColors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: const Key('laneGraph_fxType'),
                  isExpanded: true,
                  isDense: true,
                  value: fx.type,
                  dropdownColor: SetupSurfaceColors.cardHi,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 14,
                  ),
                  onChanged: (type) {
                    if (type != null && type != TrackEffectType.none) {
                      widget.onSetType(l, index, type);
                    }
                  },
                  items: [
                    for (final type in TrackEffectType.values)
                      if (type != TrackEffectType.none)
                        DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('laneGraph_fxRemove'),
                iconSize: 18,
                color: SetupSurfaceColors.t2,
                tooltip: 'Remove effect',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => widget.onRemoveEffect(l, index),
              ),
            ],
          ),
          for (var p = 0; p < fx.type.paramLabels.length; p++)
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      fx.type.paramLabels[p],
                      style: const TextStyle(
                        color: SetupSurfaceColors.t2,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: setupSliderTheme,
                      child: Slider(
                        key: Key('laneGraph_fxParam$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) => widget.onSetParam(l, index, p, v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Tappable extends StatelessWidget {
  const _Tappable({
    required this.nodeKey,
    required this.onTap,
    required this.child,
  });

  final Key nodeKey;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    child: GestureDetector(
      key: nodeKey,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: child,
    ),
  );
}

class _Edge {
  const _Edge(this.from, this.to);
  final Offset from;
  final Offset to;
}

class _PathPainter extends CustomPainter {
  _PathPainter(this.edges);

  final List<_Edge> edges;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = SetupSurfaceColors.accent.withValues(alpha: 0.75);
    for (final e in edges) {
      final dx = (e.to.dx - e.from.dx) / 2;
      final path = Path()
        ..moveTo(e.from.dx, e.from.dy)
        ..cubicTo(
          e.from.dx + dx,
          e.from.dy,
          e.to.dx - dx,
          e.to.dy,
          e.to.dx,
          e.to.dy,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) => old.edges != edges;
}
