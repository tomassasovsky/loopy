import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_layout.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_node.dart';
import 'package:loopy/audio_setup/view/monitor_graph/route_panel.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

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
          appBar: AppBar(title: Text(context.l10n.inputMonitoringTitle)),
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

/// The live input-monitoring configuration as one wired graph: hardware inputs
/// on the left, each *monitored* input as a node with its own effect chain in
/// the middle, and outputs on the right.
///
/// Each monitored input has two parallel sends, drawn as colour-coded edges:
/// the **effected (wet)** signal runs through the chain to its outputs (blue),
/// and the **clean (dry)** signal leaves the monitor node's bottom centre to
/// its own outputs (amber, dashed). Tap an input to start monitoring it and
/// focus it; with an
/// input focused, the Effected/Dry toggle picks which send an output tap wires.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph package (`package:routing_graph`); this view owns the monitor-specific
/// assembly: the dual-route geometry ([MonitorGraphLayout]), the node body
/// ([MonitorNode]), the Stop / Effected-Dry controls ([RoutePanel]), and the
/// internal selection that drives the [MonitorCubit].
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
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<MonitorCubit>().state;
    final layout = MonitorGraphLayout.compute(
      state: state,
      inCount: _inCount,
      outCount: _outCount,
      excludedMask: widget.excludedInputMask,
      focused: _focused,
      wetColor: surface.wetRoute,
      dryColor: surface.dryRoute,
    );
    final outChips = [
      for (var c = 0; c < _outCount; c++)
        _outAppearance(state, layout, surface, c),
    ];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Expanded(
              child: GraphCanvas(
                width: layout.canvasWidth,
                height: layout.canvasHeight,
                fitIdentity: layout.fitIdentity,
                onTapBackground: (_focused == null && _selected == null)
                    ? null
                    : () => setState(() {
                        _focused = null;
                        _selected = null;
                      }),
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: GraphEdgePainter(layout.edges)),
                  ),
                  for (var c = 0; c < _inCount; c++)
                    positionedNode(
                      left: layout.inX,
                      centerY: layout.inY(c),
                      width: MonitorGraphLayout.channelChipWidth,
                      height: MonitorGraphLayout.channelChipHeight,
                      child: ChannelChip(
                        key: Key('monitorGraph_in_$c'),
                        label: l10n.inputChannelLabel(c + 1),
                        color: surface.wetRoute,
                        strong: _focused == c,
                        wired: state.forInput(c).enabled && !layout.excluded(c),
                        excluded: layout.excluded(c),
                        onTap: layout.excluded(c)
                            ? null
                            : () {
                                if (!state.forInput(c).enabled) {
                                  unawaited(
                                    _cubit.setEnabled(c, enabled: true),
                                  );
                                }
                                setState(() {
                                  _focused = c;
                                  _selected = null;
                                });
                              },
                      ),
                    ),
                  for (var c = 0; c < _outCount; c++)
                    positionedNode(
                      left: layout.outX,
                      centerY: layout.outY(c),
                      width: MonitorGraphLayout.channelChipWidth,
                      height: MonitorGraphLayout.channelChipHeight,
                      child: ChannelChip(
                        key: Key('monitorGraph_out_$c'),
                        label: l10n.outputChannelLabel(c + 1),
                        color: outChips[c].color,
                        strong: outChips[c].strong,
                        wired: outChips[c].wired,
                        excluded: false,
                        onTap: _focused == null
                            ? null
                            : () {
                                final f = _focused!;
                                final m = state.forInput(f);
                                final bit = 1 << c;
                                if (_wireDry) {
                                  unawaited(
                                    _cubit.setDryOutputMask(
                                      f,
                                      m.dryOutputMask ^ bit,
                                    ),
                                  );
                                } else {
                                  unawaited(
                                    _cubit.setOutputMask(f, m.outputMask ^ bit),
                                  );
                                }
                              },
                      ),
                    ),
                  for (final c in layout.rows) ...[
                    positionedNode(
                      left: layout.nodeX,
                      centerY: layout.rowY(c),
                      width: MonitorGraphLayout.monitorNodeWidth,
                      height: MonitorGraphLayout.monitorNodeHeight,
                      child: MonitorNode(
                        input: c,
                        focused: _focused == c,
                        onTap: () => setState(() {
                          _focused = _focused == c ? null : c;
                          _selected = null;
                        }),
                      ),
                    ),
                    // Insertion drop zones in the gaps before/after each card (the
                    // cards are the drag sources) — the gap-index convention
                    // shared by the lane graph.
                    ...buildEffectDropZones(
                      keyPrefix: 'monitorGraph',
                      rowId: c,
                      cardXs: layout.cardXs[c]!,
                      emptyStartX: MonitorGraphLayout.cardStartX,
                      rowCenterY: layout.rowY(c),
                      accentColor: surface.wetRoute,
                      onMove: (from, gap) {
                        _cubit.moveEffect(c, from, gap);
                        setState(() => _selected = null);
                      },
                    ),
                    for (var k = 0; k < layout.cardXs[c]!.length; k++)
                      positionedNode(
                        left: layout.cardXs[c]![k],
                        centerY: layout.rowY(c),
                        width: kRoutingCardWidth,
                        height: kRoutingCardHeight,
                        child: EffectChainCard(
                          keyPrefix: 'monitorGraph',
                          label: l10n.effectTypeLabel(
                            state.forInput(c).effects[k].type,
                          ),
                          accentColor: surface.wetRoute,
                          selected:
                              _selected?.input == c && _selected?.index == k,
                          dragging:
                              _dragging?.rowId == c && _dragging?.index == k,
                          rowId: c,
                          index: k,
                          onTap: () => setState(() {
                            _focused = c;
                            _selected =
                                (_selected?.input == c && _selected?.index == k)
                                ? null
                                : (input: c, index: k);
                          }),
                          onDelete: () {
                            _cubit.removeEffect(c, k);
                            setState(() => _selected = null);
                          },
                          onDragStart: () =>
                              setState(() => _dragging = GraphCardRef(c, k)),
                          onDragEnd: () => setState(() => _dragging = null),
                        ),
                      ),
                    positionedNode(
                      left: layout.addFxX(c),
                      centerY: layout.rowY(c),
                      width: kRoutingAddSlot,
                      height: kRoutingAddSlot,
                      child: AddEffectButton(
                        buttonKey: Key('monitorGraph_addFx_$c'),
                        accentColor: surface.wetRoute,
                        full:
                            state.forInput(c).effects.length >= kTrackEffectMax,
                        tooltip: l10n.addEffectToInputTooltip(c + 1),
                        onAdd: () {
                          setState(() => _focused = c);
                          _cubit.addEffect(c);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            RoutePanel(
              monitor: _focused == null ? null : state.forInput(_focused!),
              wireDry: _wireDry,
              selectedFx: _selectedEffect(state),
              onWireModeChanged: (dry) => setState(() => _wireDry = dry),
              onVolumeChanged: (v) => unawaited(_cubit.setVolume(_focused!, v)),
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
              onSetParam: (p, v) => _cubit.setEffectParam(
                _selected!.input,
                _selected!.index,
                p,
                v,
              ),
              onRemove: () {
                _cubit.removeEffect(_selected!.input, _selected!.index);
                setState(() => _selected = null);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The selected effect, or null if the selection is stale.
  TrackEffect? _selectedEffect(MonitorState state) {
    final s = _selected;
    if (s == null || !state.forInput(s.input).enabled) return null;
    final effects = state.forInput(s.input).effects;
    return s.index < effects.length ? effects[s.index] : null;
  }

  /// An output chip's colour/emphasis, derived from the focused input's sends
  /// and the wet/dry unions: strong (and dry-amber) when the focused input
  /// sends here; amber when only a dry send reaches it; wet-blue otherwise.
  ({Color color, bool strong, bool wired}) _outAppearance(
    MonitorState state,
    MonitorGraphLayout layout,
    SurfaceTheme surface,
    int c,
  ) {
    final bit = 1 << c;
    final wiredWet = layout.wetUnion & bit != 0;
    final wiredDry = layout.dryUnion & bit != 0;
    final f = _focused;
    final focusWet = f != null && state.forInput(f).outputMask & bit != 0;
    final focusDry = f != null && state.forInput(f).dryOutputMask & bit != 0;
    final color = focusDry || (f == null && wiredDry && !wiredWet)
        ? surface.dryRoute
        : surface.wetRoute;
    return (
      color: color,
      strong: focusWet || focusDry,
      wired: wiredWet || wiredDry,
    );
  }
}
