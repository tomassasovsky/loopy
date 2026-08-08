import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/signal/signal_card.dart';

/// One Signal tab: the scope chip, then the chains at that stage as a row of
/// cards, then whatever else that stage owns.
///
/// **Every card on every tab is one chain**, which is what makes four faces
/// one widget. The stage decides what a card *is* — a socket's monitor chain,
/// a take's playback chain, a track bus, the master insert — and the questions
/// the card answers are the same six either way.
///
/// **Racks are #535, so every card here is rackless.** That is the mockups'
/// own empty state (`no rack` / `tap to load one`), and it has one consequence
/// worth stating plainly: a card carries its monitor line only when a rack is
/// loaded, so on the loop, track and master tabs no card shows one. The input
/// tab is the decided exception — an input's monitor gate is a fact about the
/// jack rather than about the chain on it, so those cards always show it, and
/// they are what the tri-state actually surfaces until racks land.
class SignalStageBody extends StatelessWidget {
  /// Creates a [SignalStageBody] for [stage].
  const SignalStageBody({required this.stage, super.key});

  /// Which FX stage this tab shows.
  final FxStage stage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: kConsoleBlockGap),
          Align(
            alignment: Alignment.centerLeft,
            child: SignalScopeChip(
              key: Key('signal_scope_${stage.name}'),
              label: stage == FxStage.input
                  ? l10n.signalScopePrinted
                  : l10n.signalScopeMonitorOnly,
              printed: stage == FxStage.input,
            ),
          ),
          const SizedBox(height: kConsoleBlockGap),
          switch (stage) {
            FxStage.input => const _InputCards(),
            FxStage.loop => const _LoopCards(),
            FxStage.track => const _TrackCards(),
            FxStage.master => const _MasterStage(),
          },
        ],
      ),
    );
  }
}

/// The three list tabs' shared shape: cards left-aligned in a wrapping run, or
/// the empty card in their place.
///
/// A [Wrap] rather than a [Row]: the cards are a fixed 202 wide and the rig
/// decides how many there are, so an eight-input interface has to fold onto a
/// second line instead of overflowing the pane. The mockups only ever draw one
/// line because they draw a three-track rig.
class _CardRun extends StatelessWidget {
  const _CardRun({required this.cards, required this.emptyMessage});

  final List<Widget> cards;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return ConsoleEmptyCard(
        key: const Key('signal_empty_card'),
        message: emptyMessage,
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: SignalCard.gap,
        runSpacing: SignalCard.gap,
        children: cards,
      ),
    );
  }
}

/// The `input` tab: one card per hardware socket that can be monitored.
///
/// **Loopback sockets are left out.** The engine marks them excluded because
/// they can never be monitored or captured, so a card for one would carry two
/// facts that are false by construction — a monitor line about a gate that
/// cannot open, and a chain that can never print into anything.
class _InputCards extends StatelessWidget {
  const _InputCards();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<InputsCubit>().state.names;
    final monitors = context.watch<MonitorCubit>().state;
    // The two facts the socket list is made of, and nothing else off
    // [EngineStatus] — `xrunCount` lives on the same object and moves on its
    // own, so selecting the whole status would rebuild this run on a glitch.
    final (count, excluded) = context.select<LooperBloc, (int, int)>(
      (bloc) => (
        bloc.state.status.inputChannels,
        bloc.state.status.excludedInputMask,
      ),
    );

    final cards = <Widget>[
      for (var input = 0; input < count; input++)
        if (excluded & (1 << input) == 0)
          SignalCard(
            key: Key('signal_card_input_$input'),
            name: l10n.inputName(names, input),
            coordinate: l10n.signalCoordInput(input + 1),
            routesTo: l10n.signalRouteRecorder,
            rack: l10n.signalNoRack,
            summary: l10n.signalTapToLoadRack,
            monitor: monitorLine(l10n, monitors.forInput(input)),
          ),
    ];

    return _CardRun(
      cards: cards,
      // An empty run has two causes and they are different facts: no sockets
      // at all is a stopped engine, while sockets that are every one of them
      // loopback is a RUNNING engine on a device with nothing capturable —
      // and telling that player to start the engine sends them after a
      // problem they do not have.
      emptyMessage: count == 0
          ? l10n.signalNoInputs
          : l10n.signalOnlyLoopbackInputs,
    );
  }
}

/// The `loop` tab: one card per recorded lane, since a lane is what owns a
/// loop-stage chain.
///
/// Flattened track-major, so the cards read in the order the rig does. A track
/// with no lanes contributes nothing rather than an empty placeholder — it has
/// no chain at this stage to draw.
class _LoopCards extends StatelessWidget {
  const _LoopCards();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;

    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) =>
          !sameChainShape(previous.tracks, current.tracks),
      builder: (context, state) => _CardRun(
        cards: [
          for (final track in state.tracks)
            for (final (lane, _) in track.lanes.indexed)
              SignalCard(
                key: Key('signal_card_loop_${track.channel}_$lane'),
                name: l10n.trackName(names, track.channel),
                coordinate: l10n.signalCoordTrackLane(
                  track.channel + 1,
                  laneLetter(lane),
                ),
                routesTo: l10n.signalRouteMix,
                rack: l10n.signalNoRack,
                summary: l10n.signalTapToLoadRack,
              ),
        ],
        emptyMessage: l10n.signalNoLanes,
      ),
    );
  }
}

/// The `track` tab: one card per track bus.
///
/// The fourth tab the strip has always promised and no mockup ever drew. It is
/// the loop face changing only what the stage changes — the coordinate loses
/// its lane, because a track bus sits downstream of all of them, and the chain
/// feeds the master sum rather than the track mix.
class _TrackCards extends StatelessWidget {
  const _TrackCards();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;

    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) =>
          !sameChainShape(previous.tracks, current.tracks),
      builder: (context, state) => _CardRun(
        cards: [
          for (final track in state.tracks)
            SignalCard(
              key: Key('signal_card_track_${track.channel}'),
              name: l10n.trackName(names, track.channel),
              coordinate: l10n.signalCoordTrack(track.channel + 1),
              routesTo: l10n.signalRouteMaster,
              rack: l10n.signalNoRack,
              summary: l10n.signalTapToLoadRack,
            ),
        ],
        emptyMessage: l10n.signalNoTracks,
      ),
    );
  }
}

/// The `master` tab: the one Master-insert card, then the hardware outputs it
/// is summed into.
///
/// The outputs group is on this tab and not on Audio because the question it
/// answers is *where does the master sum go*, which is this stage's own. The
/// switch is the rig's structural output gate — a cleared bit drops that
/// output from the mix while every stored route mask survives, so turning one
/// off and back on restores what was routed there.
class _MasterStage extends StatelessWidget {
  const _MasterStage();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The gate mask and the channel count, not the whole state: this group is
    // four switches, and the roster behind it moves at the meter rate.
    //
    // The mask's 32 bits cover every output there can be: the engine clamps
    // both channel counts to `LE_MAX_CHANNELS` (32) at device open, so a
    // 64-output interface reports 32 here and `1 << output` never runs off
    // the end of the default `0xFFFFFFFF`.
    final (outputs, mask) = context.select<LooperBloc, (int, int)>(
      (bloc) => (
        bloc.state.status.outputChannels,
        bloc.state.outputEnabledMask,
      ),
    );
    final live = [
      for (var output = 0; output < outputs; output++)
        mask & (1 << output) != 0,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SignalCard(
          key: const Key('signal_card_master'),
          name: l10n.signalMasterCardName,
          coordinate: l10n.signalCoordMain,
          routesTo: l10n.signalRouteOutputs,
          rack: l10n.signalNoRack,
          summary: l10n.signalTapToLoadRack,
          width: null,
        ),
        const SizedBox(height: kConsoleGroupGap),
        ConsoleGroupLabel(l10n.signalOutputsGroup),
        const SizedBox(height: kConsoleLabelGap),
        if (outputs == 0)
          ConsoleEmptyCard(
            key: const Key('signal_outputs_empty_card'),
            message: l10n.signalNoOutputs,
          )
        else ...[
          ConsoleCard(
            key: const Key('signal_outputs_card'),
            children: [
              for (final (output, enabled) in live.indexed)
                _OutputRow(
                  key: Key('signal_output_row_$output'),
                  output: output,
                  enabled: enabled,
                  showDivider: output < outputs - 1,
                ),
            ],
          ),
          // The warning the full-screen surface carried, kept: every output
          // off is a rig that records and is never heard, and nothing else on
          // this face says so. Said once, over the group, rather than on each
          // row — it is a fact about the set.
          if (!live.contains(true)) ...[
            const SizedBox(height: kConsoleBlockGap),
            ConsoleBanner(
              key: const Key('signal_no_outputs_banner'),
              tone: ConsoleBannerTone.failure,
              message: l10n.noActiveOutputsNotice,
            ),
          ],
        ],
      ],
    );
  }
}

/// One hardware output: what it is called, and its gate.
///
/// **No sublabel.** An earlier draft named the first two pairs `main` and
/// `phones`, as the mockups draw a four-output rig — but the app has no source
/// for that: the engine reports a channel count and no labels, so on the
/// 20-output interface the previews themselves model those would be sockets
/// wired to something else entirely. The surface this replaces showed the
/// ordinal alone, and a wrong name is worse than no name when the row's own
/// switch silences what it names.
class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.output,
    required this.enabled,
    required this.showDivider,
    super.key,
  });

  final int output;
  final bool enabled;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ConsoleRow(
      title: l10n.outputChannelLabel(output + 1),
      showDivider: showDivider,
      // No row here opens, so the disclosure gutter would be an empty column
      // holding every switch 11px off the card's edge.
      showDisclosure: false,
      trailing: ConsoleSwitch(
        key: Key('signal_output_switch_$output'),
        value: enabled,
        semanticLabel: enabled
            ? l10n.a11yOutputEnabledDisable(output + 1)
            : l10n.a11yOutputDisabledEnable(output + 1),
        onChanged: (value) => context.read<LooperBloc>().add(
          LooperOutputEnabledToggled(output, enabled: value),
        ),
      ),
    );
  }
}

/// Whether [a] and [b] hold the same set of loop- and track-stage chains —
/// same tracks, same lane count on each.
///
/// The loop and track faces cannot `context.select` the roster: a [Track]
/// carries live meters, so `state.tracks` changes at the meter rate, and a
/// `List` compares by identity anyway, so a projected list would never test
/// equal either. Both faces drive a `buildWhen` off this instead — and what
/// they draw is only the SHAPE, since a card's name comes from `TracksCubit`
/// and everything else on it is a constant until racks land.
bool sameChainShape(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].channel != b[i].channel) return false;
    if (a[i].lanes.length != b[i].lanes.length) return false;
  }
  return true;
}

/// `A`, `B`, `C`… for lane [index] — the Signal domain's own form.
///
/// A letter rather than the `Lane 1` the pedal targets use, because on a card
/// the lane sits inside a coordinate that already carries a number (`track 3 ·
/// lane A`) and two ordinals side by side read as a pair. Past `Z` it falls
/// back to the ordinal, which no rig will reach and which is still a coordinate
/// rather than a crash.
String laneLetter(int index) => index >= 0 && index < 26
    ? String.fromCharCode(0x41 + index)
    : '${index + 1}';

/// The monitor row for [monitor].
///
/// The label is the gate's own word, but **audible is not**: a monitor that is
/// muted, faded to nothing, or routed to no output at all is silent whatever
/// its mode reads, and the accent this drives means "you will hear this". All
/// three are reachable today from the surface PR 6 deletes, so a line that took
/// the mode at its word would contradict what the player hears.
SignalMonitorLine monitorLine(AppLocalizations l10n, InputMonitor monitor) {
  final reaches =
      !monitor.muted && monitor.outputMask != 0 && monitor.volume > 0;
  return switch (monitor.mode) {
    MonitorMode.off => SignalMonitorLine(
      label: l10n.signalMonitorOff,
      audible: false,
    ),
    MonitorMode.auto => SignalMonitorLine(
      label: l10n.signalMonitorAuto,
      audible: reaches,
    ),
    MonitorMode.on => SignalMonitorLine(
      label: l10n.signalMonitorOn,
      audible: reaches,
    ),
  };
}
