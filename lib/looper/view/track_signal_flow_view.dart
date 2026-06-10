import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

/// A single-track signal-flow graph with the track's effects as cards on the
/// path itself:
///
///   In → before-track effects → Track → after-track effects → Out
///
/// The whole canvas is zoom/pan-able (InteractiveViewer) and fits to view on
/// load. Channels are clicked to connect/disconnect routing. An effect card is
/// dragged by its handle to reorder within a lane or across the track (which
/// flips its stage), and tapped to expand its settings inline (type + params).
/// Connection paths fan out vertically so they stay legible.
class TrackSignalFlowView extends StatefulWidget {
  /// Creates a [TrackSignalFlowView].
  const TrackSignalFlowView({
    required this.track,
    required this.inputChannels,
    required this.outputChannels,
    required this.effects,
    required this.selectedEffect,
    required this.onInputMaskChanged,
    required this.onOutputMaskChanged,
    required this.onAddEffect,
    required this.onMoveEffect,
    required this.onSelectEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemoveEffect,
    this.excludedInputMask = 0,
    super.key,
  });

  /// The track whose routing + effects are drawn.
  final Track track;

  /// Hardware input/output channel counts (`0` when stopped).
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, shown dimmed and never wired.
  final int excludedInputMask;

  /// The track's ordered effects chain.
  final List<TrackEffect> effects;

  /// The selected (expanded) effect's chain index, or null.
  final int? selectedEffect;

  /// Toggles an input/output routing connection.
  final void Function(int mask) onInputMaskChanged;
  final void Function(int mask) onOutputMaskChanged;

  /// Appends a default effect to the given lane.
  final void Function(TrackEffectStage stage) onAddEffect;

  /// Moves a chain entry to the given lane stage at the given lane position.
  final void Function(int from, TrackEffectStage stage, int toPos) onMoveEffect;

  /// Selects (expands) or deselects an effect card.
  final void Function(int? index) onSelectEffect;

  /// Edits the selected card.
  final void Function(int index, TrackEffectType type) onSetType;
  final void Function(int index, int param, double value) onSetParam;
  final void Function(int index) onRemoveEffect;

  // ---- geometry ----
  static const double _chW = 60;
  static const double _chH = 28;
  static const double _rowH = 44;
  static const double _compactW = 124;
  static const double _compactH = 42;
  static const double _exW = 250;
  static const double _trkW = 84;
  static const double _trkH = 44;
  static const double _gap = 20;
  static const double _fanGap = 72;
  static const double _addW = 30;
  static const double _pad = 12;

  @override
  State<TrackSignalFlowView> createState() => _TrackSignalFlowViewState();
}

class _TrackSignalFlowViewState extends State<TrackSignalFlowView> {
  final TransformationController _tc = TransformationController();
  int _dragging = -1;
  int _fittedCount = -1;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  List<int> _lane(TrackEffectStage stage) => [
    for (var i = 0; i < widget.effects.length; i++)
      if (widget.effects[i].stage == stage) i,
  ];

  double _cardWidth(int index) => index == widget.selectedEffect
      ? TrackSignalFlowView._exW
      : TrackSignalFlowView._compactW;

  double _cardHeight(int index) {
    if (index != widget.selectedEffect) return TrackSignalFlowView._compactH;
    final params = widget.effects[index].type.paramLabels.length;
    return 62 + params * 38; // padding + header + gap + param rows
  }

  @override
  Widget build(BuildContext context) {
    final pre = _lane(TrackEffectStage.pre);
    final post = _lane(TrackEffectStage.post);
    final inCount = widget.inputChannels > 0 ? widget.inputChannels : 4;
    final outCount = widget.outputChannels > 0 ? widget.outputChannels : 2;

    const chW = TrackSignalFlowView._chW;
    const g = TrackSignalFlowView._gap;
    const fan = TrackSignalFlowView._fanGap;
    const addW = TrackSignalFlowView._addW;
    const trkW = TrackSignalFlowView._trkW;
    const inX = TrackSignalFlowView._pad;

    const preStartX = inX + chW + fan;
    var x = preStartX;
    final preXs = <double>[];
    for (final i in pre) {
      preXs.add(x);
      x += _cardWidth(i) + g;
    }
    final addPreX = x;
    final trackX = addPreX + addW + g;
    final postStartX = trackX + trkW + g;
    x = postStartX;
    final postXs = <double>[];
    for (final j in post) {
      postXs.add(x);
      x += _cardWidth(j) + g;
    }
    final addPostX = x;
    final outX = addPostX + addW + fan;
    final canvasW = outX + chW + TrackSignalFlowView._pad;

    final channelsH =
        [inCount, outCount].reduce((a, b) => a > b ? a : b) *
        TrackSignalFlowView._rowH;
    var tallestCard = TrackSignalFlowView._compactH;
    for (var i = 0; i < widget.effects.length; i++) {
      tallestCard = _cardHeight(i) > tallestCard ? _cardHeight(i) : tallestCard;
    }
    final canvasH =
        (channelsH > tallestCard + 24 ? channelsH : tallestCard + 24) +
        TrackSignalFlowView._pad * 2;
    final centerY = canvasH / 2;

    final firstX = pre.isNotEmpty ? preXs.first : trackX;
    final lastRightX = post.isNotEmpty
        ? postXs.last + _cardWidth(post.last)
        : trackX + trkW;

    final edges = _buildEdges(
      pre: pre,
      post: post,
      preXs: preXs,
      postXs: postXs,
      inCount: inCount,
      outCount: outCount,
      inX: inX,
      outX: outX,
      trackX: trackX,
      firstX: firstX,
      lastRightX: lastRightX,
      centerY: centerY,
      canvasH: canvasH,
    );

    // Fills the page; the graph fits-and-centers into the available space.
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
              // Unbounded: without this the viewer clamps the fit-and-center
              // translation back to the top-left on the first pan (the canvas
              // is smaller than the viewport), snapping the graph to the edge.
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.4,
              maxScale: 3,
              child: SizedBox(
                width: canvasW,
                height: canvasH,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _PathPainter(edges)),
                    ),
                    for (var c = 0; c < inCount; c++)
                      _channel(
                        key: 'signalFlow_input_$c',
                        label: 'In ${c + 1}',
                        x: inX,
                        y: _rowY(c, inCount, canvasH),
                        connected: widget.track.inputMask & (1 << c) != 0,
                        excluded: widget.excludedInputMask & (1 << c) != 0,
                        onTap: () => widget.onInputMaskChanged(
                          widget.track.inputMask ^ (1 << c),
                        ),
                      ),
                    for (var c = 0; c < outCount; c++)
                      _channel(
                        key: 'signalFlow_output_$c',
                        label: 'Out ${c + 1}',
                        x: outX,
                        y: _rowY(c, outCount, canvasH),
                        connected: widget.track.outputMask & (1 << c) != 0,
                        excluded: false,
                        onTap: () => widget.onOutputMaskChanged(
                          widget.track.outputMask ^ (1 << c),
                        ),
                      ),
                    Positioned(
                      left: trackX,
                      top: centerY - TrackSignalFlowView._trkH / 2,
                      width: trkW,
                      height: TrackSignalFlowView._trkH,
                      child: _trackNode(),
                    ),
                    ..._dropZones(TrackEffectStage.pre, pre, preXs, centerY),
                    ..._dropZones(
                      TrackEffectStage.post,
                      post,
                      postXs,
                      centerY,
                    ),
                    for (var k = 0; k < pre.length; k++)
                      _card(pre[k], preXs[k], centerY),
                    for (var k = 0; k < post.length; k++)
                      _card(post[k], postXs[k], centerY),
                    _addButton(TrackEffectStage.pre, addPreX, centerY),
                    _addButton(TrackEffectStage.post, addPostX, centerY),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Fits the whole canvas into the viewport and centers it, once per change in
  /// effect count (so adding/removing an effect re-frames, but selecting one
  /// does not — the user keeps whatever zoom they set in between).
  void _maybeFit(double vw, double vh, double canvasW, double canvasH) {
    if (_fittedCount == widget.effects.length || vw <= 0 || vh <= 0) return;
    _fittedCount = widget.effects.length;
    var scale = vw / canvasW;
    if (canvasH * scale > vh) scale = vh / canvasH;
    if (scale > 1) scale = 1;
    final tx = (vw - canvasW * scale) / 2;
    final ty = (vh - canvasH * scale) / 2;
    final m = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }

  double _rowY(int index, int count, double height) =>
      height / count * (index + 0.5);

  List<_Edge> _buildEdges({
    required List<int> pre,
    required List<int> post,
    required List<double> preXs,
    required List<double> postXs,
    required int inCount,
    required int outCount,
    required double inX,
    required double outX,
    required double trackX,
    required double firstX,
    required double lastRightX,
    required double centerY,
    required double canvasH,
  }) {
    final edges = <_Edge>[];
    final routedIns = [
      for (var c = 0; c < inCount; c++)
        if (widget.track.inputMask & (1 << c) != 0 &&
            widget.excludedInputMask & (1 << c) == 0)
          c,
    ];
    final inBand = routedIns.length <= 1 ? 0.0 : routedIns.length * 14.0;
    for (var k = 0; k < routedIns.length; k++) {
      final c = routedIns[k];
      final ty = routedIns.length <= 1
          ? centerY
          : centerY - inBand / 2 + (k + 0.5) * inBand / routedIns.length;
      edges.add(
        _Edge(
          Offset(inX + TrackSignalFlowView._chW, _rowY(c, inCount, canvasH)),
          Offset(firstX, ty),
        ),
      );
    }
    for (var k = 0; k < pre.length; k++) {
      final from = Offset(preXs[k] + _cardWidth(pre[k]), centerY);
      final to = k + 1 < pre.length
          ? Offset(preXs[k + 1], centerY)
          : Offset(trackX, centerY);
      edges.add(_Edge(from, to));
    }
    if (post.isNotEmpty) {
      edges.add(
        _Edge(
          Offset(trackX + TrackSignalFlowView._trkW, centerY),
          Offset(postXs.first, centerY),
        ),
      );
      for (var k = 0; k < post.length - 1; k++) {
        edges.add(
          _Edge(
            Offset(postXs[k] + _cardWidth(post[k]), centerY),
            Offset(postXs[k + 1], centerY),
          ),
        );
      }
    }
    final routedOuts = [
      for (var c = 0; c < outCount; c++)
        if (widget.track.outputMask & (1 << c) != 0) c,
    ];
    final outBand = routedOuts.length <= 1 ? 0.0 : routedOuts.length * 14.0;
    for (var k = 0; k < routedOuts.length; k++) {
      final c = routedOuts[k];
      final fy = routedOuts.length <= 1
          ? centerY
          : centerY - outBand / 2 + (k + 0.5) * outBand / routedOuts.length;
      edges.add(
        _Edge(
          Offset(lastRightX, fy),
          Offset(outX, _rowY(c, outCount, canvasH)),
        ),
      );
    }
    return edges;
  }

  Widget _channel({
    required String key,
    required String label,
    required double x,
    required double y,
    required bool connected,
    required bool excluded,
    required VoidCallback onTap,
  }) {
    return Positioned(
      left: x,
      top: y - TrackSignalFlowView._chH / 2,
      width: TrackSignalFlowView._chW,
      height: TrackSignalFlowView._chH,
      child: _Tappable(
        nodeKey: Key(key),
        onTap: excluded ? null : onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: excluded
                ? SetupSurfaceColors.cardHi
                : connected
                ? SetupSurfaceColors.accent.withValues(alpha: 0.30)
                : SetupSurfaceColors.card,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: connected
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
                  : connected
                  ? SetupSurfaceColors.t1
                  : SetupSurfaceColors.t2,
              decoration: excluded ? TextDecoration.lineThrough : null,
              decorationColor: SetupSurfaceColors.t3,
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackNode() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: SetupSurfaceColors.accent.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SetupSurfaceColors.accent, width: 2),
      ),
      child: Center(
        child: Text(
          'Track ${widget.track.channel + 1}',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: SetupSurfaceColors.t1,
          ),
        ),
      ),
    );
  }

  Widget _card(int index, double x, double centerY) {
    final fx = widget.effects[index];
    final selected = widget.selectedEffect == index;
    final dragging = _dragging == index;
    final w = _cardWidth(index);
    final h = _cardHeight(index);

    final handle = Draggable<int>(
      key: Key('signalFlow_fx_handle_$index'),
      data: index,
      onDragStarted: () => setState(() => _dragging = index),
      onDragEnd: (_) => setState(() => _dragging = -1),
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

    final content = selected
        ? _cardEditor(index, fx, handle)
        : Row(
            children: [
              handle,
              const SizedBox(width: 6),
              Expanded(
                child: _Tappable(
                  nodeKey: Key('signalFlow_fx_label_$index'),
                  onTap: () => widget.onSelectEffect(index),
                  child: Text(
                    fx.type.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: SetupSurfaceColors.t1,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          );

    return Positioned(
      left: x,
      top: centerY - h / 2,
      width: w,
      height: h,
      child: Container(
        key: Key('signalFlow_fx_$index'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
        child: content,
      ),
    );
  }

  Widget _chip(TrackEffect fx) => Container(
    width: TrackSignalFlowView._compactW,
    height: TrackSignalFlowView._compactH,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: SetupSurfaceColors.cardHi,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SetupSurfaceColors.accent),
    ),
    child: Text(
      fx.type.label,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: SetupSurfaceColors.t1),
    ),
  );

  /// The inline editor shown inside a selected card: type + params. Stage is
  /// changed by dragging the card across the track, not here.
  Widget _cardEditor(int index, TrackEffect fx, Widget handle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            handle,
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButton<TrackEffectType>(
                key: const Key('trackRouting_fx_type'),
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
                    widget.onSetType(index, type);
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
            _HeaderIcon(
              nodeKey: const Key('signalFlow_fx_collapse'),
              icon: Icons.expand_less,
              tooltip: 'Collapse',
              onTap: () => widget.onSelectEffect(null),
            ),
            const SizedBox(width: 2),
            _HeaderIcon(
              nodeKey: const Key('trackRouting_fx_remove'),
              icon: Icons.delete_outline,
              tooltip: 'Remove effect',
              onTap: () => widget.onRemoveEffect(index),
            ),
          ],
        ),
        const SizedBox(height: 2),
        for (var p = 0; p < fx.type.paramLabels.length; p++)
          SizedBox(
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
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
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: SetupSurfaceColors.accent,
                      inactiveTrackColor: SetupSurfaceColors.line,
                      thumbColor: SetupSurfaceColors.accent,
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                    ),
                    child: Slider(
                      key: Key('trackRouting_fx_param$p'),
                      value: fx.params[p].clamp(0.0, 1.0),
                      onChanged: (v) => widget.onSetParam(index, p, v),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _dropZones(
    TrackEffectStage stage,
    List<int> lane,
    List<double> xs,
    double centerY,
  ) {
    const g = TrackSignalFlowView._gap;
    final laneName = stage == TrackEffectStage.pre ? 'pre' : 'post';
    final spots = <double>[];
    if (lane.isEmpty) {
      spots.add(
        stage == TrackEffectStage.pre
            ? TrackSignalFlowView._pad +
                  TrackSignalFlowView._chW +
                  TrackSignalFlowView._fanGap -
                  g
            : (xs.isEmpty ? centerY : xs.first),
      );
    }
    for (var pos = 0; pos < lane.length; pos++) {
      spots.add(xs[pos] - g);
    }
    if (lane.isNotEmpty) {
      spots.add(xs.last + _cardWidth(lane.last));
    }
    return [
      for (var pos = 0; pos < spots.length; pos++)
        Positioned(
          left: spots[pos],
          top: centerY - TrackSignalFlowView._compactH / 2 - 6,
          width: g + 10,
          height: TrackSignalFlowView._compactH + 12,
          child: DragTarget<int>(
            onAcceptWithDetails: (d) => widget.onMoveEffect(d.data, stage, pos),
            builder: (_, candidate, _) => SizedBox.expand(
              key: Key('signalFlow_drop_${laneName}_$pos'),
              child: candidate.isEmpty
                  ? null
                  : Center(
                      child: Container(
                        width: 3,
                        height: TrackSignalFlowView._compactH,
                        color: SetupSurfaceColors.accent,
                      ),
                    ),
            ),
          ),
        ),
    ];
  }

  Widget _addButton(TrackEffectStage stage, double x, double centerY) {
    final full = widget.effects.length >= kTrackEffectMax;
    return Positioned(
      left: x,
      top: centerY - TrackSignalFlowView._addW / 2,
      width: TrackSignalFlowView._addW,
      height: TrackSignalFlowView._addW,
      child: IconButton(
        key: Key(
          stage == TrackEffectStage.pre
              ? 'signalFlow_addPre'
              : 'signalFlow_addPost',
        ),
        padding: EdgeInsets.zero,
        iconSize: 24,
        color: SetupSurfaceColors.accent,
        tooltip: full ? 'Chain is full' : 'Add effect',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: full ? null : () => widget.onAddEffect(stage),
      ),
    );
  }
}

/// A click target that stays hittable beside a [Draggable] by being opaque.
/// A compact, uniform tap target for the card-editor header (collapse, remove).
/// Square 28px hit area so the icons line up and are comfortable to click.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.nodeKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Key nodeKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkResponse(
      key: nodeKey,
      onTap: onTap,
      radius: 18,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(icon, size: 18, color: SetupSurfaceColors.t2),
      ),
    ),
  );
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
