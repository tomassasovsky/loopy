import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart' show MonitorState;

/// The flattened, list-ready view-model for the Signal surface (D4/D12).
///
/// Pure presentation-model code: it consumes the engine state objects
/// ([MonitorState] + [LooperState]) and produces the rows the three panes
/// render — with single-lane tracks collapsed to the track itself and a **tag
/// set** per row so tap-to-trace can light related rows by overlap. It imports
/// no widgets and touches no `BuildContext`, so it is unit-tested directly.

// --- Trace tags ----------------------------------------------------------
// Built once here so a typo can't silently break tap-to-trace (D10).

/// The trace tag for hardware input [i].
String inTag(int i) => 'in$i';

/// The trace tag for hardware output [o].
String outTag(int o) => 'o$o';

/// The trace tag for track [t].
String trkTag(int t) => 'trk$t';

/// One hardware input's row.
class InputRow {
  /// Creates an [InputRow].
  const InputRow({
    required this.input,
    required this.monitor,
    required this.excluded,
    required this.routes,
    required this.tags,
  });

  /// The hardware input channel.
  final int input;

  /// Its live-monitor configuration (gate + chain + routing + mix).
  final InputMonitor monitor;

  /// Whether this is a loopback input — never monitorable/capturable.
  final bool excluded;

  /// The output channels this input is routed to (within the active count).
  final List<int> routes;

  /// Trace tags: itself + each routed output.
  final Set<String> tags;
}

/// One recorded take (lane) within a track.
class TakeRow {
  /// Creates a [TakeRow].
  const TakeRow({
    required this.track,
    required this.laneIndex,
    required this.lane,
    required this.routes,
    required this.tags,
  });

  /// The owning track's index.
  final int track;

  /// The lane's position within its track.
  final int laneIndex;

  /// The lane state (captured input, snapshot FX, mix, routing).
  final Lane lane;

  /// The output channels this take plays out to (within the active count).
  final List<int> routes;

  /// Trace tags: its track + captured input + each routed output.
  final Set<String> tags;
}

/// A track and its takes. A single-lane track is rendered as one row that *is*
/// the track; a multi-lane track shows a header + nested take rows.
class TrackGroup {
  /// Creates a [TrackGroup].
  const TrackGroup({
    required this.track,
    required this.single,
    required this.takes,
  });

  /// The track index.
  final int track;

  /// Whether the track has exactly one lane (collapse to the track row).
  final bool single;

  /// The track's takes, in lane order (always at least one).
  final List<TakeRow> takes;
}

/// One hardware output's row.
class OutputRow {
  /// Creates an [OutputRow].
  const OutputRow({
    required this.output,
    required this.enabled,
    required this.tags,
  });

  /// The hardware output channel.
  final int output;

  /// Whether the output's structural gate is on.
  final bool enabled;

  /// Trace tags: itself.
  final Set<String> tags;
}

/// The whole Signal surface flattened into three lists.
class SignalRows {
  /// Creates a [SignalRows].
  const SignalRows({
    required this.inputs,
    required this.tracks,
    required this.outputs,
    required this.inputCount,
    required this.outputCount,
  });

  /// Flattens [monitor] + [looper] into list rows.
  factory SignalRows.from(MonitorState monitor, LooperState looper) {
    final status = looper.status;
    final inCount = status.inputChannels > 0 ? status.inputChannels : 4;
    final outCount = status.outputChannels > 0 ? status.outputChannels : 2;
    final excludedMask = status.excludedInputMask;

    bool isExcluded(int c) => excludedMask & (1 << c) != 0;
    List<int> routesOf(int mask) => [
      for (var o = 0; o < outCount; o++)
        if (mask & (1 << o) != 0) o,
    ];

    final inputs = <InputRow>[];
    for (var c = 0; c < inCount; c++) {
      final m = monitor.forInput(c);
      final excluded = isExcluded(c);
      // An input is only in the signal path when it is live (monitored); a
      // disabled input's mask routes nothing, so it feeds no output and shows
      // no routing chips until enabled.
      final routes = (excluded || !m.enabled)
          ? const <int>[]
          : routesOf(m.outputMask);
      inputs.add(
        InputRow(
          input: c,
          monitor: m,
          excluded: excluded,
          routes: routes,
          tags: {inTag(c), for (final o in routes) outTag(o)},
        ),
      );
    }

    final tracks = <TrackGroup>[];
    for (var t = 0; t < looper.tracks.length; t++) {
      final lanes = looper.tracks[t].lanes;
      if (lanes.isEmpty) continue; // laneless tracks contribute no row
      final takes = <TakeRow>[];
      for (var l = 0; l < lanes.length; l++) {
        final lane = lanes[l];
        final routes = routesOf(lane.outputMask);
        final ic = lane.inputChannel;
        takes.add(
          TakeRow(
            track: t,
            laneIndex: l,
            lane: lane,
            routes: routes,
            tags: {
              trkTag(t),
              if (ic >= 0 && ic < inCount && !isExcluded(ic)) inTag(ic),
              for (final o in routes) outTag(o),
            },
          ),
        );
      }
      tracks.add(
        TrackGroup(track: t, single: lanes.length == 1, takes: takes),
      );
    }

    final outputs = [
      for (var o = 0; o < outCount; o++)
        OutputRow(
          output: o,
          enabled: looper.isOutputEnabled(o),
          tags: {outTag(o)},
        ),
    ];

    return SignalRows(
      inputs: inputs,
      tracks: tracks,
      outputs: outputs,
      inputCount: inCount,
      outputCount: outCount,
    );
  }

  /// Hardware input rows (left pane).
  final List<InputRow> inputs;

  /// Track groups (middle pane).
  final List<TrackGroup> tracks;

  /// Hardware output rows (right pane).
  final List<OutputRow> outputs;

  /// The active input / output channel counts (fall back to a sensible default
  /// when the engine is stopped, mirroring the old graph).
  final int inputCount;
  final int outputCount;

  /// The set of inputs routed to output [o] (its "fed by" feeders), derived at
  /// call time — never materialized on [OutputRow].
  List<int> inputsFeeding(int o) => [
    for (final r in inputs)
      if (!r.excluded && r.routes.contains(o)) r.input,
  ];

  /// The track indices that have any take routed to output [o].
  List<int> tracksFeeding(int o) => [
    for (final g in tracks)
      if (g.takes.any((t) => t.routes.contains(o))) g.track,
  ];
}

/// The view-local tap-to-trace state (D3): the lit tag set, or inactive.
class TraceState {
  /// A trace lighting every row that shares a tag with the tapped row.
  const TraceState(this.litTags);

  /// An inactive trace (nothing highlighted).
  const TraceState.none() : litTags = const {};

  /// The tags considered "lit"; empty when inactive.
  final Set<String> litTags;

  /// Whether a trace is active.
  bool get active => litTags.isNotEmpty;

  /// Whether a row carrying [tags] is lit by the active trace.
  bool lit(Set<String> tags) => active && tags.any(litTags.contains);
}
