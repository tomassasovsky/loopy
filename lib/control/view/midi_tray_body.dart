import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// The MIDI tab of the Control domain: the foot controller, and every global
/// mapping taken off it.
///
/// Two stacked things, because they answer two questions — *is anything
/// delivering MIDI at all*, and *what are its controls wired to*. The device
/// and its status come first; the fixed transport CCs are stated between them
/// and the editable mappings, because that protocol is the reason a generic
/// controller works at all without anybody mapping anything.
///
/// The mappings are GLOBAL (R19) — they follow the rig, not the loaded session
/// — and the face says so in words before anyone invests in a layout.
class MidiTrayBody extends StatefulWidget {
  /// Creates a [MidiTrayBody].
  const MidiTrayBody({super.key});

  @override
  State<MidiTrayBody> createState() => _MidiTrayBodyState();
}

/// What the face currently has open. At most one thing — an accordion across
/// the WHOLE face, not one per card: the device chooser, an add-target
/// chooser and a mapping's calibration are all drawers, and two open at once
/// would push the second past the sheet it has to fit in.
sealed class _Open {
  const _Open();
}

/// The device row's chooser.
class _DeviceOpen extends _Open {
  const _DeviceOpen();
}

/// An Add sweep / Add switch target chooser.
class _AddOpen extends _Open {
  const _AddOpen({required this.continuous});

  /// Whether the mapping being added is a sweep rather than a switch.
  final bool continuous;
}

/// One mapping's calibration.
class _MappingOpen extends _Open {
  const _MappingOpen(this.key);

  final (MappingTrigger, String) key;
}

class _MidiTrayBodyState extends State<MidiTrayBody> {
  /// What is open, or null. See [_Open].
  _Open? _open;

  /// Whether a message has arrived recently enough to call the link busy.
  bool _receiving = false;

  Timer? _quiet;

  /// How long after the last message the link stops reading as busy. Long
  /// enough that a slow expression sweep does not flicker the line, short
  /// enough that a stopped controller stops claiming to be delivering.
  static const Duration _quietAfter = Duration(milliseconds: 1500);

  /// Group rhythm, as the mockups set it: a caption belongs to what is under
  /// it, so the gap below one is smaller than the gap above.
  static const double _groupGap = 19;
  static const double _labelGap = 9;
  static const double _blockGap = 14;

  @override
  void dispose() {
    _quiet?.cancel();
    super.dispose();
  }

  void _sawTraffic() {
    _quiet?.cancel();
    if (!_receiving) setState(() => _receiving = true);
    _quiet = Timer(_quietAfter, () {
      if (mounted) setState(() => _receiving = false);
    });
  }

  /// The key [_open] holds, when what is open is a mapping.
  (MappingTrigger, String)? get _openKey => switch (_open) {
    _MappingOpen(:final key) => key,
    _ => null,
  };

  /// The row a relearn is re-teaching while its calibration is open, and the
  /// mappings that existed when that capture started — see [_followRelearn].
  ({(MappingTrigger, String) key, Set<(MappingTrigger, String)> before})?
  _relearning;

  /// Keeps the opened calibration open across a relearn.
  ///
  /// A mapping's identity IS its control, so re-teaching it a different one
  /// gives it a new key — and [_open], which holds the old one, would then
  /// match nothing and shut the drawer the user is working in at the exact
  /// moment their relearn succeeded.
  ///
  /// Two deliveries, not one: the cubit clears the capture BEFORE it emits the
  /// set that capture edited, so on the first the row is always still here and
  /// this stays armed for the next. What it then follows is the mapping on the
  /// same target that was NOT in the set before — the one signature a rebind
  /// has and a removal never does, which is what keeps a cancelled capture
  /// followed by a Remove from hopping the drawer onto a row that merely
  /// shares the target.
  void _followRelearn(ControlState state) {
    final bindings = state.controllerBindings.bindings;
    final learn = state.controllerLearn;
    if (learn != null) {
      final open = _openKey;
      _relearning = open != null && learn.replacingKey == open
          ? (key: open, before: {for (final b in bindings) b.key})
          : null;
      return;
    }
    final armed = _relearning;
    if (armed == null) return;
    if (bindings.any((binding) => binding.key == armed.key)) return;
    _relearning = null;
    if (_openKey != armed.key) return;
    final moved = bindings
        .where(
          (b) => b.target == armed.key.$2 && !armed.before.contains(b.key),
        )
        .firstOrNull;
    if (moved == null) return;
    setState(() => _open = _MappingOpen(moved.key));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The CONNECTION only. Watching the whole state would rebuild this face on
    // every raw MIDI message, since `activityTick` bumps on each one — the
    // per-message work the listener below exists to avoid, taken anyway.
    final connection = context.select<MidiSetupCubit, MidiConnection>(
      (cubit) => cubit.state.connection,
    );

    return MultiBlocListener(
      listeners: [
        BlocListener<MidiSetupCubit, MidiSetupState>(
          // The tick's value is meaningless; only its changes are. Watching it
          // in `build` and setting state there would be a write during a
          // build, so the blink is driven from a listener instead.
          listenWhen: (a, b) => a.activityTick != b.activityTick,
          listener: (_, _) => _sawTraffic(),
        ),
        BlocListener<ControlCubit, ControlState>(
          // The mappings too, not just the capture: a relearn lands as two
          // emits — the capture clearing, then the set it edited — and the
          // one that moves the row is the second.
          listenWhen: (a, b) =>
              a.controllerLearn != b.controllerLearn ||
              a.controllerBindings != b.controllerBindings,
          listener: (_, state) => _followRelearn(state),
        ),
      ],
      child: KeyedSubtree(
        key: const Key('midi_tray_body'),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: _groupGap),
              ConsoleGroupLabel(l10n.midiDeviceGroup),
              const SizedBox(height: _labelGap),
              _deviceCard(context, connection),
              const SizedBox(height: _blockGap),
              _statusCard(context, connection),
              const SizedBox(height: _blockGap),
              ConsoleProse(l10n.midiTransportMap(_transportMap(l10n))),
              const SizedBox(height: _groupGap),
              ConsoleGroupLabel(l10n.midiLearnGroup),
              const SizedBox(height: _labelGap),
              ConsoleProse(l10n.midiLearnHint),
              const SizedBox(height: _blockGap),
              _mappingsCard(context, connection),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- device

  /// The device row, and the chooser it opens onto.
  ///
  /// **Opens in place**, like every other row on this console — the mockups'
  /// `AUDIO / settings-device` draws exactly this shape for the same question,
  /// and a modal would lose the status card underneath that says whether the
  /// choice worked.
  Widget _deviceCard(BuildContext context, MidiConnection connection) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<MidiSetupCubit>();
    final open = _open is _DeviceOpen;

    // The pinned device is listed even when the enumeration has lost it: the
    // selection is what survives the cable being found again, so hiding it
    // would make an unplugged controller look like one nobody ever chose.
    final absent =
        connection.hasSelection &&
        !connection.devices.any((d) => d.id == connection.selectedId);
    final choices = <({String id, String name, bool dimmed})>[
      (id: '', name: l10n.midiDeviceNone, dimmed: false),
      for (final device in connection.devices)
        (id: device.id, name: device.name, dimmed: false),
      if (absent)
        (
          id: connection.selectedId,
          name: connection.selectedName,
          dimmed: true,
        ),
    ];

    return ConsoleCard(
      children: [
        ConsoleRow(
          key: const Key('midi_device_row'),
          title: l10n.midiDeviceRow,
          state: connection.hasSelection
              ? connection.selectedName
              : l10n.midiDeviceNone,
          expanded: open,
          showDivider: false,
          fill: open ? surface.control : null,
          onTap: () =>
              setState(() => _open = open ? null : const _DeviceOpen()),
        ),
        ConsoleExpansion(
          key: const Key('midi_device_slot'),
          expanded: open,
          child: open
              ? ConsoleDrawer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, choice) in choices.indexed)
                        ConsolePickRow(
                          key: Key('midi_device_choice_${choice.id}'),
                          title: choice.name,
                          state: choice.dimmed
                              ? l10n.midiDeviceUnplugged
                              : null,
                          dimmed: choice.dimmed,
                          selected: choice.id == connection.selectedId,
                          showDivider: index < choices.length - 1,
                          onTap: () {
                            setState(() => _open = null);
                            unawaited(cubit.select(choice.id));
                          },
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- status

  /// The link's own report: what it is connected to, and whether anything is
  /// arriving over it.
  ///
  /// Four faults, not one. The repository already tells `none`, `deviceGone`,
  /// `error` and `connecting` apart, and collapsing them into "no MIDI device"
  /// sends the operator looking in the wrong place — for a cable when the
  /// device is open but held by another app, or for another app when nothing
  /// is selected at all.
  Widget _statusCard(BuildContext context, MidiConnection connection) {
    final l10n = context.l10n;
    final surface = context.surface;
    final name = connection.selectedName;
    final live = connection.status == MidiConnectionStatus.connected;

    final (
      String message,
      ConsoleBannerTone tone,
    ) = switch (connection.status) {
      MidiConnectionStatus.connected => (
        l10n.midiStatusConnected(name),
        ConsoleBannerTone.steady,
      ),
      MidiConnectionStatus.connecting => (
        l10n.midiStatusConnecting,
        ConsoleBannerTone.pending,
      ),
      MidiConnectionStatus.deviceGone => (
        l10n.midiStatusDeviceGone(name),
        ConsoleBannerTone.failure,
      ),
      MidiConnectionStatus.error => (
        l10n.midiStatusOpenFailed(name),
        ConsoleBannerTone.failure,
      ),
      MidiConnectionStatus.none => (
        l10n.midiStatusNone,
        ConsoleBannerTone.failure,
      ),
    };

    return ConsoleCard(
      children: [
        ConsoleBanner(
          key: const Key('midi_status'),
          message: message,
          tone: tone,
        ),
        // Traffic is only reported on a link that exists. A "waiting for MIDI
        // input" line under "no MIDI device" describes a wait that is not
        // happening.
        ConsoleExpansion(
          key: const Key('midi_traffic_slot'),
          expanded: live,
          child: live
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: surface.line)),
                  ),
                  child: ConsoleBanner(
                    key: const Key('midi_traffic'),
                    message: _receiving
                        ? l10n.midiStatusReceiving
                        : l10n.midiStatusWaiting,
                    tone: _receiving
                        ? ConsoleBannerTone.steady
                        : ConsoleBannerTone.failure,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// The fixed transport map, read off the rig's own default mapping rather
  /// than written out here.
  ///
  /// The mockups list the first four. Stating four of seven would make this
  /// line a half-truth the moment somebody wired CC 84 to a tap-tempo switch
  /// and it worked, so it is built from the source the firmware and any
  /// generic controller both speak.
  String _transportMap(AppLocalizations l10n) {
    String word(LooperAction action) => switch (action) {
      LooperAction.recordOverdub => l10n.midiActionRecord,
      LooperAction.stop => l10n.midiActionStop,
      LooperAction.play => l10n.midiActionPlay,
      LooperAction.clear => l10n.midiActionClear,
      LooperAction.undo => l10n.midiActionUndo,
      LooperAction.playAll => l10n.midiActionPlayAll,
      LooperAction.stopAll => l10n.midiActionStopAll,
      LooperAction.tapTempo => l10n.midiActionTapTempo,
      LooperAction.toggleMetronome => l10n.midiActionMetronome,
      LooperAction.cancelArm => l10n.midiActionCancelArm,
    };
    return ControllerMapping.defaults().entries
        .where((e) => e.trigger.kind == ControllerSourceKind.midiCc)
        .map((e) => '${e.trigger.id} ${word(e.action)}')
        .join(' · ');
  }

  // -------------------------------------------------------------- mappings

  Widget _mappingsCard(BuildContext context, MidiConnection connection) {
    final l10n = context.l10n;
    final cubit = context.watch<ControlCubit>();
    final bindings = cubit.state.controllerBindings.bindings;
    final learn = cubit.state.controllerLearn;
    final connected = connection.status == MidiConnectionStatus.connected;
    // A capture with no row of its own — Add sweep / Add switch — has nowhere
    // to put its banner but the head of the list it is about to join.
    final adding = learn != null && learn.replacingKey == null;

    final notice = switch ((adding, connected, bindings.isEmpty)) {
      (true, _, _) => _learnBanner(context, learn!, key: 'midi_add_banner'),
      (_, false, _) => ConsoleBanner(
        key: const Key('midi_idle_notice'),
        message: l10n.midiLearnDeviceMissing,
        tone: ConsoleBannerTone.failure,
      ),
      (_, _, true) => ConsoleBanner(
        key: const Key('midi_empty_notice'),
        message: l10n.midiMappingsEmpty,
        tone: ConsoleBannerTone.steady,
      ),
      _ => null,
    };

    return ConsoleCard(
      children: [
        ConsoleExpansion(
          key: const Key('midi_notice_slot'),
          expanded: notice != null,
          child: notice ?? const SizedBox(width: double.infinity),
        ),
        for (final binding in bindings)
          _MappingRow(
            // The WHOLE identity, not just the control number: a trigger is
            // (kind, number, channel), and the set allows two controls to
            // drive one target — so CC 20 on two channels, or note 20 and
            // CC 20, are two legal rows whose keys would otherwise collide.
            key: Key('midi_mapping_${binding.trigger}_${binding.target}'),
            binding: binding,
            open: switch (_open) {
              _MappingOpen(:final key) => key == binding.key,
              _ => false,
            },
            learn: learn?.replacingKey == binding.key ? learn : null,
            connected: connected,
            onToggle: () => setState(() {
              final already = switch (_open) {
                _MappingOpen(:final key) => key == binding.key,
                _ => false,
              };
              _open = already ? null : _MappingOpen(binding.key);
            }),
          ),
        _addRow(context, cubit, connected: connected),
        _addChooser(context, cubit, connected: connected),
      ],
    );
  }

  Widget _addRow(
    BuildContext context,
    ControlCubit cubit, {
    required bool connected,
  }) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(
        kConsoleRowInset,
      ).copyWith(top: _blockGap, bottom: _blockGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _addChip(
            id: 'midi_add_sweep',
            label: l10n.midiLearnAddSweep,
            continuous: true,
            connected: connected,
          ),
          const SizedBox(width: 10),
          _addChip(
            id: 'midi_add_switch',
            label: l10n.midiLearnAddSwitch,
            continuous: false,
            connected: connected,
          ),
        ],
      ),
    );
  }

  Widget _addChip({
    required String id,
    required String label,
    required bool continuous,
    required bool connected,
  }) => ConsoleActionChip(
    key: Key(id),
    label: label,
    // Inert with nothing attached. A capture needs a control to move, and
    // offering to listen when nothing can arrive is a button that does
    // nothing on purpose.
    onPressed: !connected
        ? null
        : () => setState(
            () => _open = _openIsAdd(continuous)
                ? null
                : _AddOpen(continuous: continuous),
          ),
  );

  bool _openIsAdd(bool continuous) => switch (_open) {
    _AddOpen(continuous: final c) => c == continuous,
    _ => false,
  };

  /// The target chooser an Add button opens onto.
  ///
  /// The same drawer the device row uses, for the same reason: a button that
  /// raised a modal would be the only control on this console that leaves the
  /// list it belongs to.
  ///
  /// Shuts with the link, on the Add buttons' own rule: a capture needs a
  /// control to move, so a chooser left open when the device went away would
  /// reach the doomed capture the inert buttons exist to prevent, one tap
  /// later. The choice is kept, so it comes back when the device does.
  Widget _addChooser(
    BuildContext context,
    ControlCubit cubit, {
    required bool connected,
  }) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final adding = !connected
        ? null
        : switch (_open) {
            _AddOpen(:final continuous) => continuous,
            _ => null,
          };

    final choices = <({String target, String title, String? state})>[
      if (adding == true)
        for (final target in looper.availableValueTargets())
          (
            target: target.canonicalString(),
            title: valueTargetLabel(l10n, looper, target),
            state: null,
          )
      else if (adding == false)
        for (final target in looper.availableBindingTargets())
          (
            target: target.canonicalString(),
            title: bindingTargetLabel(l10n, target),
            state: fxStageLabel(l10n, target.address),
          ),
    ];

    return ConsoleExpansion(
      key: const Key('midi_add_slot'),
      expanded: adding != null,
      child: adding == null
          ? const SizedBox(width: double.infinity)
          : ConsoleDrawer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, choice) in choices.indexed)
                    ConsolePickRow(
                      key: Key('midi_add_target_${choice.target}'),
                      title: choice.title,
                      state: choice.state,
                      // Nothing is chosen yet: this mapping does not exist
                      // until a control has been moved for it.
                      selected: false,
                      showDivider: index < choices.length - 1,
                      onTap: () {
                        setState(() => _open = null);
                        cubit.learnControllerBinding(
                          target: choice.target,
                          continuous: adding,
                        );
                      },
                    ),
                ],
              ),
            ),
    );
  }

  Widget _learnBanner(
    BuildContext context,
    ControllerLearn learn, {
    required String key,
  }) {
    final l10n = context.l10n;
    final cubit = context.read<ControlCubit>();
    final captured = learn.captured;
    return ConsoleBanner(
      key: Key(key),
      message: captured == null
          ? l10n.midiLearnListening
          : l10n.midiLearnReplacePrompt(controlLabel(l10n, captured)),
      tone: ConsoleBannerTone.pending,
      actions: [
        ConsoleSmallButton(
          key: Key('${key}_cancel'),
          label: captured == null ? l10n.midiLearnCancel : l10n.midiLearnKeep,
          onPressed: cubit.cancelControllerLearn,
        ),
        if (captured != null)
          ConsoleSmallButton(
            key: Key('${key}_replace'),
            label: l10n.midiLearnReplace,
            onPressed: () => unawaited(cubit.confirmControllerLearn()),
          ),
      ],
    );
  }
}

/// One mapping, and — when it is open — its own calibration.
class _MappingRow extends StatelessWidget {
  const _MappingRow({
    required this.binding,
    required this.open,
    required this.learn,
    required this.connected,
    required this.onToggle,
    super.key,
  });

  final ControllerBinding binding;
  final bool open;

  /// The capture running FOR THIS ROW (a relearn), or null.
  final ControllerLearn? learn;

  /// Whether a MIDI link is up. A mapping is GLOBAL — the row is drawn from
  /// the settings blob whether or not anything is plugged in — so the row has
  /// to be told, and Relearn obeys the same rule the Add buttons do: a capture
  /// needs a control to move.
  final bool connected;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final looper = context.read<LooperRepository>();
    final resolved = _resolve(l10n, looper, binding);

    final row = ConsoleRow(
      key: const Key('midi_mapping_row'),
      // The target's own name, whether or not it still resolves: a row that
      // renamed itself "Missing target" would lose the only clue about what
      // the control used to do.
      title: resolved?.label ?? l10n.midiLearnStale,
      subtitle: resolved != null && resolved.resolves
          ? controlLabel(l10n, binding.trigger)
          : l10n.midiLearnStale,
      state: switch (binding) {
        ContinuousBinding() => l10n.midiStateSweep,
        DiscreteBinding() => l10n.midiStateSwitch,
      },
      expanded: open,
      // The open row's own tint is the CONTROL grey, not the accent the pedal
      // face's selected switch takes: this row is one you opened, and that is
      // a different fact from "this is the thing being assigned".
      fill: open ? surface.control : null,
      onTap: onToggle,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        ConsoleExpansion(
          expanded: open,
          child: open
              ? _editor(context, resolved: resolved)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _editor(
    BuildContext context, {
    required ({String label, bool resolves})? resolved,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<ControlCubit>();
    final capture = learn;
    final stale = resolved == null || !resolved.resolves;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.background,
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 3),
          if (capture != null)
            ConsoleBanner(
              key: const Key('midi_relearn_banner'),
              message: capture.captured == null
                  ? l10n.midiLearnListening
                  : l10n.midiLearnReplacePrompt(
                      controlLabel(l10n, capture.captured!),
                    ),
              tone: ConsoleBannerTone.pending,
              actions: [
                ConsoleSmallButton(
                  key: const Key('midi_relearn_cancel'),
                  label: capture.captured == null
                      ? l10n.midiLearnCancel
                      : l10n.midiLearnKeep,
                  onPressed: cubit.cancelControllerLearn,
                ),
                if (capture.captured != null)
                  ConsoleSmallButton(
                    key: const Key('midi_relearn_replace'),
                    label: l10n.midiLearnReplace,
                    onPressed: () => unawaited(cubit.confirmControllerLearn()),
                  ),
              ],
            )
          else if (stale)
            ConsoleBanner(
              key: const Key('midi_stale_banner'),
              message: l10n.midiLearnStaleDetail,
              tone: ConsoleBannerTone.failure,
            ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: switch (binding) {
                final ContinuousBinding sweep => [
                  ConsoleValueBar(
                    key: const Key('midi_lo'),
                    label: l10n.midiLearnLo,
                    value: sweep.lo,
                    readout: '${(sweep.lo * 127).round()}',
                    semanticLabel: l10n.a11yMidiLearnLo,
                    onChanged: (value) => unawaited(
                      cubit.updateControllerBinding(
                        sweep,
                        sweep.copyWith(lo: value),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ConsoleValueBar(
                    key: const Key('midi_hi'),
                    label: l10n.midiLearnHi,
                    value: sweep.hi,
                    readout: '${(sweep.hi * 127).round()}',
                    semanticLabel: l10n.a11yMidiLearnHi,
                    onChanged: (value) => unawaited(
                      cubit.updateControllerBinding(
                        sweep,
                        sweep.copyWith(hi: value),
                      ),
                    ),
                  ),
                ],
                final DiscreteBinding stomp => [
                  ConsoleValueBar(
                    key: const Key('midi_threshold'),
                    label: l10n.midiLearnThreshold,
                    value: stomp.threshold / 127,
                    readout: '${stomp.threshold}',
                    semanticLabel: l10n.a11yMidiLearnThreshold,
                    onChanged: (value) => unawaited(
                      cubit.updateControllerBinding(
                        stomp,
                        stomp.copyWith(
                          threshold: (value * 127).round().clamp(
                            DiscreteBinding.minThreshold,
                            127,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: ConsoleValueBar.labelWidth,
                        child: Text(
                          l10n.midiLearnBehavior.toUpperCase(),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: surface.textMuted,
                            fontSize: 13,
                            height: 1.23,
                            letterSpacing: 0.78,
                            leadingDistribution: TextLeadingDistribution.even,
                          ),
                        ),
                      ),
                      const SizedBox(width: kConsoleRowGap),
                      ConsoleSegmented<BindingBehavior>(
                        key: const Key('midi_behavior'),
                        selected: stomp.behavior,
                        segments: [
                          ConsoleSegment(
                            value: BindingBehavior.toggle,
                            label: l10n.pedalAssignToggle,
                          ),
                          ConsoleSegment(
                            value: BindingBehavior.momentary,
                            label: l10n.pedalAssignMomentary,
                          ),
                        ],
                        onChanged: (next) => unawaited(
                          cubit.updateControllerBinding(
                            stomp,
                            stomp.copyWith(behavior: next),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kConsoleRowInset,
              0,
              kConsoleRowInset,
              14,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ConsoleActionChip(
                  key: const Key('midi_relearn'),
                  label: l10n.midiLearnRelearn,
                  // Inert with nothing attached, exactly as Add sweep / Add
                  // switch are: re-teaching a control needs one to move, and
                  // offering to listen on a link that is not there is a
                  // 15-second capture nothing can end but the timeout.
                  onPressed: capture != null || !connected
                      ? null
                      : () => cubit.learnControllerBinding(
                          target: binding.target,
                          continuous: binding is ContinuousBinding,
                          replacing: binding,
                        ),
                ),
                const SizedBox(width: 10),
                ConsoleActionChip(
                  key: const Key('midi_remove'),
                  label: l10n.midiLearnClear,
                  destructive: true,
                  onPressed: () =>
                      unawaited(cubit.removeControllerBinding(binding)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What [binding] drives, and whether that still exists in the live rig.
  ///
  /// The two are separate answers: a target that decodes but no longer
  /// resolves still HAS a name, and the row says it.
  ({String label, bool resolves})? _resolve(
    AppLocalizations l10n,
    LooperRepository looper,
    ControllerBinding binding,
  ) {
    switch (binding) {
      case ContinuousBinding():
        final target = ControlValueTarget.tryParse(binding.target);
        if (target == null) return null;
        return (
          label: valueTargetLabel(l10n, looper, target),
          resolves: looper.valueTargetResolves(target),
        );
      case DiscreteBinding():
        final target = FxBindingTarget.tryParse(binding.target);
        if (target == null) return null;
        return (
          label: bindingTargetLabel(l10n, target),
          resolves: looper.bindingResolves(target),
        );
    }
  }
}
