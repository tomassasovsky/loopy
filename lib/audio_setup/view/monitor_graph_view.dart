import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';

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
/// input focused, the wet/dry toggle below picks which send an output tap
/// wires. The graph zooms/pans and fits to view. Reads and drives the
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

  static const Color _wet = Color(0xFF3B82F6); // effected
  static const Color _dry = Color(0xFFF59E0B); // clean

  // ---- geometry ----
  static const double _chW = 54;
  static const double _chH = 24;
  static const double _nodeW = 116;
  static const double _nodeH = 40;
  static const double _cardW = 110;
  static const double _cardH = 38;
  static const double _gap = 16;
  static const double _fan = 92;
  static const double _addW = 28;
  static const double _rowH = 80;
  static const double _chRowH = 32;
  static const double _pad = 16;
  static const double _curveHandle = 46;

  @override
  State<MonitorGraphView> createState() => _MonitorGraphViewState();
}

class _MonitorGraphViewState extends State<MonitorGraphView> {
  final TransformationController _tc = TransformationController();
  _FxRef? _dragging;

  /// The input whose outputs are being wired, or null.
  int? _focused;

  /// Which send an output tap wires for the focused input: wet or dry.
  bool _wireDry = false;

  /// The selected (open-in-the-editor) effect, as `(input, index)`, or null.
  ({int input, int index})? _selected;

  int _fittedKey = -1;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  MonitorCubit get _cubit => context.read<MonitorCubit>();

  int get _inCount => widget.inputChannels > 0 ? widget.inputChannels : 4;
  int get _outCount => widget.outputChannels > 0 ? widget.outputChannels : 2;

  bool _excluded(int c) => widget.excludedInputMask & (1 << c) != 0;

  /// Monitored (enabled) input indices, in input order — one middle row each.
  List<int> _monitored(MonitorState s) => [
    for (var c = 0; c < _inCount; c++)
      if (s.forInput(c).enabled && !_excluded(c)) c,
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MonitorCubit>().state;
    return Column(
      children: [
        Expanded(child: _canvas(state)),
        _panel(state),
      ],
    );
  }

  // ---- canvas ----

  Widget _canvas(MonitorState state) {
    const g = MonitorGraphView._gap;
    const chW = MonitorGraphView._chW;
    const nodeW = MonitorGraphView._nodeW;
    const cardW = MonitorGraphView._cardW;
    const addW = MonitorGraphView._addW;
    const inX = MonitorGraphView._pad;
    const nodeX = inX + chW + MonitorGraphView._fan;
    const cardStartX = nodeX + nodeW + g;

    final rows = _monitored(state);

    // Per monitored input: card x positions + the row's right edge.
    final cardXs = <int, List<double>>{};
    var widestRight = cardStartX;
    for (final c in rows) {
      final xs = <double>[];
      var x = cardStartX;
      for (var k = 0; k < state.forInput(c).effects.length; k++) {
        xs.add(x);
        x += cardW + g;
      }
      cardXs[c] = xs;
      final right = x + addW;
      if (right > widestRight) widestRight = right;
    }
    final outX = widestRight + MonitorGraphView._fan;
    final canvasW = outX + chW + MonitorGraphView._pad;

    final rowsBlockH = rows.length * MonitorGraphView._rowH;
    final channelsH =
        (_inCount > _outCount ? _inCount : _outCount) *
        MonitorGraphView._chRowH;
    final canvasH =
        (rowsBlockH > channelsH ? rowsBlockH : channelsH) +
        MonitorGraphView._pad * 2;
    final rowsTop = (canvasH - rowsBlockH) / 2;

    double rowY(int r) =>
        rowsTop + r * MonitorGraphView._rowH + MonitorGraphView._rowH / 2;
    double chY(int i, int count) => canvasH / count * (i + 0.5);
    final rowOf = {for (var r = 0; r < rows.length; r++) rows[r]: r};

    final edges = _edges(
      state: state,
      rows: rows,
      rowOf: rowOf,
      cardXs: cardXs,
      nodeX: nodeX,
      inX: inX,
      outX: outX,
      rowY: rowY,
      chY: chY,
    );

    final layoutKey = Object.hashAll([
      rows.length,
      for (final c in rows) state.forInput(c).effects.length,
      _inCount,
      _outCount,
    ]);

    return ColoredBox(
      color: SetupSurfaceColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _maybeFit(
            constraints.maxWidth,
            constraints.maxHeight,
            canvasW,
            canvasH,
            layoutKey,
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
                      _inNode(state, c, inX, chY(c, _inCount)),
                    for (var c = 0; c < _outCount; c++)
                      _outNode(state, c, outX, chY(c, _outCount)),
                    for (final c in rows) ...[
                      _monitorNode(state, c, nodeX, rowY(rowOf[c]!)),
                      for (var k = 0; k < cardXs[c]!.length; k++)
                        _fxCard(state, c, k, cardXs[c]![k], rowY(rowOf[c]!)),
                      _addFxButton(
                        state,
                        c,
                        cardXs[c]!.isEmpty
                            ? cardStartX
                            : cardXs[c]!.last + cardW + g,
                        rowY(rowOf[c]!),
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

  void _maybeFit(double vw, double vh, double cw, double ch, int key) {
    if (_fittedKey == key || vw <= 0 || vh <= 0) return;
    _fittedKey = key;
    var scale = vw / cw;
    if (ch * scale > vh) scale = vh / ch;
    if (scale > 1) scale = 1;
    final m = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, (vw - cw * scale) / 2)
      ..setEntry(1, 3, (vh - ch * scale) / 2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = m;
    });
  }

  List<_Edge> _edges({
    required MonitorState state,
    required List<int> rows,
    required Map<int, int> rowOf,
    required Map<int, List<double>> cardXs,
    required double nodeX,
    required double inX,
    required double outX,
    required double Function(int) rowY,
    required double Function(int, int) chY,
  }) {
    const chW = MonitorGraphView._chW;
    const nodeW = MonitorGraphView._nodeW;
    const cardW = MonitorGraphView._cardW;
    final railX = outX - MonitorGraphView._fan;
    final edges = <_Edge>[];
    for (final c in rows) {
      final m = state.forInput(c);
      final y = rowY(rowOf[c]!);
      final faded = _focused != null && _focused != c;
      // input feed -> monitor node
      edges.add(
        _Edge(
          Offset(inX + chW, chY(c, _inCount)),
          Offset(nodeX, y),
          color: MonitorGraphView._wet,
          faded: faded,
        ),
      );
      // wet path: node -> cards -> last -> wet outputs
      final xs = cardXs[c]!;
      var rightX = nodeX + nodeW;
      if (xs.isNotEmpty) {
        edges.add(
          _Edge(
            Offset(nodeX + nodeW, y),
            Offset(xs.first, y),
            color: MonitorGraphView._wet,
            faded: faded,
          ),
        );
        for (var k = 0; k < xs.length - 1; k++) {
          edges.add(
            _Edge(
              Offset(xs[k] + cardW, y),
              Offset(xs[k + 1], y),
              color: MonitorGraphView._wet,
              faded: faded,
            ),
          );
        }
        rightX = xs.last + cardW;
      }
      _fan(
        edges,
        rightX,
        y,
        m.outputMask,
        railX,
        outX,
        chY,
        MonitorGraphView._wet,
        faded,
        false,
      );
      // dry send: node -> dry outputs (amber, dashed), just below the row so it
      // reads as bypassing the effects.
      _fan(
        edges,
        nodeX + nodeW,
        y + 14,
        m.dryOutputMask,
        railX,
        outX,
        chY,
        MonitorGraphView._dry,
        faded,
        true,
      );
    }
    return edges;
  }

  void _fan(
    List<_Edge> edges,
    double fromX,
    double fromY,
    int mask,
    double railX,
    double outX,
    double Function(int, int) chY,
    Color color,
    bool faded,
    bool dashed,
  ) {
    final outs = [
      for (var o = 0; o < _outCount; o++)
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
          Offset(outX, chY(o, _outCount)),
          color: color,
          faded: faded,
          dashed: dashed,
        ),
      );
    }
  }

  // ---- nodes ----

  Widget _inNode(MonitorState state, int c, double x, double y) {
    final excluded = _excluded(c);
    final monitored = state.forInput(c).enabled && !excluded;
    final focused = _focused == c;
    return _chNode(
      key: 'monitorGraph_in_$c',
      label: 'In ${c + 1}',
      x: x,
      y: y,
      color: MonitorGraphView._wet,
      strong: focused,
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
    );
  }

  Widget _outNode(MonitorState state, int c, double x, double y) {
    // Wired if any monitor routes to it (wet or dry); coloured by the focused
    // input's send when one is focused.
    final wetAny = [
      for (var i = 0; i < _inCount; i++)
        if (state.forInput(i).enabled &&
            state.forInput(i).outputMask & (1 << c) != 0)
          i,
    ];
    final dryAny = [
      for (var i = 0; i < _inCount; i++)
        if (state.forInput(i).enabled &&
            state.forInput(i).dryOutputMask & (1 << c) != 0)
          i,
    ];
    final f = _focused;
    final focusWet = f != null && state.forInput(f).outputMask & (1 << c) != 0;
    final focusDry =
        f != null && state.forInput(f).dryOutputMask & (1 << c) != 0;
    final color = focusDry || (f == null && dryAny.isNotEmpty && wetAny.isEmpty)
        ? MonitorGraphView._dry
        : MonitorGraphView._wet;
    return _chNode(
      key: 'monitorGraph_out_$c',
      label: 'Out ${c + 1}',
      x: x,
      y: y,
      color: color,
      strong: focusWet || focusDry,
      wired: wetAny.isNotEmpty || dryAny.isNotEmpty,
      excluded: false,
      onTap: f == null
          ? null
          : () {
              if (_wireDry) {
                unawaited(
                  _cubit.setDryOutputMask(
                    f,
                    state.forInput(f).dryOutputMask ^ (1 << c),
                  ),
                );
              } else {
                unawaited(
                  _cubit.setOutputMask(
                    f,
                    state.forInput(f).outputMask ^ (1 << c),
                  ),
                );
              }
            },
    );
  }

  Widget _chNode({
    required String key,
    required String label,
    required double x,
    required double y,
    required Color color,
    required bool strong,
    required bool wired,
    required bool excluded,
    required VoidCallback? onTap,
  }) {
    final border = excluded
        ? SetupSurfaceColors.line
        : strong
        ? color
        : wired
        ? color.withValues(alpha: 0.7)
        : SetupSurfaceColors.line.withValues(alpha: 0.6);
    return Positioned(
      left: x,
      top: y - MonitorGraphView._chH / 2,
      width: MonitorGraphView._chW,
      height: MonitorGraphView._chH,
      child: _Tappable(
        nodeKey: Key(key),
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
      ),
    );
  }

  Widget _monitorNode(MonitorState state, int c, double x, double y) {
    final focused = _focused == c;
    return Positioned(
      left: x,
      top: y - MonitorGraphView._nodeH / 2,
      width: MonitorGraphView._nodeW,
      height: MonitorGraphView._nodeH,
      child: _Tappable(
        nodeKey: Key('monitorGraph_node_$c'),
        onTap: () => setState(() {
          _focused = focused ? null : c;
          _selected = null;
        }),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: MonitorGraphView._wet.withValues(
              alpha: focused ? 0.3 : 0.16,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: MonitorGraphView._wet,
              width: focused ? 2.5 : 1.5,
            ),
          ),
          child: Text(
            'In ${c + 1} monitor',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: SetupSurfaceColors.t1,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _fxCard(MonitorState state, int c, int k, double x, double y) {
    final fx = state.forInput(c).effects[k];
    final selected = _selected?.input == c && _selected?.index == k;
    final dragging = _dragging?.input == c && _dragging?.index == k;
    final handle = Draggable<_FxRef>(
      key: Key('monitorGraph_fxHandle_${c}_$k'),
      data: _FxRef(c, k),
      onDragStarted: () => setState(() => _dragging = _FxRef(c, k)),
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
      top: y - MonitorGraphView._cardH / 2,
      width: MonitorGraphView._cardW,
      height: MonitorGraphView._cardH,
      child: DragTarget<_FxRef>(
        onWillAcceptWithDetails: (d) => d.data.input == c,
        onAcceptWithDetails: (d) => _cubit.moveEffect(c, d.data.index, k),
        builder: (context, candidate, _) => Container(
          key: Key('monitorGraph_fx_${c}_$k'),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: SetupSurfaceColors.cardHi.withValues(
              alpha: dragging ? 0.4 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected || candidate.isNotEmpty
                  ? MonitorGraphView._wet
                  : MonitorGraphView._wet.withValues(alpha: 0.45),
              width: selected || candidate.isNotEmpty ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              handle,
              const SizedBox(width: 4),
              Expanded(
                child: _Tappable(
                  nodeKey: Key('monitorGraph_fxLabel_${c}_$k'),
                  onTap: () => setState(() {
                    _focused = c;
                    _selected = selected ? null : (input: c, index: k);
                  }),
                  child: Text(
                    fx.type.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: SetupSurfaceColors.t1),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              InkResponse(
                key: Key('monitorGraph_fxDelete_${c}_$k'),
                onTap: () => _cubit.removeEffect(c, k),
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
      ),
    );
  }

  Widget _chip(TrackEffect fx) => Container(
    width: MonitorGraphView._cardW,
    height: MonitorGraphView._cardH,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: SetupSurfaceColors.cardHi,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: MonitorGraphView._wet),
    ),
    child: Text(
      fx.type.label,
      style: const TextStyle(color: SetupSurfaceColors.t1),
    ),
  );

  Widget _addFxButton(MonitorState state, int c, double x, double y) {
    final full = state.forInput(c).effects.length >= kTrackEffectMax;
    return Positioned(
      left: x,
      top: y - MonitorGraphView._addW / 2,
      width: MonitorGraphView._addW,
      height: MonitorGraphView._addW,
      child: Center(
        child: IconButton(
          key: Key('monitorGraph_addFx_$c'),
          iconSize: 22,
          color: MonitorGraphView._wet,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: SetupSurfaceColors.surface,
            shape: const CircleBorder(),
          ),
          tooltip: full ? 'Chain is full' : 'Add effect to input ${c + 1}',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: full
              ? null
              : () {
                  setState(() => _focused = c);
                  _cubit.addEffect(c);
                },
        ),
      ),
    );
  }

  // ---- bottom panel ----

  Widget _panel(MonitorState state) {
    final f = _focused;
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
          if (f == null || !state.forInput(f).enabled)
            const Text(
              'Tap an input to monitor it, then tap outputs to send it there.',
              style: TextStyle(color: SetupSurfaceColors.t2, fontSize: 13),
            )
          else
            _focusControls(state, f),
          if (_selected case final s?
              when state.forInput(s.input).enabled &&
                  s.index < state.forInput(s.input).effects.length) ...[
            const SizedBox(height: 10),
            _fxEditor(
              s.input,
              s.index,
              state.forInput(s.input).effects[s.index],
            ),
          ],
        ],
      ),
    );
  }

  Widget _focusControls(MonitorState state, int f) {
    return Row(
      children: [
        Text(
          'In ${f + 1} monitor',
          style: const TextStyle(
            color: SetupSurfaceColors.t1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 12),
        // Which send an output tap wires.
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
          selected: {_wireDry},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _wireDry = s.first),
        ),
        const Spacer(),
        TextButton.icon(
          key: const Key('monitorGraph_stop'),
          onPressed: () {
            unawaited(_cubit.setEnabled(f, enabled: false));
            setState(() {
              if (_focused == f) _focused = null;
              _selected = null;
            });
          },
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
          label: const Text('Stop'),
          style: TextButton.styleFrom(foregroundColor: SetupSurfaceColors.t2),
        ),
      ],
    );
  }

  Widget _fxEditor(int input, int index, TrackEffect fx) {
    return Container(
      key: const Key('monitorGraph_fxEditor'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MonitorGraphView._wet),
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
                      _cubit.setEffectType(input, index, type);
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
                onPressed: () => _cubit.removeEffect(input, index),
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
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: MonitorGraphView._wet,
                        inactiveTrackColor: SetupSurfaceColors.line,
                        thumbColor: MonitorGraphView._wet,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        key: Key('monitorGraph_fxParam$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) =>
                            _cubit.setEffectParam(input, index, p, v),
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
  final bool faded;
  final bool dashed;
}

class _PathPainter extends CustomPainter {
  _PathPainter(this.edges);

  final List<_Edge> edges;

  void _draw(Canvas canvas, _Edge e) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = e.faded ? 1.4 : 2.4
      ..color = e.color.withValues(alpha: e.faded ? 0.22 : 0.95);
    final span = (e.to.dx - e.from.dx).abs();
    final dx = span / 2 < MonitorGraphView._curveHandle
        ? span / 2
        : MonitorGraphView._curveHandle;
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
      _drawDashed(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
        d += 11;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edges) {
      if (e.faded) _draw(canvas, e);
    }
    for (final e in edges) {
      if (!e.faded) _draw(canvas, e);
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) => old.edges != edges;
}
