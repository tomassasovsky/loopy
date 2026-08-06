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
                  ConsoleGroupLabel(l10n.trackRecordedInputGroup),
                  const SizedBox(height: 10),
                  ConsoleCard(
                    color: surface.background,
                    children: [
                      // The chosen row also says `live`, as the mockups mark
                      // it: a check says "this is selected", and the point of
                      // the input list is which one is being recorded RIGHT
                      // NOW.
                      // Multi-select: every checked input is a lane of its
                      // own. The chosen rows also say `live`, as the mockups
                      // mark them — a check says "this is selected", and the
                      // point of the list is what is being recorded RIGHT NOW.
                      for (var i = 0; i < inputCount; i++)
                        _PickRow(
                          key: Key('track_input_$i'),
                          label: l10n.inputChannelLabel(i + 1),
                          value: inputs.contains(i)
                              ? l10n.trackInputLive
                              : null,
                          selected: inputs.contains(i),
                          onTap: () => _toggleInput(track, i),
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
                  ConsoleGroupLabel(l10n.trackOutputsGroup),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < outputCount; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        ConsoleToggleChip(
                          key: Key('track_output_$i'),
                          label: l10n.outputChannelLabel(i + 1),
                          selected: track.outputMask & (1 << i) != 0,
                          onPressed: () =>
                              _toggleOutput(track, track.outputMask, i),
                        ),
                      ],
                    ],
                  ),
                  if (track.outputMask == 0) ...[
                    const SizedBox(height: 10),
                    _UnroutedBanner(text: l10n.trackUnroutedWarning),
                  ],
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

  /// Outputs are per lane in the engine, but this panel offers one set for
  /// the whole track, as the mockups draw it: the lanes of a track are one
  /// instrument's capture, and sending half of it somewhere else is a Signal
  /// page job, not a routing summary.
  void _toggleOutput(Track track, int mask, int output) {
    final bloc = context.read<LooperBloc>();
    final next = mask ^ (1 << output);
    final lanes = track.lanes.isEmpty ? 1 : track.lanes.length;
    for (var lane = 0; lane < lanes; lane++) {
      bloc.add(LooperLaneOutputChanged(widget.channel, lane, next));
    }
  }
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

/// The mockups' unrouted warning: a red dot and a sentence, on the same
/// recessed fill as the lists it sits between.
class _UnroutedBanner extends StatelessWidget {
  const _UnroutedBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 14, 20, 14),
        child: Row(
          key: const Key('track_unrouted_banner'),
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: surface.rec,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: surface.textSecondary, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
