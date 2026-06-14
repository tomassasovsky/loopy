import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_channel_chip.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_layout.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_lane_node.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_lane_panel.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// Opens the input-monitoring routing graph as a full-screen page (so it has
/// room instead of a cramped panel). Re-provides the [MonitorCubit] and
/// [AudioSetupCubit] into the pushed route (it lives under the root navigator):
/// the latter drives the octaver monitoring-lag hint live, so engaging a
/// phase-vocoder octaver here surfaces the hint without reopening the page.
Future<void> showMonitorRoutingPage({
  required BuildContext context,
  required int inputChannels,
  required int outputChannels,
  int excludedInputMask = 0,
}) {
  final monitor = context.read<MonitorCubit>();
  final audioSetup = context.read<AudioSetupCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: monitor),
          BlocProvider.value(value: audioSetup),
        ],
        child: Scaffold(
          key: const Key('monitorRouting_page'),
          appBar: AppBar(title: Text(context.l10n.inputMonitoringTitle)),
          body: BlocBuilder<AudioSetupCubit, AudioSetupState>(
            buildWhen: (a, b) =>
                a.engineStatus.fxAddedLatencyMs !=
                b.engineStatus.fxAddedLatencyMs,
            builder: (context, state) => MonitorGraphView(
              inputChannels: inputChannels,
              outputChannels: outputChannels,
              excludedInputMask: excludedInputMask,
              addedLatencyMs: state.engineStatus.fxAddedLatencyMs,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The live input-monitoring configuration as one wired graph, structurally
/// identical to the track lane graph: hardware inputs on the left, each
/// monitored input's **lanes** stacked in the middle (each a node + its own
/// effect chain), and hardware outputs on the right. Bezier edges show how
/// every lane is wired.
///
/// Each hardware input is a multi-lane container: tapping an input chip enables
/// monitoring (gating the whole input); each lane is an independent parallel
/// path with its own routing, volume, mute, and effect chain. A lane with no
/// effects is the clean (dry) path — there is no separate wet/dry concept. With
/// a lane focused, an output tap wires that lane.
///
/// Drawing, cards, chips, and the zoom/pan canvas come from the shared routing
/// graph package (`package:routing_graph`); this view owns only the
/// monitor-specific assembly: the geometry ([MonitorGraphLayout]), the lane
/// node body ([MonitorLaneNode]), the output ports ([MonitorOutputChip]), and
/// the bottom panel ([MonitorLanePanel]). Every edit drives the [MonitorCubit].
class MonitorGraphView extends StatefulWidget {
  /// Creates a [MonitorGraphView].
  const MonitorGraphView({
    required this.inputChannels,
    required this.outputChannels,
    this.excludedInputMask = 0,
    this.addedLatencyMs = 0,
    super.key,
  });

  /// Hardware input/output channel counts.
  final int inputChannels;
  final int outputChannels;

  /// Loopback inputs, drawn dimmed and never monitorable.
  final int excludedInputMask;

  /// The engine's reported added latency (ms) for the octaver monitoring hint.
  final double addedLatencyMs;

  @override
  State<MonitorGraphView> createState() => _MonitorGraphViewState();
}

class _MonitorGraphViewState extends State<MonitorGraphView> {
  /// The effect currently being dragged to reorder, or null.
  GraphCardRef? _dragging;

  /// The focused row (whose outputs are being wired), or null.
  MonitorRow? _focused;

  /// The selected (open-in-the-editor) effect, as `(row, index)`, or null.
  ({MonitorRow row, int index})? _selected;

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
      palette: surface.lanePalette,
    );

    // Drop a focus/selection that no longer maps to a live row (e.g. its input
    // was disabled or a lane removed). View-local only, so render it as cleared
    // this frame without mutating state during build.
    final focus = (_focused != null && layout.rows.contains(_focused))
        ? _focused
        : null;
    final selected = (_selected != null && layout.rows.contains(_selected!.row))
        ? _selected
        : null;

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
                onTapBackground: (focus == null && selected == null)
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
                        color: surface.accent,
                        strong: focus?.input == c,
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
                                  _focused = (input: c, lane: 0);
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
                      child: MonitorOutputChip(
                        label: l10n.outputChannelLabel(c + 1),
                        channel: c,
                        rows: layout.rows,
                        state: state,
                        focused: focus,
                        onWire: focus == null
                            ? null
                            : () {
                                final mask = state
                                    .forInput(focus.input)
                                    .lane(focus.lane)
                                    .outputMask;
                                unawaited(
                                  _cubit.setLaneOutputMask(
                                    focus.input,
                                    focus.lane,
                                    mask ^ (1 << c),
                                  ),
                                );
                              },
                      ),
                    ),
                  for (var r = 0; r < layout.rows.length; r++) ...[
                    _laneRow(context, layout, state, r, focus, selected),
                  ],
                ],
              ),
            ),
            _panel(state, focus, selected),
          ],
        ),
      ),
    );
  }

  /// All positioned widgets for row [r]: the lane node, its effect cards, the
  /// drop zones, and the add-effect button.
  Widget _laneRow(
    BuildContext context,
    MonitorGraphLayout layout,
    MonitorState state,
    int r,
    MonitorRow? focus,
    ({MonitorRow row, int index})? selected,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final row = layout.rows[r];
    final laneState = state.forInput(row.input).lane(row.lane);
    final color = surface.laneColor(row.lane);
    return Stack(
      children: [
        positionedNode(
          left: layout.nodeX,
          centerY: layout.rowY(r),
          width: MonitorGraphLayout.nodeWidth,
          height: MonitorGraphLayout.nodeHeight,
          child: MonitorLaneNode(
            input: row.input,
            lane: row.lane,
            laneState: laneState,
            color: color,
            focused: focus == row,
            dim: focus != null && focus != row,
            onTap: () => setState(() {
              _focused = focus == row ? null : row;
              _selected = null;
            }),
          ),
        ),
        ...buildEffectDropZones(
          keyPrefix: 'monitorGraph',
          rowId: r,
          cardXs: layout.cardXs[r],
          emptyStartX: MonitorGraphLayout.cardStartX,
          rowCenterY: layout.rowY(r),
          accentColor: surface.accent,
          onMove: (from, gap) {
            _cubit.moveEffect(row.input, row.lane, from, gap);
            setState(() => _selected = null);
          },
        ),
        for (var k = 0; k < layout.cardXs[r].length; k++)
          positionedNode(
            left: layout.cardXs[r][k],
            centerY: layout.rowY(r),
            width: kRoutingCardWidth,
            height: kRoutingCardHeight,
            child: EffectChainCard(
              keyPrefix: 'monitorGraph',
              label: l10n.effectTypeLabel(laneState.effects[k].type),
              accentColor: color,
              selected: selected?.row == row && selected?.index == k,
              dragging: _dragging?.rowId == r && _dragging?.index == k,
              rowId: r,
              index: k,
              onTap: () => setState(() {
                _focused = row;
                _selected = (selected?.row == row && selected?.index == k)
                    ? null
                    : (row: row, index: k);
              }),
              onDelete: () {
                _cubit.removeEffect(row.input, row.lane, k);
                setState(() => _selected = null);
              },
              onDragStart: () => setState(() => _dragging = GraphCardRef(r, k)),
              onDragEnd: () => setState(() => _dragging = null),
            ),
          ),
        positionedNode(
          left: layout.addFxX(r),
          centerY: layout.rowY(r),
          width: kRoutingAddSlot,
          height: kRoutingAddSlot,
          child: AddEffectButton(
            buttonKey: Key('monitorGraph_addFx_$r'),
            accentColor: surface.accent,
            full: laneState.effects.length >= kTrackEffectMax,
            tooltip: l10n.addEffectToInputTooltip(row.input + 1),
            onAdd: () {
              setState(() => _focused = row);
              _cubit.addEffect(row.input, row.lane);
            },
          ),
        ),
      ],
    );
  }

  Widget _panel(
    MonitorState state,
    MonitorRow? focus,
    ({MonitorRow row, int index})? selected,
  ) {
    final monitor = focus == null ? null : state.forInput(focus.input);
    final laneState = focus == null ? null : monitor!.lane(focus.lane);
    TrackEffect? selectedFx;
    if (focus != null && selected != null && selected.row == focus) {
      final effects = laneState!.effects;
      if (selected.index < effects.length) selectedFx = effects[selected.index];
    }
    return MonitorLanePanel(
      input: focus?.input,
      lane: focus?.lane ?? 0,
      laneState: laneState,
      laneCount: monitor?.laneCount ?? 1,
      selectedFx: selectedFx,
      onMuteToggled: () {
        if (focus == null || laneState == null) return;
        unawaited(
          _cubit.setLaneMute(focus.input, focus.lane, muted: !laneState.muted),
        );
      },
      onVolumeChanged: (v) {
        if (focus == null) return;
        unawaited(_cubit.setLaneVolume(focus.input, focus.lane, v));
      },
      onRemoveLane: () {
        if (focus == null) return;
        unawaited(_cubit.removeLane(focus.input, focus.lane));
        setState(() {
          _focused = null;
          _selected = null;
        });
      },
      onAddLane: () {
        if (focus == null) return;
        unawaited(_cubit.addLane(focus.input));
      },
      onStop: () {
        if (focus == null) return;
        unawaited(_cubit.setEnabled(focus.input, enabled: false));
        setState(() {
          _focused = null;
          _selected = null;
        });
      },
      onSetType: (t) {
        if (focus == null || selected == null) return;
        _cubit.setEffectType(focus.input, focus.lane, selected.index, t);
      },
      onSetParam: (p, v) {
        if (focus == null || selected == null) return;
        _cubit.setEffectParam(focus.input, focus.lane, selected.index, p, v);
      },
      onRemoveEffect: () {
        if (focus == null || selected == null) return;
        _cubit.removeEffect(focus.input, focus.lane, selected.index);
        setState(() => _selected = null);
      },
      addedLatencyMs: widget.addedLatencyMs,
    );
  }
}
