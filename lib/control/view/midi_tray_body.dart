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

class _MidiTrayBodyState extends State<MidiTrayBody> {
  /// Which mapping is open. At most one — an accordion, so the list never
  /// grows past the sheet it has to fit in.
  (MappingTrigger, String)? _openKey;

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connection = context.watch<MidiSetupCubit>().state.connection;

    return BlocListener<MidiSetupCubit, MidiSetupState>(
      // The tick's value is meaningless; only its changes are. Watching it in
      // `build` and setting state there would be a write during a build, so
      // the blink is driven from a listener instead.
      listenWhen: (a, b) => a.activityTick != b.activityTick,
      listener: (_, _) => _sawTraffic(),
      child: KeyedSubtree(
        key: const Key('midi_tray_body'),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: _groupGap),
              ConsoleGroupLabel(l10n.midiDeviceGroup),
              const SizedBox(height: _labelGap),
              ConsoleCard(children: [_deviceRow(context, connection)]),
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

  Widget _deviceRow(BuildContext context, MidiConnection connection) {
    final l10n = context.l10n;
    return ConsoleRow(
      key: const Key('midi_device_row'),
      title: l10n.midiDeviceRow,
      state: connection.hasSelection
          ? connection.selectedName
          : l10n.midiDeviceNone,
      expanded: false,
      showDivider: false,
      onTap: () => unawaited(_pickDevice(context, connection)),
    );
  }

  Future<void> _pickDevice(
    BuildContext context,
    MidiConnection connection,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<MidiSetupCubit>();
    final picked = await showConsolePickerSheet<String>(
      context,
      title: l10n.midiPickDeviceTitle,
      current: connection.selectedId,
      entries: [
        // "None" is a real choice, not the absence of one: an operator who
        // wants the rig off MIDI has to be able to say so, and the repository
        // treats an empty id as exactly that.
        ConsolePickerEntry(value: '', title: l10n.midiDeviceNone),
        for (final device in connection.devices)
          ConsolePickerEntry(value: device.id, title: device.name),
      ],
    );
    if (picked == null) return;
    await cubit.select(picked);
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
            key: Key('midi_mapping_${binding.key.$1.id}_${binding.key.$2}'),
            binding: binding,
            open: _openKey == binding.key,
            learn: learn?.replacingKey == binding.key ? learn : null,
            onToggle: () => setState(
              () => _openKey = _openKey == binding.key ? null : binding.key,
            ),
          ),
        _addRow(context, cubit, connected: connected),
      ],
    );
  }

  Widget _addRow(
    BuildContext context,
    ControlCubit cubit, {
    required bool connected,
  }) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    return Padding(
      padding: const EdgeInsets.all(kConsoleRowInset).copyWith(
        top: _blockGap,
        bottom: _blockGap,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ConsoleActionChip(
            key: const Key('midi_add_sweep'),
            label: l10n.midiLearnAddSweep,
            // Inert with nothing attached. A capture needs a control to move,
            // and offering to listen when nothing can arrive is a button that
            // does nothing on purpose.
            onPressed: !connected
                ? null
                : () => unawaited(
                    _addMapping(
                      context,
                      cubit,
                      title: l10n.midiPickSweepTitle,
                      entries: [
                        for (final target in looper.availableValueTargets())
                          ConsolePickerEntry(
                            value: target.canonicalString(),
                            title: valueTargetLabel(l10n, looper, target),
                          ),
                      ],
                      continuous: true,
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          ConsoleActionChip(
            key: const Key('midi_add_switch'),
            label: l10n.midiLearnAddSwitch,
            onPressed: !connected
                ? null
                : () => unawaited(
                    _addMapping(
                      context,
                      cubit,
                      title: l10n.midiPickSwitchTitle,
                      entries: [
                        for (final target in looper.availableBindingTargets())
                          ConsolePickerEntry(
                            value: target.canonicalString(),
                            title: bindingTargetLabel(l10n, target),
                            state: fxStageLabel(l10n, target.address),
                            indented: target is FxSlotTarget,
                          ),
                      ],
                      continuous: false,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _addMapping(
    BuildContext context,
    ControlCubit cubit, {
    required String title,
    required List<ConsolePickerEntry<String>> entries,
    required bool continuous,
  }) async {
    final target = await showConsolePickerSheet<String>(
      context,
      title: title,
      entries: entries,
    );
    if (target == null) return;
    cubit.learnControllerBinding(target: target, continuous: continuous);
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
    required this.onToggle,
    super.key,
  });

  final ControllerBinding binding;
  final bool open;

  /// The capture running FOR THIS ROW (a relearn), or null.
  final ControllerLearn? learn;

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
                  onPressed: capture != null
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
