import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';

/// A single-track signal-flow graph with the track's effects as draggable cards
/// laid out on the path itself:
///
///   In → before-track effects → Track → after-track effects → Out
///
/// Channels (left/right columns) are clicked to connect/disconnect routing.
/// Effect cards are dragged to reorder within a lane or across the track (which
/// flips their stage, before↔after), and tapped to select for editing. The
/// connecting paths are drawn between adjacent stations along the centerline so
/// they never run through a card. The whole graph scrolls horizontally when a
/// lane grows long.
class TrackSignalFlowView extends StatefulWidget {
  /// Creates a [TrackSignalFlowView].
  const TrackSignalFlowView({
    required this.track,
    required this.inputChannels,
    required this.outputChannels,
    required this.effects,
    required this.onInputMaskChanged,
    required this.onOutputMaskChanged,
    required this.onAddEffect,
    required this.onMoveEffect,
    required this.selectedEffect,
    required this.onSelectEffect,
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

  /// Toggles an input/output routing connection.
  final void Function(int mask) onInputMaskChanged;
  final void Function(int mask) onOutputMaskChanged;

  /// Appends a default effect to the given lane.
  final void Function(TrackEffectStage stage) onAddEffect;

  /// Moves the chain entry at the first index to the given lane stage at the
  /// position (drag-and-drop reorder / restage).
  final void Function(int from, TrackEffectStage stage, int toPos) onMoveEffect;

  /// The selected effect's chain index (for the editor), or null.
  final int? selectedEffect;

  /// Selects (or deselects) an effect card.
  final void Function(int? index) onSelectEffect;

  // ---- geometry ----
  static const double _chW = 60;
  static const double _chH = 28;
  static const double _rowH = 46;
  static const double _cardW = 84;
  static const double _cardH = 36;
  static const double _trkW = 80;
  static const double _trkH = 40;
  static const double _gap = 16;
  static const double _addW = 28;
  static const double _pad = 8;

  @override
  State<TrackSignalFlowView> createState() => _TrackSignalFlowViewState();
}

class _TrackSignalFlowViewState extends State<TrackSignalFlowView> {
  /// The chain index currently being dragged (dims its card), or null.
  int? _dragging;

  List<int> _lane(TrackEffectStage stage) => [
    for (var i = 0; i < widget.effects.length; i++)
      if (widget.effects[i].stage == stage) i,
  ];

  @override
  Widget build(BuildContext context) {
    final pre = _lane(TrackEffectStage.pre);
    final post = _lane(TrackEffectStage.post);
    final inCount = widget.inputChannels > 0 ? widget.inputChannels : 4;
    final outCount = widget.outputChannels > 0 ? widget.outputChannels : 2;
    final rows = [inCount, outCount, 1].reduce((a, b) => a > b ? a : b);

    const g = TrackSignalFlowView._gap;
    const cardW = TrackSignalFlowView._cardW;
    const chW = TrackSignalFlowView._chW;
    const addW = TrackSignalFlowView._addW;
    final height = rows * TrackSignalFlowView._rowH;
    final centerY = height / 2;

    // X positions (left edge) of each station along the centerline.
    const inX = TrackSignalFlowView._pad;
    const preStartX = inX + chW + g;
    final preXs = [
      for (var i = 0; i < pre.length; i++) preStartX + i * (cardW + g),
    ];
    final addPreX = preStartX + pre.length * (cardW + g);
    final trackX = addPreX + addW + g;
    final postStartX = trackX + TrackSignalFlowView._trkW + g;
    final postXs = [
      for (var j = 0; j < post.length; j++) postStartX + j * (cardW + g),
    ];
    final addPostX = postStartX + post.length * (cardW + g);
    final outX = addPostX + addW + g;
    final width = outX + chW + TrackSignalFlowView._pad;

    // Anchor points (right edge of one station -> left edge of the next) used
    // to draw the path. The first/last centerline station the channels fan to.
    final firstX = pre.isNotEmpty ? preXs.first : trackX;
    final lastX = post.isNotEmpty
        ? postXs.last + cardW
        : trackX + TrackSignalFlowView._trkW;

    final edges = <_Edge>[];
    // Inputs -> first centerline station.
    for (var c = 0; c < inCount; c++) {
      if (widget.track.inputMask & (1 << c) == 0) continue;
      if (widget.excludedInputMask & (1 << c) != 0) continue;
      edges.add(
        _Edge(
          Offset(inX + chW, _rowY(c, inCount, height)),
          Offset(firstX, centerY),
        ),
      );
    }
    // Pre chain -> track.
    for (var i = 0; i < pre.length; i++) {
      final from = Offset(preXs[i] + cardW, centerY);
      final to = i + 1 < pre.length
          ? Offset(preXs[i + 1], centerY)
          : Offset(trackX, centerY);
      edges.add(_Edge(from, to));
    }
    // Track -> first post station (or straight to outputs handled below).
    if (post.isNotEmpty) {
      edges.add(
        _Edge(
          Offset(trackX + TrackSignalFlowView._trkW, centerY),
          Offset(postXs.first, centerY),
        ),
      );
      for (var j = 0; j < post.length - 1; j++) {
        edges.add(
          _Edge(
            Offset(postXs[j] + cardW, centerY),
            Offset(postXs[j + 1], centerY),
          ),
        );
      }
    }
    // Last centerline station -> outputs.
    for (var c = 0; c < outCount; c++) {
      if (widget.track.outputMask & (1 << c) == 0) continue;
      edges.add(
        _Edge(Offset(lastX, centerY), Offset(outX, _rowY(c, outCount, height))),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final flow = SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _PathPainter(edges, scheme.primary)),
          ),
          // Input channels.
          for (var c = 0; c < inCount; c++)
            _channel(
              key: 'signalFlow_input_$c',
              label: 'In ${c + 1}',
              x: inX,
              y: _rowY(c, inCount, height),
              connected: widget.track.inputMask & (1 << c) != 0,
              excluded: widget.excludedInputMask & (1 << c) != 0,
              onTap: () =>
                  widget.onInputMaskChanged(widget.track.inputMask ^ (1 << c)),
            ),
          // Output channels.
          for (var c = 0; c < outCount; c++)
            _channel(
              key: 'signalFlow_output_$c',
              label: 'Out ${c + 1}',
              x: outX,
              y: _rowY(c, outCount, height),
              connected: widget.track.outputMask & (1 << c) != 0,
              excluded: false,
              onTap: () => widget.onOutputMaskChanged(
                widget.track.outputMask ^ (1 << c),
              ),
            ),
          // The track node.
          Positioned(
            left: trackX,
            top: centerY - TrackSignalFlowView._trkH / 2,
            width: TrackSignalFlowView._trkW,
            height: TrackSignalFlowView._trkH,
            child: _trackNode(),
          ),
          // Drop zones (one before each card and after the last) per lane.
          ..._dropZones(TrackEffectStage.pre, pre, preStartX, centerY),
          ..._dropZones(TrackEffectStage.post, post, postStartX, centerY),
          // Effect cards.
          for (var i = 0; i < pre.length; i++) _card(pre[i], preXs[i], centerY),
          for (var j = 0; j < post.length; j++)
            _card(post[j], postXs[j], centerY),
          // Add buttons.
          _addButton(TrackEffectStage.pre, addPreX, centerY),
          _addButton(TrackEffectStage.post, addPostX, centerY),
        ],
      ),
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: flow,
    );
  }

  double _rowY(int index, int count, double height) =>
      height / count * (index + 0.5);

  Widget _channel({
    required String key,
    required String label,
    required double x,
    required double y,
    required bool connected,
    required bool excluded,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
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
            color: connected
                ? scheme.primary.withValues(alpha: 0.28)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: connected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              decoration: excluded ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackNode() {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.primary, width: 2),
      ),
      child: Center(
        child: Text(
          'Track ${widget.track.channel + 1}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      ),
    );
  }

  Widget _card(int index, double x, double centerY) {
    final fx = widget.effects[index];
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selectedEffect == index;
    final dragging = _dragging == index;

    final body = Container(
      width: TrackSignalFlowView._cardW,
      height: TrackSignalFlowView._cardH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: dragging ? 0.4 : 1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.drag_indicator, size: 14, color: scheme.outline),
          const SizedBox(width: 2),
          Flexible(child: Text(fx.type.label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );

    return Positioned(
      left: x,
      top: centerY - TrackSignalFlowView._cardH / 2,
      width: TrackSignalFlowView._cardW,
      height: TrackSignalFlowView._cardH,
      child: Draggable<int>(
        data: index,
        onDragStarted: () => setState(() => _dragging = index),
        onDragEnd: (_) => setState(() => _dragging = null),
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.9, child: body),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: body),
        child: _Tappable(
          nodeKey: Key('signalFlow_fx_$index'),
          onTap: () => widget.onSelectEffect(selected ? null : index),
          child: body,
        ),
      ),
    );
  }

  /// Invisible drop targets sitting in the gap before each card (and after the
  /// last) so a dragged card can be inserted at that lane position.
  List<Widget> _dropZones(
    TrackEffectStage stage,
    List<int> lane,
    double startX,
    double centerY,
  ) {
    const cardW = TrackSignalFlowView._cardW;
    const g = TrackSignalFlowView._gap;
    final laneName = stage == TrackEffectStage.pre ? 'pre' : 'post';
    return [
      for (var pos = 0; pos <= lane.length; pos++)
        Positioned(
          left: startX + pos * (cardW + g) - g,
          top: centerY - TrackSignalFlowView._cardH / 2 - 6,
          width: g + 8,
          height: TrackSignalFlowView._cardH + 12,
          child: DragTarget<int>(
            onAcceptWithDetails: (d) => widget.onMoveEffect(d.data, stage, pos),
            builder: (_, candidate, _) => SizedBox.expand(
              key: Key('signalFlow_drop_${laneName}_$pos'),
              child: candidate.isEmpty
                  ? null
                  : Center(
                      child: Container(
                        width: 3,
                        height: TrackSignalFlowView._cardH,
                        color: Theme.of(context).colorScheme.primary,
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
        iconSize: 22,
        tooltip: full ? 'Chain is full' : 'Add effect',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: full ? null : () => widget.onAddEffect(stage),
      ),
    );
  }
}

/// A click target that stays a click target during a [Draggable]'s gesture
/// arena by using an opaque hit-test region.
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
  _PathPainter(this.edges, this.color);

  final List<_Edge> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.7);
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
  bool shouldRepaint(_PathPainter old) =>
      old.edges != edges || old.color != color;
}
