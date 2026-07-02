import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/view/signal_graph/plugin_browser.dart';
import 'package:loopy/looper/view/signal_graph/signal_dock.dart';
import 'package:loopy/looper/view/signal_graph/signal_routing_chips.dart';
import 'package:loopy/looper/view/signal_graph/signal_rows.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

// The surface is large, so its widgets are split across part files by role:
// the three list panes, the row cards, and the page chrome. They share this
// library's imports and stay private to it.
part 'signal_chrome.dart';
part 'signal_panes.dart';
part 'signal_row_views.dart';

/// Opens the unified **Signal** surface as a full-screen page from the
/// tracks flow. Re-provides the state objects it drives — [LooperBloc],
/// [MonitorCubit], and [TracksCubit] — into the pushed route.
Future<void> showSignalPage(BuildContext context) {
  final bloc = context.read<LooperBloc>();
  final monitor = context.read<MonitorCubit>();
  final tracks = context.read<TracksCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: bloc),
          BlocProvider.value(value: monitor),
          BlocProvider.value(value: tracks),
        ],
        child: Scaffold(
          key: const Key('signal_page'),
          body: Builder(
            builder: (context) {
              final surface = context.surface;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.5, -1.15),
                    radius: 1.25,
                    colors: [const Color(0xFF11111B), surface.background],
                    stops: const [0, 0.62],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    children: [
                      const _SignalChromeBar(),
                      Expanded(
                        child: SignalListView(
                          trackNames: context.watch<TracksCubit>().state.names,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// The whole signal flow as **three side-by-side lists** — inputs, tracks,
/// outputs — with no wires. Routing is shown as output-hued chips; "what
/// connects to what" comes from per-output colour + **tap-to-trace** (tap a row
/// to light its connections across all panes and dim the rest). Tracks are
/// grouped so a single-lane track is one row (no "Lane 1"); a multi-lane track
/// nests its takes. A contextual dock edits the focused input / take.
class SignalListView extends StatefulWidget {
  /// Creates a [SignalListView].
  const SignalListView({this.trackNames = const [], super.key});

  /// Per-track display names (from `TracksCubit`); falls back to `Track N`
  /// when absent or default.
  final List<String> trackNames;

  @override
  State<SignalListView> createState() => _SignalListViewState();
}

class _SignalListViewState extends State<SignalListView> {
  int? _focusedInput;
  ({int track, int lane})? _focusedTake;
  int? _tracedOutput;

  MonitorCubit get _monitor => context.read<MonitorCubit>();
  LooperBloc get _bloc => context.read<LooperBloc>();

  bool get _anyFocus =>
      _focusedInput != null || _focusedTake != null || _tracedOutput != null;

  void _focusInput(int c) => setState(() {
    final same = _focusedInput == c;
    _focusedInput = same ? null : c;
    _focusedTake = null;
    _tracedOutput = null;
  });

  void _focusTake(TakeRow take) => setState(() {
    final same = _focusedTake == (track: take.track, lane: take.laneIndex);
    _focusedTake = same ? null : (track: take.track, lane: take.laneIndex);
    _focusedInput = null;
    _tracedOutput = null;
  });

  void _traceOutput(int o) => setState(() {
    final same = _tracedOutput == o;
    _tracedOutput = same ? null : o;
    _focusedInput = null;
    _focusedTake = null;
  });

  void _clear() => setState(() {
    _focusedInput = null;
    _focusedTake = null;
    _tracedOutput = null;
  });

  /// The lit-tag set, **recomputed from current rows each build** so editing a
  /// route while tracing updates the highlight (no stale snapshot).
  TraceState _traceFor(SignalRows rows) {
    final fi = _focusedInput;
    if (fi != null && fi < rows.inputs.length) {
      return TraceState(rows.inputs[fi].tags);
    }
    final ft = _focusedTake;
    if (ft != null) {
      for (final g in rows.tracks) {
        for (final t in g.takes) {
          if (t.track == ft.track && t.laneIndex == ft.lane) {
            return TraceState(t.tags);
          }
        }
      }
    }
    final to = _tracedOutput;
    if (to != null) return TraceState({outTag(to)});
    return const TraceState.none();
  }

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<MonitorCubit>().state;
    final looper = context.watch<LooperBloc>().state;
    final rows = SignalRows.from(monitor, looper);
    final trace = _traceFor(rows);
    final noActiveOutputs =
        rows.outputs.isNotEmpty && rows.outputs.every((o) => !o.enabled);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_anyFocus) {
            _clear();
          } else {
            unawaited(Navigator.of(context).maybePop());
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            const _SignalHintStrip(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < kSignalStackBreakpoint;
                  final panes = [
                    _InputsPane(
                      rows: rows,
                      trace: trace,
                      selectedInput: _focusedInput,
                      onTap: _onTapInput,
                      onToggleRoute: (input, output) {
                        final m = monitor.forInput(input);
                        unawaited(
                          _monitor.setOutputMask(
                            input,
                            m.outputMask ^ (1 << output),
                          ),
                        );
                      },
                      onToggleGate: (input) => unawaited(
                        _monitor.setEnabled(
                          input,
                          enabled: !monitor.forInput(input).enabled,
                        ),
                      ),
                    ),
                    _TracksPane(
                      rows: rows,
                      trace: trace,
                      selectedTake: _focusedTake,
                      trackNames: widget.trackNames,
                      onTap: _focusTake,
                      onToggleRoute: (take, output) => _bloc.add(
                        LooperLaneOutputChanged(
                          take.track,
                          take.laneIndex,
                          take.lane.outputMask ^ (1 << output),
                        ),
                      ),
                      onReassignInput: (take, input) => _bloc.add(
                        LooperLaneInputChanged(
                          take.track,
                          take.laneIndex,
                          input,
                        ),
                      ),
                    ),
                    _OutputsPane(
                      rows: rows,
                      trace: trace,
                      noActiveOutputs: noActiveOutputs,
                      tracedOutput: _tracedOutput,
                      trackNames: widget.trackNames,
                      onTapRow: _traceOutput,
                      onToggleGate: (o, {required enabled}) => _bloc.add(
                        LooperOutputEnabledToggled(o, enabled: enabled),
                      ),
                    ),
                  ];
                  if (stacked) {
                    // Too narrow for three columns: switch to tabs so each
                    // list gets the full width instead of a long stack.
                    return _SignalTabs(panes: panes);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final p in panes) Expanded(child: p)],
                  );
                },
              ),
            ),
            const _SignalLegend(),
            _SignalDock(
              focusedInput: _focusedInput,
              focusedTake: _focusedTake,
              monitor: monitor,
              looper: looper,
              onClear: _clear,
            ),
          ],
        ),
      ),
    );
  }

  // Tapping a card only selects (opens its editor) + traces — it never changes
  // what you hear. Monitoring is toggled deliberately on the gate pill.
  void _onTapInput(InputRow row) {
    if (row.excluded) return;
    _focusInput(row.input);
  }
}

/// The contextual bottom dock: the focused input's monitor controls, the
/// selected take's snapshot editor, or a hint when nothing is focused. Reads
/// [MonitorCubit] / [LooperBloc] from context and dispatches their edits, so
/// the parent only hands it the current focus and an [onClear] for the actions
/// that dismiss the dock (stopping an input, removing the last lane).
class _SignalDock extends StatelessWidget {
  const _SignalDock({
    required this.focusedInput,
    required this.focusedTake,
    required this.monitor,
    required this.looper,
    required this.onClear,
  });

  final int? focusedInput;
  final ({int track, int lane})? focusedTake;
  final MonitorState monitor;
  final LooperState looper;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final monitorCubit = context.read<MonitorCubit>();
    final bloc = context.read<LooperBloc>();
    // Read-only query for the live plugin knob readouts (the plugin's own
    // value-to-text). A pure lookup, so the dock reads the repository directly.
    final repo = context.read<LooperRepository>();

    final fi = focusedInput;
    if (fi != null && fi < looper.status.inputChannels) {
      final m = monitor.forInput(fi);
      return SignalInputDock(
        input: fi,
        monitor: m,
        onMuteToggled: () =>
            unawaited(monitorCubit.setMute(fi, muted: !m.muted)),
        onVolumeChanged: (v) => unawaited(monitorCubit.setVolume(fi, v)),
        onStop: () {
          unawaited(monitorCubit.setEnabled(fi, enabled: false));
          onClear();
        },
        onAddEffect: () => monitorCubit.addEffect(fi),
        onAddPlugin: () => unawaited(_addMonitorPlugin(context, fi)),
        onSetType: (i, t) => monitorCubit.setEffectType(fi, i, t),
        onSetParam: (i, p, v) => monitorCubit.setEffectParam(fi, i, p, v),
        onSetPluginParam: (i, id, v) =>
            monitorCubit.setPluginParam(fi, i, id, v),
        onOpenPluginEditor: (i) => monitorCubit.openPluginEditor(fi, i),
        onRelinkPlugin: (i) => unawaited(_relinkMonitorPlugin(context, fi, i)),
        onRemoveEffect: (i) => monitorCubit.removeEffect(fi, i),
        onReorderEffect: (from, to) => monitorCubit.moveEffect(fi, from, to),
        onFormatPluginValue: (i, id, v) => repo.monitorPluginParamText(
          input: fi,
          index: i,
          paramId: id,
          value: v,
        ),
      );
    }
    final ft = focusedTake;
    if (ft != null &&
        ft.track < looper.tracks.length &&
        ft.lane < looper.tracks[ft.track].lanes.length) {
      final lane = looper.tracks[ft.track].lanes[ft.lane];
      final laneCount = looper.tracks[ft.track].lanes.length;
      return SignalLaneDock(
        inputNumber: lane.inputChannel >= 0 ? lane.inputChannel + 1 : 0,
        effects: lane.effects,
        muted: lane.muted,
        volume: lane.volume,
        canAddLane: laneCount < kMaxLanes,
        canRemoveLane: laneCount > 1 && ft.lane == laneCount - 1,
        onAddLane: () =>
            bloc.add(LooperLaneCountChanged(ft.track, laneCount + 1)),
        onRemoveLane: () {
          bloc.add(LooperLaneCountChanged(ft.track, laneCount - 1));
          onClear();
        },
        onAddEffect: () => bloc.add(LooperLaneEffectAdded(ft.track, ft.lane)),
        onAddPlugin: () =>
            unawaited(_addLanePlugin(context, ft.track, ft.lane)),
        onRemoveEffect: (i) =>
            bloc.add(LooperLaneEffectRemoved(ft.track, ft.lane, i)),
        onSetType: (i, t) =>
            bloc.add(LooperLaneEffectTypeChanged(ft.track, ft.lane, i, t)),
        onSetParam: (i, p, v) => bloc.add(
          LooperLaneEffectParamChanged(ft.track, ft.lane, i, p, v),
        ),
        onSetPluginParam: (i, id, v) => bloc.add(
          LooperLanePluginParamChanged(ft.track, ft.lane, i, id, v),
        ),
        onOpenPluginEditor: (i) =>
            bloc.add(LooperLanePluginEditorOpened(ft.track, ft.lane, i)),
        onRelinkPlugin: (i) =>
            unawaited(_relinkLanePlugin(context, ft.track, ft.lane, i)),
        onReorderEffect: (from, to) =>
            bloc.add(LooperLaneEffectMoved(ft.track, ft.lane, from, to)),
        onMuteToggled: () => bloc.add(LooperLaneMuteToggled(ft.track, ft.lane)),
        onVolumeChanged: (v) =>
            bloc.add(LooperLaneVolumeChanged(ft.track, ft.lane, v)),
        onFormatPluginValue: (i, id, v) => repo.lanePluginParamText(
          channel: ft.track,
          lane: ft.lane,
          index: i,
          paramId: id,
          value: v,
        ),
      );
    }
    return SignalHintDock(message: context.l10n.signalHint);
  }

  PluginRef _refOf(PluginDescriptor d) =>
      PluginRef(format: d.format, id: d.id, version: d.version);

  /// Opens the plugin browser and inserts the chosen plugin into lane [lane].
  Future<void> _addLanePlugin(
    BuildContext context,
    int track,
    int lane,
  ) async {
    final bloc = context.read<LooperBloc>();
    final descriptor = await showPluginBrowser(context);
    if (descriptor != null) {
      bloc.add(LooperLanePluginInserted(track, lane, _refOf(descriptor)));
    }
  }

  /// Opens the plugin browser and inserts the chosen plugin into monitor
  /// [input]'s chain.
  Future<void> _addMonitorPlugin(BuildContext context, int input) async {
    final cubit = context.read<MonitorCubit>();
    final descriptor = await showPluginBrowser(context);
    if (descriptor != null) {
      cubit.insertPlugin(input, _refOf(descriptor));
    }
  }

  /// Relinks an unavailable lane plugin (D-MISS) to a browser-chosen plugin,
  /// keeping the preserved ref + opaque state.
  Future<void> _relinkLanePlugin(
    BuildContext context,
    int track,
    int lane,
    int index,
  ) async {
    final bloc = context.read<LooperBloc>();
    final descriptor = await showPluginBrowser(context);
    if (descriptor != null) {
      bloc.add(
        LooperLanePluginRelinked(track, lane, index, _refOf(descriptor)),
      );
    }
  }

  /// Relinks an unavailable monitor plugin (D-MISS); see [_relinkLanePlugin].
  Future<void> _relinkMonitorPlugin(
    BuildContext context,
    int input,
    int index,
  ) async {
    final cubit = context.read<MonitorCubit>();
    final descriptor = await showPluginBrowser(context);
    if (descriptor != null) {
      cubit.relinkPlugin(input, index, _refOf(descriptor));
    }
  }
}
