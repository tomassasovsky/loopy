import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';

/// Opens the input-monitoring routing graph as a full-screen page (so it has
/// room instead of a cramped panel). Re-provides the [MonitorCubit] into the
/// pushed route, which lives under the root navigator.
Future<void> showMonitorRoutingPage({
  required BuildContext context,
  required int inputChannels,
  required int outputChannels,
  int excludedInputMask = 0,
}) {
  final cubit = context.read<MonitorCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: Scaffold(
          key: const Key('monitorRouting_page'),
          appBar: AppBar(title: const Text('Input monitoring')),
          body: MonitorGraphView(
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            excludedInputMask: excludedInputMask,
          ),
        ),
      ),
    ),
  );
}

/// Colours shared across the graph. Wet = effected route, dry = clean send.
const Color _wet = Color(0xFF3B82F6);
const Color _dry = Color(0xFFF59E0B);

/// The slider styling for the effect-parameter editor.
const _paramSliderTheme = SliderThemeData(
  trackHeight: 3,
  activeTrackColor: _wet,
  inactiveTrackColor: SetupSurfaceColors.line,
  thumbColor: _wet,
  overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
);

/// A reference to one effect within a monitored input's chain, used as the
/// drag payload when reordering (so a drop only lands on the same input).
@immutable
class _FxRef {
  const _FxRef(this.input, this.index);
  final int input;
  final int index;
}

/// The live input-monitoring configuration as one wired graph: hardware inputs
/// on the left, each *monitored* input as a node with its own effect chain in
/// the middle, and outputs on the right.
///
/// Each monitored input has two parallel sends, drawn as colour-coded edges:
/// the **effected (wet)** signal runs through the chain to its outputs (blue),
/// and the **clean (dry)** signal is sent, untouched, to its own outputs
/// (amber, dashed). Tap an input to start monitoring it and focus it; with an
/// input focused, the Effected/Dry toggle picks which send an output tap wires.
/// The graph zooms/pans and fits to view. Reads and drives the [MonitorCubit].
class MonitorGraphView extends StatefulWidget {
  /// Creates a [MonitorGraphView].
  const MonitorGraphView({
    required this.inputChannels,
    required this.outputChannels,
    this.excludedInputMask = 0,
    super.key,
  });

  /// Hardware input/output channel counts.
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, drawn dimmed and never monitorable.
  final int excludedInputMask;

  @override
  State<MonitorGraphView> createState() => _MonitorGraphViewState();
}

class _MonitorGraphViewState extends State<MonitorGraphView> {
  final TransformationController _tc = TransformationController();

  /// The effect currently being dragged to reorder, or null.
  _FxRef? _dragging;

  /// The input whose outputs are being wired, or null.
  int? _focused;

  /// Which send an output tap wires for the focused input: wet or dry.
  bool _wireDry = false;

  /// The selected (open-in-the-editor) effect, as `(input, index)`, or null.
  ({int input, int index})? _selected;

  /// Identity of the last fitted layout, so we re-fit only on structural
  /// changes (lane/effect count), not on every focus tap.
  Object? _fittedKey;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  MonitorCubit get _cubit => context.read<MonitorCubit>();

  int get _inCount => widget.inputChannels > 0 ? widget.inputChannels : 4;
  int get _outCount => widget.outputChannels > 0 ? widget.outputChannels : 2;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MonitorCubit>().state;
    final layout = _GraphLayout.compute(
      state: state,
      inCount: _inCount,
      outCount: _outCount,
      excludedMask: widget.excludedInputMask,
      focused: _focused,
    );
    return Column(
      children: [
        Expanded(child: _canvas(state, layout)),
        _RoutePanel(
          monitor: _focused == null ? null : state.forInput(_focused!),
          wireDry: _wireDry,
          selectedFx: _selectedEffect(state),
          onWireModeChanged: (dry) => setState(() => _wireDry = dry),
          onStop: () {
            final f = _focused!;
            unawaited(_cubit.setEnabled(f, enabled: false));
            setState(() {
              _focused = null;
              _selected = null;
            });
          },
          onSetType: (t) =>
              _cubit.setEffectType(_selected!.input, _selected!.index, t),
          onSetParam: (p, v) =>
              _cubit.setEffectParam(_selected!.input, _selected!.index, p, v),
          onRemove: () {
            _cubit.removeEffect(_selected!.input, _selected!.index);
            setState(() => _selected = null);
          },
        ),
      ],
    );
  }

  /// The selected effect, or null if the selection is stale.
  TrackEffect? _selectedEffect(MonitorState state) {
    final s = _selected;
    if (s == null || !state.forInput(s.input).enabled) return null;
    final effects = state.forInput(s.input).effects;
    return s.index < effects.length ? effects[s.index] : null;
  }

  // ---- canvas ----

  Widget _canvas(MonitorState state, _GraphLayout layout) {
    return ColoredBox(
      color: SetupSurfaceColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _maybeFit(constraints.maxWidth, constraints.maxHeight, layout);
          return ClipRect(
            child: InteractiveViewer(
              transformationController: _tc,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.3,
              maxScale: 3,
              child: SizedBox(
                width: layout.canvasW,
                height: layout.canvasH,
                child: Stack(children: _canvasChildren(state, layout)),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _canvasChildren(MonitorState state, _GraphLayout layout) {
    return [
      Positioned.fill(child: CustomPaint(painter: _PathPainter(layout.edges))),
      for (var c = 0; c < _inCount; c++) _inNode(state, layout, c),
      for (var c = 0; c < _outCount; c++) _outNode(state, layout, c),
      for (final c in layout.rows) ..._monitorRow(state, layout, c),
    ];
  }

  Iterable<Widget> _monitorRow(
    MonitorState state,
    _GraphLayout layout,
    int c,
  ) sync* {
    final y = layout.rowY(c);
    yield _positioned(
      layout.nodeX,
      y,
      _GraphLayout.nodeW,
      _GraphLayout.nodeH,
      _MonitorNode(
        input: c,
        focused: _focused == c,
        onTap: () => setState(() {
          _focused = _focused == c ? null : c;
          _selected = null;
        }),
      ),
    );
    final xs = layout.cardXs[c]!;
    for (var k = 0; k < xs.length; k++) {
      yield _positioned(
        xs[k],
        y,
        _GraphLayout.cardW,
        _GraphLayout.cardH,
        _FxCard(
          input: c,
          index: k,
          fx: state.forInput(c).effects[k],
          selected: _selected?.input == c && _selected?.index == k,
          dragging: _dragging?.input == c && _dragging?.index == k,
          onTap: () => setState(() {
            _focused = c;
            _selected = (_selected?.input == c && _selected?.index == k)
                ? null
                : (input: c, index: k);
          }),
          onDelete: () {
            _cubit.removeEffect(c, k);
            setState(() => _selected = null);
          },
          onDragStart: () => setState(() => _dragging = _FxRef(c, k)),
          onDragEnd: () => setState(() => _dragging = null),
          onReorder: (from) {
            _cubit.moveEffect(c, from, k);
            setState(() => _selected = null);
          },
        ),
      );
    }
    yield _positioned(
      layout.addFxX(c),
      y,
      _GraphLayout.addW,
      _GraphLayout.addW,
      _AddFxButton(
        input: c,
        full: state.forInput(c).effects.length >= kTrackEffectMax,
        onAdd: () {
          setState(() => _focused = c);
          _cubit.addEffect(c);
        },
      ),
    );
  }

  Positioned _positioned(
    double x,
    double y,
    double w,
    double h,
    Widget child,
  ) => Positioned(left: x, top: y - h / 2, width: w, height: h, child: child);

  Widget _inNode(MonitorState state, _GraphLayout layout, int c) {
    final excluded = layout.excluded(c);
    final monitored = state.forInput(c).enabled && !excluded;
    return _positioned(
      layout.inX,
      layout.inY(c),
      _GraphLayout.chW,
      _GraphLayout.chH,
      _ChannelNode(
        nodeKey: Key('monitorGraph_in_$c'),
        label: 'In ${c + 1}',
        color: _wet,
        strong: _focused == c,
        wired: monitored,
        excluded: excluded,
        onTap: excluded
            ? null
            : () {
                if (!monitored) unawaited(_cubit.setEnabled(c, enabled: true));
                setState(() {
                  _focused = c;
                  _selected = null;
                });
              },
      ),
    );
  }

  Widget _outNode(MonitorState state, _GraphLayout layout, int c) {
    final bit = 1 << c;
    final wiredWet = layout.wetUnion & bit != 0;
    final wiredDry = layout.dryUnion & bit != 0;
    final f = _focused;
    final focusWet = f != null && state.forInput(f).outputMask & bit != 0;
    final focusDry = f != null && state.forInput(f).dryOutputMask & bit != 0;
    // Colour by the focused input's send, else amber when only dry uses it.
    final color = focusDry || (f == null && wiredDry && !wiredWet)
        ? _dry
        : _wet;
    return _positioned(
      layout.outX,
      layout.outY(c),
      _GraphLayout.chW,
      _GraphLayout.chH,
      _ChannelNode(
        nodeKey: Key('monitorGraph_out_$c'),
        label: 'Out ${c + 1}',
        color: color,
        strong: focusWet || focusDry,
        wired: wiredWet || wiredDry,
        excluded: false,
        onTap: f == null
            ? null
            : () {
                final m = state.forInput(f);
                if (_wireDry) {
                  unawaited(_cubit.setDryOutputMask(f, m.dryOutputMask ^ bit));
                } else {
                  unawaited(_cubit.setOutputMask(f, m.outputMask ^ bit));
                }
              },
      ),
    );
  }

  void _maybeFit(double vw, double vh, _GraphLayout layout) {
    if (_fittedKey == layout.key || vw <= 0 || vh <= 0) return;
    _fittedKey = layout.key;
    var scale = vw / layout.canvasW;
    if (layout.canvasH * scale > vh) scale = vh / layout.canvasH;
    if (scale > 1) scale = 1;
    final m = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, (vw - layout.canvasW * scale) / 2)
      ..setEntry(1, 3, (vh - layout.canvasH * scale) / 2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }
}

// ===========================================================================
// Layout
// ===========================================================================

/// Pure geometry for one frame of the graph: node positions, card positions,
/// and the wires. Computed once per build from the monitor state, so the build
/// method composes widgets instead of threading a dozen coordinates around.
@immutable
class _GraphLayout {
  const _GraphLayout._({
    required this.rows,
    required this.cardXs,
    required this.edges,
    required this.wetUnion,
    required this.dryUnion,
    required this.canvasW,
    required this.canvasH,
    required this.inX,
    required this.nodeX,
    required this.outX,
    required this.excludedMask,
    required int inCount,
    required int outCount,
    required double rowsTop,
  }) : _inCount = inCount,
       _outCount = outCount,
       _rowsTop = rowsTop;

  factory _GraphLayout.compute({
    required MonitorState state,
    required int inCount,
    required int outCount,
    required int excludedMask,
    required int? focused,
  }) {
    bool isExcluded(int c) => excludedMask & (1 << c) != 0;
    final rows = [
      for (var c = 0; c < inCount; c++)
        if (state.forInput(c).enabled && !isExcluded(c)) c,
    ];

    const inX = pad;
    const nodeX = inX + chW + fanGap;
    const cardStartX = nodeX + nodeW + gap;

    final cardXs = <int, List<double>>{};
    var widestRight = cardStartX;
    for (final c in rows) {
      final xs = <double>[];
      var x = cardStartX;
      for (var k = 0; k < state.forInput(c).effects.length; k++) {
        xs.add(x);
        x += cardW + gap;
      }
      cardXs[c] = xs;
      widestRight = math.max(widestRight, x + addW);
    }
    final railX = widestRight;
    final outX = railX + fanGap;
    final canvasW = outX + chW + pad;

    final rowsBlockH = rows.length * rowH;
    final channelsH = math.max(inCount, outCount) * chRowH;
    final canvasH = math.max(rowsBlockH, channelsH) + pad * 2;
    final rowsTop = (canvasH - rowsBlockH) / 2;

    double chYAt(int i, int count) => canvasH / count * (i + 0.5);
    double rowYAt(int r) => rowsTop + r * rowH + rowH / 2;

    var wetUnion = 0;
    var dryUnion = 0;
    final edges = <_Edge>[];
    for (var r = 0; r < rows.length; r++) {
      final c = rows[r];
      final m = state.forInput(c);
      final y = rowYAt(r);
      final faded = focused != null && focused != c;
      wetUnion |= m.enabled ? m.outputMask : 0;
      dryUnion |= m.enabled ? m.dryOutputMask : 0;

      // input feed → monitor node
      if (!isExcluded(c)) {
        edges.add(
          _Edge(
            Offset(inX + chW, chYAt(c, inCount)),
            Offset(nodeX, y),
            color: _wet,
            faded: faded,
          ),
        );
      }
      // wet path: node → cards → last
      final xs = cardXs[c]!;
      var rightX = nodeX + nodeW;
      if (xs.isNotEmpty) {
        edges.add(
          _Edge(
            Offset(nodeX + nodeW, y),
            Offset(xs.first, y),
            color: _wet,
            faded: faded,
          ),
        );
        for (var k = 0; k < xs.length - 1; k++) {
          edges.add(
            _Edge(
              Offset(xs[k] + cardW, y),
              Offset(xs[k + 1], y),
              color: _wet,
              faded: faded,
            ),
          );
        }
        rightX = xs.last + cardW;
      }
      // last → wet outputs (along the row to the rail, then fan)
      _fan(
        edges,
        rightX,
        y,
        m.outputMask,
        railX,
        outX,
        outCount,
        chYAt,
        _wet,
        faded: faded,
        dashed: false,
      );
      // dry send: leaves the node BELOW the cards (so it never hides behind
      // them) and fans, dashed amber, to its own outputs.
      _fan(
        edges,
        nodeX + nodeW,
        y + dryDrop,
        m.dryOutputMask,
        railX,
        outX,
        outCount,
        chYAt,
        _dry,
        faded: faded,
        dashed: true,
      );
    }

    return _GraphLayout._(
      rows: rows,
      cardXs: cardXs,
      edges: edges,
      wetUnion: wetUnion,
      dryUnion: dryUnion,
      canvasW: canvasW,
      canvasH: canvasH,
      inX: inX,
      nodeX: nodeX,
      outX: outX,
      excludedMask: excludedMask,
      inCount: inCount,
      outCount: outCount,
      rowsTop: rowsTop,
    );
  }

  // Geometry constants. Inputs/outputs are small "channel" chips; a monitored
  // input is a wider node feeding a horizontal chain of effect cards.
  static const double chW = 54; // channel chip width
  static const double chH = 24; // channel chip height
  static const double chRowH = 32; // vertical pitch between channel chips
  static const double nodeW = 128; // monitor node width
  static const double nodeH = 50; // monitor node height
  static const double rowH = 80; // vertical pitch between monitor rows
  static const double cardW = 110; // effect card width
  static const double cardH = 38; // effect card height
  static const double gap = 16; // between effect cards
  static const double fanGap = 100; // input→node / rail→output gutter width
  static const double addW = 28; // add-effect button
  static const double pad = 16; // canvas padding
  static const double curveHandle = 48; // fixed bezier handle (uniform curves)
  static const double dryDrop = cardH / 2 + 10; // dry edge offset, clears cards

  /// Monitored input indices, in input order (one middle row each).
  final List<int> rows;

  /// Per monitored input: the x of each effect card.
  final Map<int, List<double>> cardXs;

  /// The wires to paint.
  final List<_Edge> edges;

  /// Outputs reached by any monitor's wet / dry send (for node colouring).
  final int wetUnion;
  final int dryUnion;

  final double canvasW;
  final double canvasH;
  final double inX;
  final double nodeX;
  final double outX;
  final int excludedMask;

  final int _inCount;
  final int _outCount;
  final double _rowsTop;

  bool excluded(int c) => excludedMask & (1 << c) != 0;
  double inY(int c) => canvasH / _inCount * (c + 0.5);
  double outY(int c) => canvasH / _outCount * (c + 0.5);
  double rowY(int input) => _rowsTop + rows.indexOf(input) * rowH + rowH / 2;
  double addFxX(int input) {
    final xs = cardXs[input]!;
    return xs.isEmpty ? nodeX + nodeW + gap : xs.last + cardW + gap;
  }

  /// Re-fit identity: the canvas only changes shape when the row/effect counts
  /// or channel counts change.
  Object get key => Object.hashAll([
    _inCount,
    _outCount,
    for (final c in rows) cardXs[c]!.length,
  ]);

  static void _fan(
    List<_Edge> edges,
    double fromX,
    double fromY,
    int mask,
    double railX,
    double outX,
    int outCount,
    double Function(int, int) chYAt,
    Color color, {
    required bool faded,
    required bool dashed,
  }) {
    final outs = [
      for (var o = 0; o < outCount; o++)
        if (mask & (1 << o) != 0) o,
    ];
    if (outs.isEmpty) return;
    if (railX > fromX + 0.5) {
      edges.add(
        _Edge(
          Offset(fromX, fromY),
          Offset(railX, fromY),
          color: color,
          faded: faded,
          dashed: dashed,
        ),
      );
    }
    for (final o in outs) {
      edges.add(
        _Edge(
          Offset(railX, fromY),
          Offset(outX, chYAt(o, outCount)),
          color: color,
          faded: faded,
          dashed: dashed,
        ),
      );
    }
  }
}

// ===========================================================================
// Node + card widgets
// ===========================================================================

/// One hardware input/output port chip.
class _ChannelNode extends StatelessWidget {
  const _ChannelNode({
    required this.nodeKey,
    required this.label,
    required this.color,
    required this.strong,
    required this.wired,
    required this.excluded,
    required this.onTap,
  });

  final Key nodeKey;
  final String label;
  final Color color;
  final bool strong;
  final bool wired;
  final bool excluded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final border = excluded
        ? SetupSurfaceColors.line
        : strong
        ? color
        : wired
        ? color.withValues(alpha: 0.7)
        : SetupSurfaceColors.line.withValues(alpha: 0.6);
    return _Tappable(
      nodeKey: nodeKey,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: !excluded && strong
              ? color.withValues(alpha: 0.28)
              : SetupSurfaceColors.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: strong ? 1.6 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: excluded
                ? SetupSurfaceColors.t3
                : wired
                ? SetupSurfaceColors.t1
                : SetupSurfaceColors.t3,
            decoration: excluded ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }
}

/// A monitored input's node (feeds its effect chain).
class _MonitorNode extends StatelessWidget {
  const _MonitorNode({
    required this.input,
    required this.focused,
    required this.onTap,
  });

  final int input;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Tappable(
      nodeKey: Key('monitorGraph_node_$input'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _wet.withValues(alpha: focused ? 0.3 : 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _wet, width: focused ? 2.5 : 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'In ${input + 1} monitor',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: SetupSurfaceColors.t1,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
            const Text(
              'live · not recorded',
              style: TextStyle(
                color: SetupSurfaceColors.t2,
                fontSize: 10,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One effect card on a monitor's wet path: a drag handle (reorder), a tappable
/// label (edit), and a delete button. Accepts a same-input drop to reorder.
class _FxCard extends StatelessWidget {
  const _FxCard({
    required this.input,
    required this.index,
    required this.fx,
    required this.selected,
    required this.dragging,
    required this.onTap,
    required this.onDelete,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onReorder,
  });

  final int input;
  final int index;
  final TrackEffect fx;
  final bool selected;
  final bool dragging;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final void Function(int from) onReorder;

  static BoxDecoration decoration({required bool selected}) => BoxDecoration(
    color: SetupSurfaceColors.cardHi,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: selected ? _wet : _wet.withValues(alpha: 0.45),
      width: selected ? 2 : 1,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DragTarget<_FxRef>(
      onWillAcceptWithDetails: (d) => d.data.input == input,
      onAcceptWithDetails: (d) => onReorder(d.data.index),
      builder: (context, candidate, _) => Container(
        key: Key('monitorGraph_fx_${input}_$index'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: decoration(selected: selected || candidate.isNotEmpty)
            .copyWith(
              color: SetupSurfaceColors.cardHi.withValues(
                alpha: dragging ? 0.4 : 1,
              ),
            ),
        child: Row(
          children: [
            Draggable<_FxRef>(
              key: Key('monitorGraph_fxHandle_${input}_$index'),
              data: _FxRef(input, index),
              onDragStarted: onDragStart,
              onDragEnd: (_) => onDragEnd(),
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: _GraphLayout.cardW,
                  height: _GraphLayout.cardH,
                  child: DecoratedBox(
                    decoration: decoration(selected: true),
                    child: Center(
                      child: Text(
                        fx.type.label,
                        style: const TextStyle(color: SetupSurfaceColors.t1),
                      ),
                    ),
                  ),
                ),
              ),
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Icon(
                  Icons.drag_indicator,
                  size: 16,
                  color: SetupSurfaceColors.t3,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _Tappable(
                nodeKey: Key('monitorGraph_fxLabel_${input}_$index'),
                onTap: onTap,
                child: Text(
                  fx.type.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SetupSurfaceColors.t1),
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkResponse(
              key: Key('monitorGraph_fxDelete_${input}_$index'),
              onTap: onDelete,
              radius: 15,
              child: const SizedBox(
                width: 18,
                height: 24,
                child: Icon(
                  Icons.close,
                  size: 15,
                  color: SetupSurfaceColors.t2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "add an effect" button at the end of a monitor's chain.
class _AddFxButton extends StatelessWidget {
  const _AddFxButton({
    required this.input,
    required this.full,
    required this.onAdd,
  });

  final int input;
  final bool full;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IconButton(
        key: Key('monitorGraph_addFx_$input'),
        iconSize: 22,
        color: _wet,
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: SetupSurfaceColors.surface,
          shape: const CircleBorder(),
        ),
        tooltip: full ? 'Chain is full' : 'Add effect to input ${input + 1}',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: full ? null : onAdd,
      ),
    );
  }
}

// ===========================================================================
// Bottom panel
// ===========================================================================

/// The docked controls below the canvas: a hint when nothing is focused, else
/// the focused input's wet/dry toggle, stop button, selected-effect editor,
/// and the wet/dry legend.
class _RoutePanel extends StatelessWidget {
  const _RoutePanel({
    required this.monitor,
    required this.wireDry,
    required this.selectedFx,
    required this.onWireModeChanged,
    required this.onStop,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
  });

  final InputMonitor? monitor;
  final bool wireDry;
  final TrackEffect? selectedFx;
  final ValueChanged<bool> onWireModeChanged;
  final VoidCallback onStop;
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final focused = monitor?.enabled ?? false;
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
          if (!focused)
            const Text(
              'Tap an input to monitor it, then tap outputs to send it there.',
              style: TextStyle(color: SetupSurfaceColors.t2, fontSize: 13),
            )
          else
            _focusControls(monitor!),
          if (focused && selectedFx != null) ...[
            const SizedBox(height: 10),
            _EffectEditor(
              fx: selectedFx!,
              onSetType: onSetType,
              onSetParam: onSetParam,
              onRemove: onRemove,
            ),
          ],
          const SizedBox(height: 10),
          const _Legend(),
        ],
      ),
    );
  }

  Widget _focusControls(InputMonitor m) {
    return Row(
      children: [
        Text(
          'In ${m.input + 1} monitor',
          style: const TextStyle(
            color: SetupSurfaceColors.t1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 12),
        SegmentedButton<bool>(
          key: const Key('monitorGraph_routeToggle'),
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Effected'),
              icon: Icon(Icons.graphic_eq, size: 16),
            ),
            ButtonSegment(
              value: true,
              label: Text('Dry'),
              icon: Icon(Icons.water_drop_outlined, size: 16),
            ),
          ],
          selected: {wireDry},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onWireModeChanged(s.first),
        ),
        const Spacer(),
        TextButton.icon(
          key: const Key('monitorGraph_stop'),
          onPressed: onStop,
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
          label: const Text('Stop'),
          style: TextButton.styleFrom(foregroundColor: SetupSurfaceColors.t2),
        ),
      ],
    );
  }
}

/// The inline editor for the selected effect: type + parameter sliders.
class _EffectEditor extends StatelessWidget {
  const _EffectEditor({
    required this.fx,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
  });

  final TrackEffect fx;
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('monitorGraph_fxEditor'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _wet),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<TrackEffectType>(
                  key: const Key('monitorGraph_fxType'),
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
                      onSetType(type);
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
                key: const Key('monitorGraph_fxRemove'),
                iconSize: 18,
                color: SetupSurfaceColors.t2,
                tooltip: 'Remove effect',
                icon: const Icon(Icons.delete_outline),
                onPressed: onRemove,
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
                      data: _paramSliderTheme,
                      child: Slider(
                        key: Key('monitorGraph_fxParam$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) => onSetParam(p, v),
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

/// The wet/dry colour legend.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _LegendKey(color: _wet, label: 'effected (wet) → outs', dashed: false),
        SizedBox(width: 20),
        _LegendKey(color: _dry, label: 'clean (dry) → outs', dashed: true),
      ],
    );
  }
}

class _LegendKey extends StatelessWidget {
  const _LegendKey({
    required this.color,
    required this.label,
    required this.dashed,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 26,
          height: 12,
          child: CustomPaint(
            painter: _LegendLinePainter(color, dashed: dashed),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: SetupSurfaceColors.t2, fontSize: 12),
        ),
      ],
    );
  }
}

// ===========================================================================
// Painters + helpers
// ===========================================================================

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

/// One wire. A value type so the painter can skip repaints when unchanged.
@immutable
class _Edge {
  const _Edge(
    this.from,
    this.to, {
    required this.color,
    this.faded = false,
    this.dashed = false,
  });
  final Offset from;
  final Offset to;
  final Color color;

  /// A wire on a lane other than the focused one — drawn thin and dim.
  final bool faded;
  final bool dashed;

  @override
  bool operator ==(Object other) =>
      other is _Edge &&
      other.from == from &&
      other.to == to &&
      other.color == color &&
      other.faded == faded &&
      other.dashed == dashed;

  @override
  int get hashCode => Object.hash(from, to, color, faded, dashed);
}

class _PathPainter extends CustomPainter {
  _PathPainter(this.edges);

  final List<_Edge> edges;

  void _draw(Canvas canvas, _Edge e) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = e.faded ? 1.4 : 2.4
      ..color = e.color.withValues(alpha: e.faded ? 0.22 : 0.95);
    // A fixed handle length (clamped so short hops stay straight) gives every
    // wire the same horizontal tangent — uniform curvature across the graph.
    final span = (e.to.dx - e.from.dx).abs();
    final dx = math.min(span / 2, _GraphLayout.curveHandle);
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
    if (e.dashed) {
      for (final metric in path.computeMetrics()) {
        var d = 0.0;
        while (d < metric.length) {
          canvas.drawPath(metric.extractPath(d, d + 6), paint);
          d += 11;
        }
      }
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Faded wires first so the focused input's wires sit on top.
    for (final e in edges) {
      if (e.faded) _draw(canvas, e);
    }
    for (final e in edges) {
      if (!e.faded) _draw(canvas, e);
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) => !listEquals(old.edges, edges);
}

/// Draws a short solid/dashed colour swatch for the wet/dry legend.
class _LegendLinePainter extends CustomPainter {
  _LegendLinePainter(this.color, {required this.dashed});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = color;
    final y = size.height / 2;
    if (dashed) {
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(x + 5, y), paint);
        x += 9;
      }
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_LegendLinePainter old) =>
      old.color != color || old.dashed != dashed;
}
