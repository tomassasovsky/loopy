import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

  /// The panel's own width cap. Wider than this and the two lists become a
  /// pair of very long rows with their readouts a hand-span from their names.
  static const double _width = 744;

  /// How far the panel stays off the screen edge — the mockup's own scrim
  /// inset, and what gives the panel a height to fit inside.
  static const double _scrimInset = 29;

  /// The quantize group's own height: its caption, plus the three rows it
  /// always has — follow, always, never — in a card that insets 1px top and
  /// bottom.
  ///
  /// Fixed because the QUESTION is: a track's override on the global setting
  /// has exactly three answers, and a fourth would be a different control.
  /// [_StickyGroups] needs it to know when the real caption has risen far
  /// enough to take the preview's place.
  static const double _quantizeExtent =
      _PinnedGroupLabel.extent + kConsoleRowHeight * 3 + 2;

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
    // The engine caps a track at [kMaxLanes] lanes and rejects both writes
    // past it — while a device may report up to 32 inputs, so this IS
    // reachable. Stop rather than dispatch them: the repository caches and
    // the bloc persists a lane input unconditionally, so a lane index the
    // engine can never have would be replayed on every restart.
    // [_laneRow] withholds the tap in the same state, so this is the backstop.
    if (lanes.length >= kMaxLanes) return;
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

  void _setQuantize(bool? enabled) => context.read<LooperBloc>().add(
    LooperTrackQuantizeChanged(widget.channel, enabled: enabled),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final names = context.watch<TracksCubit>().state.names;

    return Center(
      // Inset from the screen edge, as the mockup's scrim is, and the reason
      // the panel has a height at all: an eight-input rig with a lane open is
      // taller than 1080, and a Column that tall overflows rather than
      // scrolling.
      child: Padding(
        padding: const EdgeInsets.all(_scrimInset),
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
                    !sameQuantize(previous.tracks, current.tracks) ||
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
                      // The GROUPS scroll, not the whole panel: the title says
                      // which track this is and Done is how you leave, so both
                      // stay put however many inputs the rig has.
                      //
                      // Both captions are STICKY. A caption belongs to what is
                      // under it, and a lane list long enough to scroll is
                      // exactly where "which group am I in?" stops being
                      // obvious — so LANES holds the top until QUANTIZE
                      // RECORDING arrives and pushes it out, and one of the two
                      // is overhead at every scroll position.
                      //
                      // Flexible, not Expanded — a short panel still shrinks to
                      // its content the way the mockup draws it, and nothing
                      // scrolls until the content runs out of room.
                      Flexible(
                        child: _StickyGroups(
                          // What the caption at the bottom edge says, and what
                          // it hands over to.
                          upcoming: l10n.trackQuantizeGroup,
                          upcomingExtent: _quantizeExtent,
                          slivers: [
                            // A group per caption, so a caption pins only
                            // while its OWN section is passing: plain pinned
                            // headers stack up at the top instead, which ends
                            // with both captions overhead and neither of them
                            // attached to what is under it.
                            SliverMainAxisGroup(
                              slivers: [
                                _PinnedGroupLabel(l10n.trackLanesGroup),
                                SliverToBoxAdapter(
                                  child: _lanes(context, state, track),
                                ),
                              ],
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: kConsoleGroupGap),
                            ),
                            SliverMainAxisGroup(
                              slivers: [
                                _PinnedGroupLabel(l10n.trackQuantizeGroup),
                                SliverToBoxAdapter(
                                  child: _quantizeGroup(context, track),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
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
    final deviceInputs = state.status.inputChannels > 0
        ? state.status.inputChannels
        : 2;
    final outputs = state.status.outputChannels > 0
        ? state.status.outputChannels
        : 2;
    final recording = recordedInputs(track);
    // The device's own jacks, plus any input a lane is ALREADY recording that
    // this device has not got — a session saved on an eight-in rig still
    // records In 6 when it is reopened on a two-in one, and the Routing tab's
    // summary says so. That lane needs a row or the panel cannot uncheck it,
    // and the list would show nothing recorded while `None (clean)` stayed
    // unlit. Only the recorded ones, though: a row for a jack that is neither
    // present nor in use would OFFER to record silence.
    // `recording` is ascending, so this stays in channel order.
    final inputs = [
      for (var input = 0; input < deviceInputs; input++) input,
      ...recording.where((input) => input >= deviceInputs),
    ];
    // The engine caps a track at [kMaxLanes] lanes; a device can report more
    // inputs than that. With every lane occupied there is none left to give a
    // further input, so those rows stop offering the tap.
    final full =
        lanes.length >= kMaxLanes &&
        !lanes.any((lane) => lane.inputChannel < 0);

    return ConsoleCard(
      fill: surface.background,
      children: [
        for (final input in inputs)
          ..._laneRow(context, lanes, input, outputs, full: full),
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
    int outputs, {
    required bool full,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final lane = lanes.indexWhere((value) => value.inputChannel == input);
    final recorded = lane >= 0;
    final open = recorded && _openLane == lane;
    final mask = recorded ? lanes[lane].outputMask : 0;
    final label = l10n.inputChannelLabel(input + 1);
    // The device's own outputs, plus any bit this lane ALREADY reaches that
    // the device has not got — same rule as the rows themselves, and for the
    // same reason: a mask bit carried in from a wider rig needs a cell or the
    // readout names an output the drawer cannot turn off, while a cell for a
    // socket that is neither present nor in use would only add routing that
    // can never be heard.
    final cells = [
      for (var out = 0; out < outputs; out++) out,
      for (var out = outputs; out < mask.bitLength; out++)
        if (mask & (1 << out) != 0) out,
    ];
    // With every lane occupied there is none left for a further input, so
    // those rows take no tap rather than one the engine would drop.
    final inert = !recorded && full;
    final readout = recorded
        ? (mask == 0 ? l10n.trackLaneOutputsNone : outputMaskLabel(l10n, mask))
        : null;
    // What the row SAYS about where the lane goes — built from the lane, not
    // borrowed from the readout beside it. `nothing` is a token: it works in a
    // column under a warning tint and, spoken, is a dangling noun that states
    // no problem at all. The unrouted lane gets the sentence the drawer would
    // show, which is the only place that fact is otherwise said.
    final spokenRouting = recorded
        ? (mask == 0 ? l10n.trackLaneUnrouted : outputMaskLabel(l10n, mask))
        : null;
    return [
      ConsoleRow(
        key: Key('track_routing_input_$input'),
        // One step in, so the check column lines up with the pick rows of the
        // quantize group under it.
        indented: true,
        leading: _LaneCheck(
          key: Key('track_routing_check_$input'),
          recorded: recorded,
          // The check gutter both SHOWS and UNDOES the choice. It only takes
          // the tap once the lane exists; while the row is unchecked the whole
          // row, gutter included, is the thing that checks it.
          //
          // It carries no label of its own: [ConsoleRow] hands its own
          // `semanticLabel` to `FocusableTapTarget`, which EXCLUDES everything
          // it wraps, so a nested label here never reaches the tree. The row
          // says the lane's state below, and the gutter's action is exposed
          // beside it as a custom action.
          onTap: recorded ? () => _toggleInput(lanes, input) : null,
        ),
        title: label,
        // A row the track has no lane left for is drawn in the muted ink the
        // console uses for "listed, but not choosable right now" — otherwise it
        // is indistinguishable from the available rows above it and swallows
        // the tap with nothing said.
        titleColor: inert ? surface.textMuted : null,
        state: readout,
        valueColor: recorded && mask == 0 ? surface.warning : null,
        // The sentence rides the ROW, which is the node assistive tech gets,
        // and it says what the row will actually do. The idle one reads
        // "activate to record it" and the row's own tap does exactly that; the
        // recorded one says where the lane goes, because the row's tap opens
        // the drawer and stopping is the custom action below; the capped one
        // promises nothing, because a row with no lane left to give takes no
        // tap — the muted ink says so to the eye, and this says it aloud.
        semanticLabel: [
          if (recorded)
            l10n.a11yTrackLaneRecording(label)
          else if (inert)
            l10n.a11yTrackLaneNoLane(label)
          else
            l10n.a11yTrackLaneIdle(label),
          ?spokenRouting,
          // Space, not the row's usual comma: both sentences already end in a
          // full stop, and ", " after one reads as a stutter.
        ].join(' '),
        // The gutter's own semantics go out with the rest of the row's, so the
        // un-route is published on the row instead. Without it a screen reader
        // can only reach `None (clean)`, which clears EVERY lane on the track.
        customSemanticsActions: recorded
            ? {
                CustomSemanticsAction(
                  label: l10n.a11yTrackLaneStopRecording,
                ): () =>
                    _toggleInput(lanes, input),
              }
            : null,
        // An unchecked input is not a lane, so it has nothing to open and
        // draws no marker — the gutter stays reserved so the list's trailing
        // edge does not move as lanes come and go.
        expanded: recorded ? open : null,
        fill: open ? surface.control : null,
        onTap: inert
            ? null
            : () {
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
                for (final out in cells)
                  if (mask & (1 << out) != 0) out,
              },
              options: [
                for (final out in cells)
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
  Widget _quantizeGroup(BuildContext context, Track track) {
    final l10n = context.l10n;
    final global = context.watch<QuantizeCubit>().state;
    final override = track.quantizeOverride;
    return ConsoleCard(
      fill: context.surface.background,
      children: [
        ConsolePickRow(
          key: const Key('track_routing_quantize_follow'),
          title: l10n.trackQuantizeFollow,
          state: global
              ? l10n.trackQuantizeGlobalOn
              : l10n.trackQuantizeGlobalOff,
          selected: override == null,
          onTap: () => _setQuantize(null),
        ),
        ConsolePickRow(
          key: const Key('track_routing_quantize_always'),
          title: l10n.trackQuantizeAlways,
          selected: override ?? false,
          onTap: () => _setQuantize(true),
        ),
        ConsolePickRow(
          key: const Key('track_routing_quantize_never'),
          title: l10n.trackQuantizeNever,
          selected: override == false,
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
    required this.onTap,
    super.key,
  });

  final bool recorded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: ConsolePickRow.checkWidth,
      child: recorded ? const ConsoleCheck() : const SizedBox.shrink(),
    );
    // Deliberately unlabelled: [ConsoleRow] hands its own `semanticLabel` to
    // `FocusableTapTarget`, which wraps everything it holds in
    // `ExcludeSemantics`, so a label given here would be dropped rather than
    // announced. The row carries both sentences and the un-route action.
    if (onTap == null) return mark;
    return FocusableTapTarget(
      onTap: onTap,
      selected: recorded,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: mark,
      ),
    );
  }
}

/// A group caption that stays overhead while its own list scrolls under it.
///
/// Pinned rather than scrolling away, because on this panel the caption is the
/// only thing that says which of the two questions a row answers. It carries
/// the panel's own fill so the rows pass *behind* it rather than through it,
/// and it reserves [kConsoleLabelGap] under itself — a caption belongs to what
/// is beneath it, so that gap travels with the caption rather than staying
/// behind with the list.
class _PinnedGroupLabel extends StatelessWidget {
  const _PinnedGroupLabel(this.label);

  final String label;

  /// The caption's own line, at [ConsoleGroupLabel]'s 13px × 1.23.
  static const double _lineHeight = 16;

  /// What one caption occupies: its line, plus the gap it carries with it.
  static const double extent = _lineHeight + kConsoleLabelGap;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _PinnedGroupLabelDelegate(
      label: label,
      fill: context.surface.card,
    ),
  );
}

class _PinnedGroupLabelDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedGroupLabelDelegate({required this.label, required this.fill});

  final String label;
  final Color fill;

  @override
  double get minExtent => _PinnedGroupLabel.extent;

  @override
  double get maxExtent => _PinnedGroupLabel.extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    color: fill,
    alignment: Alignment.topLeft,
    child: ConsoleGroupLabel(label),
  );

  @override
  bool shouldRebuild(_PinnedGroupLabelDelegate oldDelegate) =>
      oldDelegate.label != label || oldDelegate.fill != fill;
}

/// The panel's scrolling middle: sticky group captions, plus a preview of the
/// group you have not reached yet, pinned to the bottom edge.
///
/// Two captions and one viewport is the problem this solves. Pinning both at
/// the top stacks them, which says nothing — a caption belongs to what is
/// under it, and two of them overhead belong to nothing. Pinning only the
/// current one is honest but leaves the panel's second question invisible
/// until you have scrolled the whole lane list to find out it exists.
///
/// So the *current* caption pins overhead (each group is its own
/// [SliverMainAxisGroup], so it is pushed out by the next rather than stacking
/// under it), and the *next* one waits at the bottom edge. It is dropped the
/// moment the real one rises into view, so the two are never on screen at
/// once and the handover has no seam.
class _StickyGroups extends StatefulWidget {
  const _StickyGroups({
    required this.slivers,
    required this.upcoming,
    required this.upcomingExtent,
  });

  /// The groups, in display order.
  final List<Widget> slivers;

  /// The last group's caption — the one previewed at the bottom.
  final String upcoming;

  /// How tall the last group is, caption included.
  final double upcomingExtent;

  @override
  State<_StickyGroups> createState() => _StickyGroupsState();
}

class _StickyGroupsState extends State<_StickyGroups> {
  /// Whether the last group's real caption is still below the bottom edge.
  bool _upcomingBelow = false;

  /// True while the last caption is still below the bottom edge.
  ///
  /// The last group ends the content, so what remains to scroll is the
  /// distance from the bottom edge to the end of that group. Its caption is
  /// exactly [_StickyGroups.upcomingExtent] above that end — so the caption is
  /// still off the bottom while the remaining scroll exceeds the group's own
  /// height, and reaches the edge precisely when it does not.
  bool _below(ScrollMetrics m) =>
      m.hasContentDimensions &&
      (m.maxScrollExtent - m.pixels) > widget.upcomingExtent;

  bool _update(ScrollMetrics metrics) {
    final below = _below(metrics);
    if (below != _upcomingBelow) setState(() => _upcomingBelow = below);
    return false;
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _update(n.metrics),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => _update(n.metrics),
          child: CustomScrollView(shrinkWrap: true, slivers: widget.slivers),
        ),
      ),
      // Ignores pointers: it is a label, and the list under it must stay
      // draggable through the strip it occupies.
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
          child: AnimatedOpacity(
            key: const Key('track_routing_upcoming_group'),
            duration: kConsoleMotion,
            curve: Curves.easeOut,
            opacity: _upcomingBelow ? 1 : 0,
            child: Container(
              color: context.surface.card,
              padding: const EdgeInsets.only(top: kConsoleLabelGap),
              child: ConsoleGroupLabel(widget.upcoming),
            ),
          ),
        ),
      ),
    ],
  );
}
