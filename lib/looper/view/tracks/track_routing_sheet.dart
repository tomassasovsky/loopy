import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/routing_tracks_tab.dart';
import 'package:segno/theme/theme.dart';

/// Opens one track's routing: what it records, where it goes, and whether it
/// quantizes. Drawn to `TRACKS / track-routing` and `track-unrouted`.
///
/// A track records ANY set of inputs — one dry lane each, sharing the track's
/// transport and loop. That is the model the multi-lane engine was rewritten
/// for ("both inputs recorded into track 1 as separate dry lanes", NOT one
/// input per track with grouping), so the input list here is multi-select and
/// each check is a lane.
///
/// A centred dialog rather than a bottom sheet, as the mockups draw it: this
/// one is a panel of three lists, and a sheet tall enough to hold them would
/// be the whole screen anyway.
///
/// Every change applies as it is tapped — the Done button dismisses, it does
/// not commit. That is what the rest of the console does, and a routing panel
/// with an OK button would imply the changes were not already audible.
Future<void> showTrackRoutingSheet(
  BuildContext context, {
  required int channel,
}) {
  // A dialog route is built by the navigator and sees nothing the caller's
  // subtree provides, so the three it needs are handed across explicitly.
  final looper = context.read<LooperBloc>();
  final tracks = context.read<TracksCubit>();
  final quantize = context.read<QuantizeCubit>();
  final repository = context.read<LooperRepository>();
  return showDialog<void>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (dialogContext) => MultiBlocProvider(
      providers: [
        BlocProvider<LooperBloc>.value(value: looper),
        BlocProvider<TracksCubit>.value(value: tracks),
        BlocProvider<QuantizeCubit>.value(value: quantize),
      ],
      child: RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: _TrackRoutingSheet(channel: channel),
      ),
    ),
  );
}

class _TrackRoutingSheet extends StatefulWidget {
  const _TrackRoutingSheet({required this.channel});

  final int channel;

  @override
  State<_TrackRoutingSheet> createState() => _TrackRoutingSheetState();
}

class _TrackRoutingSheetState extends State<_TrackRoutingSheet> {
  /// The quantize override, held here because the engine snapshot does not
  /// carry it: seeded from the repository's own map on open, and kept in step
  /// as it is changed. Everything else on this panel is read live off the
  /// snapshot.
  bool? _quantize;

  /// The open lane row, by lane index — one at a time, like every other
  /// console list that opens in place.
  int? _openLane;

  @override
  void initState() {
    super.initState();
    _quantize = context.read<LooperRepository>().trackQuantize(widget.channel);
  }

  /// The inputs this track records, in lane order.
  ///
  /// From the lanes themselves, falling back to the lane-0 mirror for a
  /// stopped engine, which reports no lanes at all.
  List<int> _inputsOf(Track track) {
    if (track.lanes.isEmpty) {
      final single = maskToInputChannel(track.inputMask);
      return single < 0 ? const [] : [single];
    }
    return [
      for (final lane in track.lanes)
        if (lane.inputChannel >= 0) lane.inputChannel,
    ];
  }

  /// Adds or drops one input WITHOUT renumbering the others.
  ///
  /// Lane index is identity: lane 2 holds lane 2's recorded audio. Rebuilding
  /// the list as "sorted inputs, lane per index" would silently move a take
  /// from one source to another whenever an input was added in the middle.
  /// So dropping an input sets its own lane to record nothing (`-1`) and
  /// leaves the lane where it is, and adding one reuses such a spare lane
  /// before growing the track.
  void _toggleInput(Track track, int input) {
    final bloc = context.read<LooperBloc>();
    final lanes = track.lanes;
    final existing = lanes.indexWhere((lane) => lane.inputChannel == input);
    if (existing >= 0) {
      bloc.add(LooperLaneInputChanged(widget.channel, existing, -1));
      return;
    }
    if (lanes.isEmpty && maskToInputChannel(track.inputMask) < 0) {
      bloc.add(LooperLaneInputChanged(widget.channel, 0, input));
      return;
    }
    final spare = lanes.indexWhere((lane) => lane.inputChannel < 0);
    if (spare >= 0) {
      bloc.add(LooperLaneInputChanged(widget.channel, spare, input));
      return;
    }
    // Grow first, so the engine has allocated the lane before it is routed.
    final next = lanes.isEmpty ? 1 : lanes.length;
    bloc
      ..add(LooperLaneCountChanged(widget.channel, next + 1))
      ..add(LooperLaneInputChanged(widget.channel, next, input));
  }

  /// Which lane records [input], or null when none does.
  int? _laneOf(Track track, int input) {
    final index = track.lanes.indexWhere((lane) => lane.inputChannel == input);
    if (index >= 0) return index;
    // A stopped engine reports no lanes; the lane-0 mirror still says what it
    // would be recording.
    if (track.lanes.isEmpty && maskToInputChannel(track.inputMask) == input) {
      return 0;
    }
    return null;
  }

  /// Where lane [lane] is sent — the lane-0 mirror when there are no lanes.
  int _outputsOf(Track track, int? lane) {
    if (lane == null) return 0;
    if (lane < track.lanes.length) return track.lanes[lane].outputMask;
    return track.outputMask;
  }

  /// Clean: every lane keeps its audio and records nothing.
  void _recordNothing(Track track) {
    final bloc = context.read<LooperBloc>();
    final lanes = track.lanes.length;
    for (var lane = 0; lane < (lanes == 0 ? 1 : lanes); lane++) {
      bloc.add(LooperLaneInputChanged(widget.channel, lane, -1));
    }
  }

  void _setQuantize(bool? enabled) {
    setState(() => _quantize = enabled);
    context.read<LooperBloc>().add(
      LooperTrackQuantizeChanged(widget.channel, enabled: enabled),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<LooperBloc>().state;
    final globalQuantize = context.watch<QuantizeCubit>().state;
    final names = context.watch<TracksCubit>().state;
    final track = state.tracks.firstWhere(
      (t) => t.channel == widget.channel,
      orElse: () => Track(channel: widget.channel),
    );
    final inputCount = state.status.inputChannels > 0
        ? state.status.inputChannels
        : kFallbackInputCount;
    final outputCount = state.status.outputChannels > 0
        ? state.status.outputChannels
        : kFallbackOutputCount;
    final inputs = _inputsOf(track);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 744),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: surface.borderStrong),
          ),
          child: Padding(
            padding: const EdgeInsets.all(25),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    // The rig's own word for this track, not its ordinal.
                    l10n.trackSettingsNamedTitle(
                      l10n.trackName(names.names, widget.channel),
                    ),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    // The ordinal belongs UNDER the name, not instead of it:
                    // it still says which pad on the pedal this is.
                    l10n.tracksRowOrdinal(widget.channel + 1),
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 19),
                  ConsoleGroupLabel(l10n.trackLanesGroup),
                  const SizedBox(height: 10),
                  ConsoleCard(
                    color: surface.background,
                    children: [
                      // The chosen row also says `live`, as the mockups mark
                      // it: a check says "this is selected", and the point of
                      // the input list is which one is being recorded RIGHT
                      // NOW.
                      // Multi-select: every checked input is a lane of its
                      // own, and a checked row opens onto that lane's
                      // outputs. An unchecked one is just an input to add.
                      for (var i = 0; i < inputCount; i++)
                        _LaneRow(
                          key: Key('track_input_$i'),
                          label: l10n.inputChannelLabel(i + 1),
                          lane: _laneOf(track, i),
                          outputCount: outputCount,
                          outputMask: _outputsOf(track, _laneOf(track, i)),
                          expanded: _openLane != null &&
                              _openLane == _laneOf(track, i),
                          onToggle: () => _toggleInput(track, i),
                          onOpen: () => setState(() {
                            final lane = _laneOf(track, i);
                            _openLane = _openLane == lane ? null : lane;
                          }),
                          onToggleOutput: (output) => _toggleOutput(
                            _laneOf(track, i)!,
                            _outputsOf(track, _laneOf(track, i)),
                            output,
                          ),
                        ),
                      _PickRow(
                        key: const Key('track_input_none'),
                        label: l10n.signalInputNone,
                        value: inputs.isEmpty ? l10n.trackInputLive : null,
                        selected: inputs.isEmpty,
                        divider: false,
                        onTap: () => _recordNothing(track),
                      ),
                    ],
                  ),
                  const SizedBox(height: 19),
                  ConsoleGroupLabel(l10n.trackQuantizeGroup),
                  const SizedBox(height: 10),
                  ConsoleCard(
                    color: surface.background,
                    children: [
                      _PickRow(
                        key: const Key('track_quantize_follow'),
                        label: l10n.trackQuantizeFollow,
                        // What following the global setting means RIGHT NOW,
                        // so the choice does not have to be looked up on
                        // another face.
                        value: globalQuantize ? l10n.toggleOn : l10n.toggleOff,
                        selected: _quantize == null,
                        onTap: () => _setQuantize(null),
                      ),
                      _PickRow(
                        key: const Key('track_quantize_always'),
                        label: l10n.trackQuantizeAlways,
                        selected: _quantize ?? false,
                        onTap: () => _setQuantize(true),
                      ),
                      _PickRow(
                        key: const Key('track_quantize_never'),
                        label: l10n.trackQuantizeNever,
                        selected: _quantize == false,
                        divider: false,
                        onTap: () => _setQuantize(false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 19),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ConsoleSmallButton(
                      key: const Key('track_routing_done'),
                      label: l10n.done,
                      large: true,
                      accent: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Outputs belong to the LANE, which is what the engine has always modelled
  /// and what a two-input track needs: a guitar lane going to the mains while
  /// its DI lane goes to the desk is one track, two destinations.
  void _toggleOutput(int lane, int mask, int output) => context
      .read<LooperBloc>()
      .add(LooperLaneOutputChanged(widget.channel, lane, mask ^ (1 << output)));
}

/// One choice in the sheet's lists: a check in the gutter when it is current,
/// an empty gutter when it is not, so the labels stay on one line down the
/// list either way.
class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.value,
    this.divider = true,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? value;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ConsoleRow(
      title: label,
      value: value,
      divider: divider,
      showDisclosure: false,
      onTap: onTap,
      leading: SizedBox(
        width: 33,
        child: Align(
          alignment: Alignment.centerRight,
          child: selected
              ? Icon(Icons.check, size: 18, color: surface.accent)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// One input in the lane list.
///
/// Unchecked it is just an input to add. Checked it IS a lane, so it carries
/// that lane's outputs — as a summary on the right, and as chips when the row
/// is opened. A lane recording something and routed nowhere says so here,
/// where the outputs are, rather than as a note about the whole track: with
/// one lane per input, "this track is silent" is no longer the same statement
/// as "this lane is".
class _LaneRow extends StatelessWidget {
  const _LaneRow({
    required this.label,
    required this.lane,
    required this.outputCount,
    required this.outputMask,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
    required this.onToggleOutput,
    super.key,
  });

  final String label;

  /// The lane this input records into, or null when it records nothing.
  final int? lane;

  final int outputCount;
  final int outputMask;
  final bool expanded;

  /// Checks or unchecks the input — adds or frees its lane.
  final VoidCallback onToggle;

  /// Opens the lane's outputs.
  final VoidCallback onOpen;

  final ValueChanged<int> onToggleOutput;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final recording = lane != null;
    final routed = outputMask != 0;

    final row = ConsoleRow(
      title: label,
      value: recording
          ? (routed ? _outputs(l10n, outputMask) : l10n.trackRoutingSummaryNone)
          : null,
      valueColor: recording && !routed ? surface.warning : null,
      showDisclosure: recording,
      expanded: expanded,
      // Checking is the tap target while the row is closed; once it is a lane,
      // the row opens and the check itself un-checks it.
      onTap: recording ? onOpen : onToggle,
      leading: _CheckGutter(
        selected: recording,
        onTap: recording ? onToggle : null,
      ),
    );

    if (!recording) return row;
    // Not ConsoleExpandedRow: its action strip is a right-aligned row of
    // chips, and a lane opens onto a captioned block — chips, and the warning
    // when they are all off. Same expansion primitive, same motion.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        ConsoleExpansion(
          expanded: expanded,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            // The strip spans the row it belongs to; without this the block
            // shrinks to its chips and floats mid-card.
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: surface.control,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConsoleGroupLabel(l10n.laneOutputsGroup),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < outputCount; i++)
                          ConsoleToggleChip(
                            key: Key('track_output_${lane}_$i'),
                            label: l10n.outputChannelLabel(i + 1),
                            selected: outputMask & (1 << i) != 0,
                            onPressed: () => onToggleOutput(i),
                          ),
                      ],
                    ),
                    if (!routed) ...[
                      const SizedBox(height: 12),
                      _UnroutedNote(
                        key: const Key('track_unrouted_banner'),
                        text: l10n.laneUnroutedWarning,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      l10n.laneEffectsNote,
                      style: TextStyle(color: surface.textMuted, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _outputs(AppLocalizations l10n, int mask) => [
    for (var i = 0; i < 32; i++)
      if (mask & (1 << i) != 0) l10n.outputChannelLabel(i + 1),
  ].join(' · ');
}

/// The check gutter, at the mockups' 40px inset. Tappable on a lane row, so
/// the check both SHOWS and UNDOES the choice.
class _CheckGutter extends StatelessWidget {
  const _CheckGutter({required this.selected, this.onTap});

  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final glyph = SizedBox(
      width: 33,
      child: Align(
        alignment: Alignment.centerRight,
        child: selected
            ? Icon(Icons.check, size: 18, color: surface.accent)
            : const SizedBox.shrink(),
      ),
    );
    if (onTap == null) return glyph;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: glyph,
    );
  }
}

/// A lane that records but goes nowhere, said inside the lane's own strip.
class _UnroutedNote extends StatelessWidget {
  const _UnroutedNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(color: surface.rec, shape: BoxShape.circle),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: surface.textSecondary, fontSize: 16),
          ),
        ),
      ],
    );
  }
}
