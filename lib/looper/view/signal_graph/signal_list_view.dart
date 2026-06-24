import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
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
/// performance flow. Re-provides the state objects it drives — [LooperBloc],
/// [MonitorCubit], and [BigPictureCubit] — into the pushed route.
Future<void> showSignalPage(BuildContext context) {
  final bloc = context.read<LooperBloc>();
  final monitor = context.read<MonitorCubit>();
  final bigPicture = context.read<BigPictureCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: bloc),
          BlocProvider.value(value: monitor),
          BlocProvider.value(value: bigPicture),
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
                          trackNames: context
                              .watch<BigPictureCubit>()
                              .state
                              .names,
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

  /// Per-track display names (from `BigPictureCubit`); falls back to `Track N`
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

    final fi = focusedInput;
    if (fi != null && fi < looper.status.inputChannels) {
      final m = monitor.forInput(fi);
      return _withDebugPluginInsert(
        (ref) => monitorCubit.insertPlugin(fi, ref),
        SignalInputDock(
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
          onSetType: (i, t) => monitorCubit.setEffectType(fi, i, t),
          onSetParam: (i, p, v) => monitorCubit.setEffectParam(fi, i, p, v),
          onSetPluginParam: (i, id, v) =>
              monitorCubit.setPluginParam(fi, i, id, v),
          onOpenPluginEditor: (i) => monitorCubit.openPluginEditor(fi, i),
          onRemoveEffect: (i) => monitorCubit.removeEffect(fi, i),
          onReorderEffect: (from, to) => monitorCubit.moveEffect(fi, from, to),
        ),
      );
    }
    final ft = focusedTake;
    if (ft != null &&
        ft.track < looper.tracks.length &&
        ft.lane < looper.tracks[ft.track].lanes.length) {
      final lane = looper.tracks[ft.track].lanes[ft.lane];
      final laneCount = looper.tracks[ft.track].lanes.length;
      return _withDebugPluginInsert(
        (ref) => bloc.add(LooperLanePluginInserted(ft.track, ft.lane, ref)),
        SignalLaneDock(
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
          onReorderEffect: (from, to) =>
              bloc.add(LooperLaneEffectMoved(ft.track, ft.lane, from, to)),
          onMuteToggled: () =>
              bloc.add(LooperLaneMuteToggled(ft.track, ft.lane)),
          onVolumeChanged: (v) =>
              bloc.add(LooperLaneVolumeChanged(ft.track, ft.lane, v)),
        ),
      );
    }
    return SignalHintDock(message: context.l10n.signalHint);
  }

  /// DEBUG-ONLY scaffolding: overlays a button that scans for plugins and
  /// inserts the first one into the focused chain via [onInsert] — a temporary
  /// seam to exercise the plugin device card + native editor until the plugin
  /// browser lands. Compiled out of release builds via [kDebugMode].
  Widget _withDebugPluginInsert(
    void Function(PluginRef) onInsert,
    Widget dock,
  ) {
    if (!kDebugMode) return dock;
    return Stack(
      children: [
        dock,
        Positioned(
          right: 12,
          top: 6,
          child: _DebugInsertPluginButton(onInsert: onInsert),
        ),
      ],
    );
  }
}

/// DEBUG-ONLY button: scans the [LooperRepository]'s plugin catalog and inserts
/// the first available plugin into the focused chain. A stop-gap for manual
/// editor/knob testing; replaced by the real plugin browser later.
class _DebugInsertPluginButton extends StatefulWidget {
  const _DebugInsertPluginButton({required this.onInsert});

  final void Function(PluginRef) onInsert;

  @override
  State<_DebugInsertPluginButton> createState() =>
      _DebugInsertPluginButtonState();
}

class _DebugInsertPluginButtonState extends State<_DebugInsertPluginButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final catalog = context.read<LooperRepository>().pluginCatalog;
    final found = await catalog.scan();
    if (!mounted) return;
    final available = found.where((p) => p.isAvailable).toList();
    if (available.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('No plugins found to insert')),
      );
    } else {
      final d = available.first;
      widget.onInsert(
        PluginRef(format: d.format, id: d.id, version: d.version),
      );
      messenger?.showSnackBar(
        SnackBar(content: Text('Inserted ${d.name}')),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'DEBUG: insert first scanned plugin',
      child: FloatingActionButton.small(
        heroTag: 'debugInsertPlugin',
        onPressed: _busy ? null : _run,
        child: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.electrical_services),
      ),
    );
  }
}
