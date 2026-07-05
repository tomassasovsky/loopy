import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/view/fx_editor/fx_editor_page.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_summary.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';
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
                    colors: [surface.pageGlow, surface.background],
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
/// nests its takes. Each input/lane card carries its mix + a tappable FX
/// summary that opens the dedicated editor; there is no bottom dock.
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
                      onEditFx: _editInputFx,
                      onMuteToggled: (input) => unawaited(
                        _monitor.setMute(
                          input,
                          muted: !monitor.forInput(input).muted,
                        ),
                      ),
                      onVolumeChanged: (input, v) =>
                          unawaited(_monitor.setVolume(input, v)),
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
                      onEditFx: (take) =>
                          _editLaneFx(take.track, take.laneIndex),
                      onMuteToggled: (take) => _bloc.add(
                        LooperLaneMuteToggled(take.track, take.laneIndex),
                      ),
                      onVolumeChanged: (take, v) => _bloc.add(
                        LooperLaneVolumeChanged(take.track, take.laneIndex, v),
                      ),
                      onAddLane: (track) => _bloc.add(
                        LooperLaneCountChanged(
                          track,
                          _laneCount(looper, track) + 1,
                        ),
                      ),
                      onRemoveLane: (track) => _bloc.add(
                        LooperLaneCountChanged(
                          track,
                          _laneCount(looper, track) - 1,
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
          ],
        ),
      ),
    );
  }

  // Tapping a card only traces its signal — it never changes what you hear.
  // Monitoring is toggled deliberately on the gate dot; FX open in the editor.
  void _onTapInput(InputRow row) {
    if (row.excluded) return;
    _focusInput(row.input);
  }

  int _laneCount(LooperState looper, int track) =>
      track < looper.tracks.length ? looper.tracks[track].lanes.length : 1;

  /// Opens the FX editor for input [input]'s live-monitor chain.
  void _editInputFx(int input) {
    unawaited(
      showFxEditorPage(
        context,
        scope: InputFxScope(
          monitor: _monitor,
          looper: _bloc,
          repository: context.read<LooperRepository>(),
          input: input,
        ),
      ),
    );
  }

  /// Opens the FX editor for lane [lane] of track [track].
  void _editLaneFx(int track, int lane) {
    unawaited(
      showFxEditorPage(
        context,
        scope: LaneFxScope(
          looper: _bloc,
          repository: context.read<LooperRepository>(),
          track: track,
          lane: lane,
        ),
      ),
    );
  }
}
