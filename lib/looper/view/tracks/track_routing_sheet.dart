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
    final input = maskToInputChannel(track.inputMask);

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
                    l10n.trackSettingsTitle(widget.channel + 1),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l10n.trackRoutingSubtitle(names.nameOf(widget.channel)),
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
                      for (var i = 0; i < inputCount; i++)
                        _PickRow(
                          key: Key('track_input_$i'),
                          label: l10n.inputChannelLabel(i + 1),
                          value: input == i ? l10n.trackInputLive : null,
                          selected: input == i,
                          onTap: () => _setInput(i),
                        ),
                      _PickRow(
                        key: const Key('track_input_none'),
                        label: l10n.signalInputNone,
                        value: input < 0 ? l10n.trackInputLive : null,
                        selected: input < 0,
                        divider: false,
                        onTap: () => _setInput(-1),
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
                          onPressed: () => _toggleOutput(track.outputMask, i),
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

  /// Lane 0, not the track's input mask: a lane records ONE input, and the
  /// mask setter picks the lowest set bit, which quietly loses the choice on
  /// any track with more than one lane. Multi-lane tracks keep the Signal
  /// page for the rest of their lanes.
  void _setInput(int inputChannel) => context.read<LooperBloc>().add(
    LooperLaneInputChanged(widget.channel, 0, inputChannel),
  );

  void _toggleOutput(int mask, int output) => context.read<LooperBloc>().add(
    LooperLaneOutputChanged(widget.channel, 0, mask ^ (1 << output)),
  );
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
