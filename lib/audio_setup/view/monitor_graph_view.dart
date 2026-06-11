import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/common/routing_graph/channel_chip.dart';
import 'package:loopy/common/routing_graph/effect_chain_card.dart';
import 'package:loopy/common/routing_graph/effect_params_editor.dart';
import 'package:loopy/common/routing_graph/graph_canvas.dart';
import 'package:loopy/common/routing_graph/graph_colors.dart';
import 'package:loopy/common/routing_graph/graph_edge.dart';
import 'package:loopy/common/routing_graph/graph_edge_painter.dart';
import 'package:loopy/common/routing_graph/graph_geometry.dart';
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

/// Send-role colours, from the shared kit. Wet = effected, dry = clean.
const Color _wet = kWetRouteColor;
const Color _dry = kDryRouteColor;

/// The live input-monitoring configuration as one wired graph: hardware inputs
/// on the left, each *monitored* input as a node with its own effect chain in
/// the middle, and outputs on the right.
///
/// Each monitored input has two parallel sends, drawn as colour-coded edges:
/// the **effected (wet)** signal runs through the chain to its outputs (blue),
/// and the **clean (dry)** signal is sent, untouched, to its own outputs
/// (amber, dashed). Tap an input to start monitoring it and focus it; with an
/// input focused, the Effected/Dry toggle picks which send an output tap wires.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph kit (`lib/common/routing_graph`); this view owns the monitor-specific
/// assembly: the dual-route geometry, the node body, the Stop / Effected-Dry
/// controls, the wet/dry legend, and the internal selection that drives the
/// [MonitorCubit].
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
  /// The effect currently being dragged to reorder, or null.
  GraphCardRef? _dragging;

  /// The input whose outputs are being wired, or null.
  int? _focused;

  /// Which send an output tap wires for the focused input: wet or dry.
  bool _wireDry = false;

  /// The selected (open-in-the-editor) effect, as `(input, index)`, or null.
  ({int input, int index})? _selected;

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
    return GraphCanvas(
      width: layout.canvasW,
      height: layout.canvasH,
      fitIdentity: layout.fitIdentity,
      children: [
        Positioned.fill(
          child: CustomPaint(painter: GraphEdgePainter(layout.edges)),
        ),
        for (var c = 0; c < _inCount; c++) _inNode(state, layout, c),
        for (var c = 0; c < _outCount; c++) _outNode(state, layout, c),
        for (final c in layout.rows) ..._monitorRow(state, layout, c),
      ],
    );
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
    // Insertion drop zones in the gaps before/after each card (the cards
    // themselves are the drag sources) — the same gap-index convention as the
    // lane graph, so a reorder behaves identically in both views.
    for (final zone in _dropZones(layout, c, xs, y)) {
      yield zone;
    }
    for (var k = 0; k < xs.length; k++) {
      yield _positioned(
        xs[k],
        y,
        _GraphLayout.cardW,
        _GraphLayout.cardH,
        EffectChainCard(
          cardKey: Key('monitorGraph_fx_${c}_$k'),
          handleKey: Key('monitorGraph_fxHandle_${c}_$k'),
          labelKey: Key('monitorGraph_fxLabel_${c}_$k'),
          deleteKey: Key('monitorGraph_fxDelete_${c}_$k'),
          label: state.forInput(c).effects[k].type.label,
          accentColor: _wet,
          selected: _selected?.input == c && _selected?.index == k,
          dragging: _dragging?.rowId == c && _dragging?.index == k,
          rowId: c,
          index: k,
          cardW: _GraphLayout.cardW,
          cardH: _GraphLayout.cardH,
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
          onDragStart: () => setState(() => _dragging = GraphCardRef(c, k)),
          onDragEnd: () => setState(() => _dragging = null),
        ),
      );
    }
    yield _positioned(
      layout.addFxX(c),
      y,
      _GraphLayout.addW,
      _GraphLayout.addW,
      AddEffectButton(
        buttonKey: Key('monitorGraph_addFx_$c'),
        accentColor: _wet,
        full: state.forInput(c).effects.length >= kTrackEffectMax,
        tooltip: 'Add effect to input ${c + 1}',
        iconSize: 22,
        onAdd: () {
          setState(() => _focused = c);
          _cubit.addEffect(c);
        },
      ),
    );
  }

  /// Drop targets in the gaps around input [c]'s cards. The gap index is the
  /// insertion slot passed to [MonitorCubit.moveEffect] (which clamps it), so
  /// it matches the lane graph's convention exactly.
  Iterable<Widget> _dropZones(
    _GraphLayout layout,
    int c,
    List<double> xs,
    double y,
  ) sync* {
    const gap = _GraphLayout.gap;
    const cardW = _GraphLayout.cardW;
    final spots = <double>[];
    if (xs.isEmpty) {
      spots.add(_GraphLayout.cardStartX);
    } else {
      for (final x in xs) {
        spots.add(x - gap);
      }
      spots.add(xs.last + cardW);
    }
    for (var pos = 0; pos < spots.length; pos++) {
      yield Positioned(
        left: spots[pos],
        top: y - _GraphLayout.cardH / 2 - 6,
        width: gap + 10,
        height: _GraphLayout.cardH + 12,
        child: EffectDropZone(
          dropKey: Key('monitorGraph_drop_${c}_$pos'),
          rowId: c,
          accentColor: _wet,
          caretHeight: _GraphLayout.cardH,
          onAccept: (from) {
            _cubit.moveEffect(c, from, pos);
            setState(() => _selected = null);
          },
        ),
      );
    }
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
      ChannelChip(
        key: Key('monitorGraph_in_$c'),
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
      ChannelChip(
        key: Key('monitorGraph_out_$c'),
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
      final xs = cardColumnXs(
        startX: cardStartX,
        count: state.forInput(c).effects.length,
        cardW: cardW,
        gap: gap,
      );
      cardXs[c] = xs;
      final rowRight = (xs.isEmpty ? cardStartX : xs.last + cardW + gap) + addW;
      widestRight = math.max(widestRight, rowRight);
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
    final edges = <GraphEdge>[];
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
          GraphEdge(
            Offset(inX + chW, chYAt(c, inCount)),
            Offset(nodeX, y),
            color: _wet,
            faded: faded,
          ),
        );
      }
      // wet path: node → cards → last
      final xs = cardXs[c]!;
      edges.addAll(
        chainEdges(
          nodeRight: nodeX + nodeW,
          y: y,
          cardXs: xs,
          cardW: cardW,
          color: _wet,
          faded: faded,
        ),
      );
      final rightX = xs.isEmpty ? nodeX + nodeW : xs.last + cardW;
      // Two parallel sends: wet from the chain tail, dry from below the node
      // (so it never hides behind the cards), each fanned to its own outputs.
      edges.addAll(
        fanEdges(
          sends: [
            GraphSend(
              originX: rightX,
              originY: y,
              mask: m.outputMask,
              color: _wet,
            ),
            GraphSend(
              originX: nodeX + nodeW,
              originY: y + dryDrop,
              mask: m.dryOutputMask,
              color: _dry,
              dashed: true,
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
  // The dry edge leaves below the node so it clears the cards.
  static const double dryDrop = cardH / 2 + 10;

  /// The x at which the first effect card sits (also the empty-chain drop spot).
  static const double cardStartX = pad + chW + fanGap + nodeW + gap;

  /// Monitored input indices, in input order (one middle row each).
  final List<int> rows;

  /// Per monitored input: the x of each effect card.
  final Map<int, List<double>> cardXs;

  /// The wires to paint.
  final List<GraphEdge> edges;

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

  /// Re-fit identity: a structural value list (compared with `listEquals`), so
  /// the canvas re-fits only when the row/effect counts or channel counts
  /// change — not when a row is focused or a mask toggled.
  List<Object?> get fitIdentity => [
    _inCount,
    _outCount,
    for (final c in rows) cardXs[c]!.length,
  ];
}

// ===========================================================================
// Node + bottom panel
// ===========================================================================

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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('monitorGraph_node_$input'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
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
      ),
    );
  }
}

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
            EffectParamsEditor(
              editorKey: const Key('monitorGraph_fxEditor'),
              typeKey: const Key('monitorGraph_fxType'),
              removeKey: const Key('monitorGraph_fxRemove'),
              paramKey: (p) => Key('monitorGraph_fxParam$p'),
              fx: selectedFx!,
              accentColor: _wet,
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
