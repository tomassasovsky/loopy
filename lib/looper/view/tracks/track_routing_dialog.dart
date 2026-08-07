import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/tracks/routing_tracks_tab.dart';
import 'package:segno/looper/view/tracks/tracks_face.dart';
import 'package:segno/theme/theme.dart';

/// Opens track [channel]'s own routing panel.
///
/// A centred dialog rather than a bottom sheet, as the mockups draw it: it is
/// two grouped lists, and a sheet tall enough to hold them is the whole screen
/// anyway. It re-provides everything it reads, because a dialog route is built
/// by the navigator and inherits nothing from the caller's subtree.
Future<void> showTrackRoutingDialog(
  BuildContext context, {
  required int channel,
}) {
  final looper = context.read<LooperBloc>();
  final tracks = context.read<TracksCubit>();
  final quantize = context.read<QuantizeCubit>();
  final repository = context.read<LooperRepository>();
  return showDialog<void>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: looper),
        BlocProvider.value(value: tracks),
        BlocProvider.value(value: quantize),
      ],
      child: RepositoryProvider.value(
        value: repository,
        child: _TrackRoutingDialog(channel: channel),
      ),
    ),
  );
}

/// The routing rule this panel exists to express, stated precisely because a
/// smaller-sounding version of it is wrong:
///
/// > **A track records any set of inputs — one dry lane each, sharing the
/// > track's transport and loop. Lane index is identity.**
///
/// Checking an input gives the track a lane for it; unchecking frees that
/// lane. Two consequences follow, and [_TrackRoutingDialogState._toggleInput]
/// implements both literally:
///
/// - **Dropping an input sets its own lane to record nothing (`-1`) and leaves
///   the lane where it is.** It does not compact the list.
/// - **Adding an input reuses such a freed lane before growing the track**,
///   and grows first when there is none, so the engine has allocated the lane
///   before it is routed.
///
/// The alternative — rebuild the lane list as "sorted inputs, one per index" —
/// is the obvious implementation and the one to refuse. Lane 2 holds lane 2's
/// recorded audio; renumbering would silently move a take from one source to
/// another whenever an input was added in the middle of the set. The panel
/// would look right and the loop would play the wrong thing.
class _TrackRoutingDialog extends StatefulWidget {
  const _TrackRoutingDialog({required this.channel});

  final int channel;

  @override
  State<_TrackRoutingDialog> createState() => _TrackRoutingDialogState();
}

class _TrackRoutingDialogState extends State<_TrackRoutingDialog> {
  /// The lane whose outputs are showing, or null. One at a time, like every
  /// other console list.
  int? _openLane;

  /// The quantize override, read once and then owned here.
  ///
  /// It is not on `Track` and not in the engine snapshot — the engine takes
  /// the value and never reports it back — so unlike everything else on this
  /// panel it cannot be re-read from the bloc on every build.
  late bool? _quantize = context.read<LooperRepository>().trackQuantize(
    widget.channel,
  );

  /// The panel's own width cap. Wider than this and the two lists become a
  /// pair of very long rows with their readouts a hand-span from their names.
  static const double _width = 744;

  /// Recording [input], or freeing the lane that already does.
  ///
  /// Applied as it is tapped — the Done button dismisses, it does not commit.
  /// A routing panel with an OK button would imply the changes were not
  /// already audible.
  void _toggleInput(List<Lane> lanes, int input) {
    final bloc = context.read<LooperBloc>();
    final channel = widget.channel;
    final existing = lanes.indexWhere((lane) => lane.inputChannel == input);
    if (existing >= 0) {
      // Frees the lane IN PLACE. Compacting here is what would renumber the
      // lanes and move a recorded take onto another source.
      bloc.add(LooperLaneInputChanged(channel, existing, -1));
      if (_openLane == existing) setState(() => _openLane = null);
      return;
    }
    final freed = lanes.indexWhere((lane) => lane.inputChannel < 0);
    if (freed >= 0) {
      bloc.add(LooperLaneInputChanged(channel, freed, input));
      return;
    }
    // Grow FIRST, so the lane exists before it is routed.
    bloc
      ..add(LooperLaneCountChanged(channel, lanes.length + 1))
      ..add(LooperLaneInputChanged(channel, lanes.length, input));
  }

  /// Stops every lane recording while each keeps the audio it already has.
  void _recordNothing(List<Lane> lanes) {
    final bloc = context.read<LooperBloc>();
    for (final (lane, value) in lanes.indexed) {
      if (value.inputChannel < 0) continue;
      bloc.add(LooperLaneInputChanged(widget.channel, lane, -1));
    }
    setState(() => _openLane = null);
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
    final names = context.watch<TracksCubit>().state.names;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _width),
          child: Container(
            key: Key('track_routing_dialog_${widget.channel}'),
            padding: const EdgeInsets.all(25),
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: surface.borderStrong),
            ),
            child: BlocBuilder<LooperBloc, LooperState>(
              buildWhen: (previous, current) =>
                  !sameRouting(previous.tracks, current.tracks) ||
                  previous.status.inputChannels !=
                      current.status.inputChannels ||
                  previous.status.outputChannels !=
                      current.status.outputChannels,
              builder: (context, state) {
                final track = widget.channel < state.tracks.length
                    ? state.tracks[widget.channel]
                    : const Track();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.trackSettingsDialogTitle(
                        l10n.trackName(names, widget.channel),
                      ),
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 19,
                        height: 1.16,
                        leadingDistribution: TextLeadingDistribution.even,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: kConsoleLabelGap),
                    // The ordinal stays under the name, where it still says
                    // which pad on the pedal this track is.
                    Text(
                      l10n.tracksOrdinal(widget.channel + 1),
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 16,
                        height: 1.55,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                    const SizedBox(height: kConsoleGroupGap),
                    ConsoleGroupLabel(l10n.trackLanesGroup),
                    const SizedBox(height: kConsoleLabelGap),
                    _lanes(context, state, track),
                    const SizedBox(height: kConsoleGroupGap),
                    ConsoleGroupLabel(l10n.trackQuantizeGroup),
                    const SizedBox(height: kConsoleLabelGap),
                    _quantizeGroup(context),
                    const SizedBox(height: kConsoleGroupGap),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ConsoleDialogButton(
                          key: const Key('track_routing_done'),
                          label: l10n.done,
                          tone: ConsoleDialogTone.accent,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- lanes

  /// One row per hardware input, plus the row that clears them all.
  ///
  /// **A checked input row IS a lane row**: it carries that lane's outputs as
  /// its readout and opens in place onto that lane's chips. Outputs belong to
  /// the lane, not the track — a guitar lane going to the mains while its DI
  /// lane goes to the desk is one track with two destinations, which a single
  /// track-wide output group cannot express.
  Widget _lanes(BuildContext context, LooperState state, Track track) {
    final l10n = context.l10n;
    final surface = context.surface;
    final lanes = track.lanes;
    // The engine reports 0 before the device is open; 2 is what every other
    // surface assumes then.
    final inputs = state.status.inputChannels > 0
        ? state.status.inputChannels
        : 2;
    final outputs = state.status.outputChannels > 0
        ? state.status.outputChannels
        : 2;
    final recording = recordedInputs(track);

    return ConsoleCard(
      fill: surface.background,
      children: [
        for (var input = 0; input < inputs; input++)
          ..._laneRow(context, lanes, input, outputs),
        ConsolePickRow(
          key: const Key('track_routing_none'),
          title: l10n.tracksNoInputs,
          // Checked when nothing is recorded: this row is the state "no lane
          // records anything", not a button that always looks unpicked.
          selected: recording.isEmpty,
          showDivider: false,
          onTap: () => _recordNothing(lanes),
        ),
      ],
    );
  }

  List<Widget> _laneRow(
    BuildContext context,
    List<Lane> lanes,
    int input,
    int outputs,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final lane = lanes.indexWhere((value) => value.inputChannel == input);
    final recorded = lane >= 0;
    final open = recorded && _openLane == lane;
    final mask = recorded ? lanes[lane].outputMask : 0;
    final label = l10n.inputChannelLabel(input + 1);
    return [
      ConsoleRow(
        key: Key('track_routing_input_$input'),
        // One step in, so the check column lines up with the pick rows of the
        // quantize group under it.
        indented: true,
        leading: _LaneCheck(
          key: Key('track_routing_check_$input'),
          recorded: recorded,
          semanticLabel: recorded
              ? l10n.a11yTrackLaneRecording(label)
              : l10n.a11yTrackLaneIdle(label),
          // The check gutter both SHOWS and UNDOES the choice. It only takes
          // the tap once the lane exists; while the row is unchecked the whole
          // row, gutter included, is the thing that checks it.
          onTap: recorded ? () => _toggleInput(lanes, input) : null,
        ),
        title: label,
        state: recorded
            ? (mask == 0
                  ? l10n.trackLaneOutputsNone
                  : outputMaskLabel(l10n, mask))
            : null,
        valueColor: recorded && mask == 0 ? surface.warning : null,
        // An unchecked input is not a lane, so it has nothing to open and
        // draws no marker — the gutter stays reserved so the list's trailing
        // edge does not move as lanes come and go.
        expanded: recorded ? open : null,
        fill: open ? surface.control : null,
        onTap: () {
          if (!recorded) {
            _toggleInput(lanes, input);
            return;
          }
          setState(() => _openLane = open ? null : lane);
        },
      ),
      ConsoleChooser(
        key: Key('track_routing_outputs_$input'),
        open: open,
        children: [
          ConsoleDrawerLabel(l10n.trackLaneOutputsGroup),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ConsoleRow.indentedInset,
              0,
              kConsoleRowInset,
              kConsoleBlockGap,
            ),
            child: ConsoleChipGrid<int>(
              // A bitmask, not a pick-one: a lane is sent to ANY set of
              // outputs, so several cells are lit and a tap toggles one bit.
              // Nothing here closes the drawer — no single tap answers it.
              selected: {
                for (var out = 0; out < outputs; out++)
                  if (mask & (1 << out) != 0) out,
              },
              options: [
                for (var out = 0; out < outputs; out++)
                  ConsoleSegment(
                    value: out,
                    label: l10n.outputChannelLabel(out + 1),
                    optionKey: Key('track_routing_out_${input}_$out'),
                  ),
              ],
              onTap: (out) => context.read<LooperBloc>().add(
                LooperLaneOutputChanged(
                  widget.channel,
                  lane,
                  mask ^ (1 << out),
                ),
              ),
            ),
          ),
          if (mask == 0)
            // "This track is silent" is no longer the same statement as "this
            // lane is", so the warning sits inside the lane strip it describes
            // — next to the chips that are all off.
            ConsoleBanner(
              key: Key('track_routing_unrouted_$input'),
              message: l10n.trackLaneUnrouted,
              tone: ConsoleBannerTone.failure,
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ConsoleRow.indentedInset,
                0,
                kConsoleRowInset,
                kConsoleBlockGap,
              ),
              // Said explicitly rather than left as a gap where a chain editor
              // looks like it should be: per-lane effects stay on Signal.
              child: ConsoleProse(l10n.trackLaneFxNote),
            ),
        ],
      ),
    ];
  }

  // -------------------------------------------------------------- quantize

  /// Follow / always / never, with what "follow" currently MEANS spelled out.
  ///
  /// The three sit flat rather than behind a row that opens: this panel is
  /// already the editor, and hiding three alternatives inside a fourth row
  /// would put a chooser inside a chooser.
  Widget _quantizeGroup(BuildContext context) {
    final l10n = context.l10n;
    final global = context.watch<QuantizeCubit>().state;
    return ConsoleCard(
      fill: context.surface.background,
      children: [
        ConsolePickRow(
          key: const Key('track_routing_quantize_follow'),
          title: l10n.trackQuantizeFollow,
          state: global
              ? l10n.trackQuantizeGlobalOn
              : l10n.trackQuantizeGlobalOff,
          selected: _quantize == null,
          onTap: () => _setQuantize(null),
        ),
        ConsolePickRow(
          key: const Key('track_routing_quantize_always'),
          title: l10n.trackQuantizeAlways,
          selected: _quantize ?? false,
          onTap: () => _setQuantize(true),
        ),
        ConsolePickRow(
          key: const Key('track_routing_quantize_never'),
          title: l10n.trackQuantizeNever,
          selected: _quantize == false,
          showDivider: false,
          onTap: () => _setQuantize(false),
        ),
      ],
    );
  }
}

/// A lane row's check gutter: the mark, and the target that undoes it.
///
/// Its own tap target rather than part of the row's, because the row body and
/// the gutter answer two different questions — *show me this lane* and *stop
/// recording this input*. The slot is the same width lit or not, so the names
/// beside it do not move as lanes come and go.
class _LaneCheck extends StatelessWidget {
  const _LaneCheck({
    required this.recorded,
    required this.semanticLabel,
    required this.onTap,
    super.key,
  });

  final bool recorded;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: ConsolePickRow.checkWidth,
      child: recorded ? const ConsoleCheck() : const SizedBox.shrink(),
    );
    if (onTap == null) return mark;
    return FocusableTapTarget(
      onTap: onTap,
      selected: recorded,
      semanticLabel: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: mark,
      ),
    );
  }
}
