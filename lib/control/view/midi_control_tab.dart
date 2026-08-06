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

/// The MIDI tab of the console's Control domain, drawn to
/// `CONTROL / control-midi` and its states.
///
/// Two things stacked, because they answer different questions: which device
/// is delivering MIDI at all (and whether anything is arriving from it), then
/// what its controls are wired to. The mappings are global — they follow the
/// rig, not the loaded session — which the surface says in as many words
/// before anyone invests in a layout.
class MidiControlTab extends StatefulWidget {
  /// Creates a [MidiControlTab].
  const MidiControlTab({super.key});

  @override
  State<MidiControlTab> createState() => _MidiControlTabState();
}

class _MidiControlTabState extends State<MidiControlTab> {
  /// The mapping whose editor is open, keyed the way the binding set keys
  /// itself. View state: which row is expanded is not the rig's business.
  (MappingTrigger, String)? _openKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    final midi = context.watch<MidiSetupCubit>().state;
    final connected = midi.connection.status == MidiConnectionStatus.connected;
    final bindings = control.state.controllerBindings;
    final learn = control.state.controllerLearn;

    return KeyedSubtree(
      key: const Key('midi_control_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.midiControlDeviceGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('midi_device_row'),
                  title: l10n.midiControlDeviceRow,
                  value: _deviceName(l10n, midi),
                  divider: false,
                  onTap: () => unawaited(_pickDevice(context, midi)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleCard(
              children: [
                _StatusRow(
                  key: const Key('midi_status_connection'),
                  ok: connected,
                  // Each fault says what it IS: unplugged and in-use-by-
                  // another-app need different answers from the user, and
                  // "no MIDI device" for all of them sends them looking in
                  // the wrong place.
                  message: _connectionMessage(l10n, midi),
                  divider: connected,
                ),
                if (connected)
                  _StatusRow(
                    key: const Key('midi_status_traffic'),
                    divider: false,
                    // The state carries a monotonic tick rather than a flag:
                    // any tick at all means something has arrived since the
                    // app started, which is the question this line answers.
                    ok: midi.activityTick > 0,
                    message: midi.activityTick > 0
                        ? l10n.midiControlReceiving
                        : l10n.midiControlWaiting,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // The fixed transport CCs the pedal firmware and any generic
            // controller both speak. Not editable — they are the protocol.
            Text(
              l10n.midiControlFixedCcs,
              style: TextStyle(
                color: context.surface.textMuted,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            ConsoleGroupLabel(l10n.midiLearnGroup),
            const SizedBox(height: 10),
            Text(
              l10n.midiLearnHint,
              style: TextStyle(
                color: context.surface.textSecondary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            _MappingList(
              bindings: bindings,
              learn: learn,
              connected: connected,
              idleNotice: connected ? null : l10n.midiControlIdle,
              openKey: _openKey,
              onToggle: (key) => setState(
                () => _openKey = _openKey == key ? null : key,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _deviceName(AppLocalizations l10n, MidiSetupState midi) {
    final name = midi.connection.selectedName;
    return name.isEmpty ? l10n.midiControlNoDevice : name;
  }

  /// What the connection line says, per state. The repository already tells
  /// these four apart; collapsing them into one "not connected" line throws
  /// away the only clue the operator has.
  String _connectionMessage(AppLocalizations l10n, MidiSetupState midi) {
    final name = midi.connection.selectedName;
    return switch (midi.connection.status) {
      MidiConnectionStatus.connected => l10n.midiControlConnected(
        _deviceName(l10n, midi),
      ),
      MidiConnectionStatus.connecting => l10n.midiControlConnecting(name),
      MidiConnectionStatus.deviceGone => l10n.midiControlDeviceGone(name),
      MidiConnectionStatus.error => l10n.midiControlOpenFailed(name),
      MidiConnectionStatus.none => l10n.midiControlNoDeviceDetail,
    };
  }

  Future<void> _pickDevice(BuildContext context, MidiSetupState midi) async {
    final cubit = context.read<MidiSetupCubit>();
    final chosen = await showConsolePickerSheet<String>(
      context,
      title: context.l10n.midiControlDeviceRow,
      options: [
        for (final device in midi.connection.devices)
          ConsolePickerOption(value: device.id, label: device.name),
      ],
      selected: midi.connection.selectedId,
    );
    if (chosen == null) return;
    await cubit.select(chosen);
  }
}

/// One line of the device status card: a state dot and a sentence, with the
/// action that answers it when there is one.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.ok,
    required this.message,
    this.divider = true,
    super.key,
  });

  final bool ok;
  final String message;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ConsoleRow(
      title: message,
      divider: divider,
      showDisclosure: false,
      leading: Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: ok ? surface.success : surface.rec,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Every mapping as a row, the open one showing its calibration and actions.
class _MappingList extends StatelessWidget {
  const _MappingList({
    required this.bindings,
    required this.learn,
    required this.connected,
    required this.idleNotice,
    required this.openKey,
    required this.onToggle,
  });

  final ControllerBindingSet bindings;
  final ControllerLearn? learn;
  final bool connected;

  /// Why the mappings cannot fire, or null while they can. Shown at the head
  /// of the list, where the rows it explains are.
  final String? idleNotice;
  final (MappingTrigger, String)? openKey;
  final ValueChanged<(MappingTrigger, String)> onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final rows = bindings.bindings;
    // A capture for a mapping that does not exist yet: the list is the place
    // it will land, so the prompt lives at its head.
    final adding = learn?.replacingKey == null ? learn : null;

    final idle = idleNotice;
    return ConsoleCard(
      children: [
        if (idle != null && adding == null)
          ConsoleBanner(
            key: const Key('midi_idle_notice'),
            failed: true,
            message: idle,
          ),
        if (adding != null)
          ConsoleBanner(
            actionKey: const Key('midi_learn_cancel'),
            message: adding.captured == null
                ? l10n.midiLearnListening
                : l10n.midiLearnReplacePrompt(
                    controlLabel(l10n, adding.captured!),
                  ),
            actionLabel: adding.captured == null
                ? l10n.midiLearnCancel
                : l10n.midiLearnKeep,
            onAction: cubit.cancelControllerLearn,
            secondaryLabel: adding.captured == null
                ? null
                : l10n.midiLearnReplace,
            onSecondary: adding.captured == null
                ? null
                : () => unawaited(cubit.confirmControllerLearn()),
          ),
        if (rows.isEmpty && adding == null)
          ConsoleRow(
            key: const Key('midi_mapping_empty'),
            title: l10n.midiLearnEmpty,
            centred: true,
            showDisclosure: false,
            divider: false,
          )
        else
          for (final binding in rows)
            ..._mappingRow(
              context: context,
              l10n: l10n,
              cubit: cubit,
              looper: looper,
              binding: binding,
            ),
        _AddRow(connected: connected),
      ],
    );
  }

  List<Widget> _mappingRow({
    required BuildContext context,
    required AppLocalizations l10n,
    required ControlCubit cubit,
    required LooperRepository looper,
    required ControllerBinding binding,
  }) {
    final open = openKey == binding.key;
    final resolved = _resolve(l10n, looper, binding);
    final capture = learn?.replacingKey == binding.key ? learn : null;

    return [
      ConsoleRow(
        key: const Key('midi_mapping_row'),
        title: resolved ?? l10n.midiLearnStale,
        // A mapping whose target is gone says so where the control would be:
        // what it listens to is no longer the interesting fact about it.
        subtitle: resolved == null
            ? l10n.midiControlMissingTarget
            : controlLabel(l10n, binding.trigger),
        value: binding is ContinuousBinding
            ? l10n.midiControlSweep
            : l10n.midiControlSwitch,
        expanded: open,
        onTap: () => onToggle(binding.key),
      ),
      ConsoleExpansion(
        expanded: open,
        child: _MappingEditor(
          binding: binding,
          capture: capture,
          onChanged: (next) =>
              unawaited(cubit.updateControllerBinding(binding, next)),
          onRelearn: () => cubit.learnControllerBinding(
            target: binding.target,
            continuous: binding is ContinuousBinding,
            replacing: binding,
          ),
          onRemove: () => unawaited(cubit.removeControllerBinding(binding)),
        ),
      ),
    ];
  }

  String? _resolve(
    AppLocalizations l10n,
    LooperRepository looper,
    ControllerBinding binding,
  ) {
    switch (binding) {
      case ContinuousBinding():
        final target = ControlValueTarget.tryParse(binding.target);
        if (target == null) return null;
        return valueTargetLabel(l10n, looper, target);
      case DiscreteBinding():
        final target = FxBindingTarget.tryParse(binding.target);
        if (target == null || !looper.bindingResolves(target)) return null;
        return bindingTargetLabel(l10n, target);
    }
  }
}

/// The open mapping's calibration: a sweep's travel, or a switch's threshold
/// and behaviour, over the row's own actions.
class _MappingEditor extends StatelessWidget {
  const _MappingEditor({
    required this.binding,
    required this.capture,
    required this.onChanged,
    required this.onRelearn,
    required this.onRemove,
  });

  final ControllerBinding binding;
  final ControllerLearn? capture;
  final ValueChanged<ControllerBinding> onChanged;
  final VoidCallback onRelearn;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final learning = capture;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.background,
        border: Border(bottom: BorderSide(color: surface.borderHairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (learning != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  learning.captured == null
                      ? l10n.midiLearnListening
                      : l10n.midiLearnReplacePrompt(
                          controlLabel(l10n, learning.captured!),
                        ),
                  key: const Key('midi_mapping_learning'),
                  style: TextStyle(color: surface.warning, fontSize: 15),
                ),
              ),
            switch (binding) {
              final ContinuousBinding sweep => Column(
                children: [
                  ConsoleValueBar(
                    key: const Key('midi_mapping_lo'),
                    label: l10n.midiControlLo,
                    value: sweep.lo,
                    readout: '${(sweep.lo * 100).round()}%',
                    resetValue: 0,
                    onChanged: (value) => onChanged(sweep.copyWith(lo: value)),
                  ),
                  const SizedBox(height: 10),
                  ConsoleValueBar(
                    key: const Key('midi_mapping_hi'),
                    label: l10n.midiControlHi,
                    value: sweep.hi,
                    readout: '${(sweep.hi * 100).round()}%',
                    resetValue: 1,
                    onChanged: (value) => onChanged(sweep.copyWith(hi: value)),
                  ),
                ],
              ),
              final DiscreteBinding sw => Column(
                children: [
                  ConsoleValueBar(
                    key: const Key('midi_mapping_thresh'),
                    label: l10n.midiControlThreshold,
                    value: sw.threshold / 127,
                    readout: '${sw.threshold}',
                    resetValue: 64 / 127,
                    onChanged: (value) => onChanged(
                      sw.copyWith(threshold: (value * 127).round()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text(
                          l10n.midiLearnBehavior,
                          style: TextStyle(
                            color: surface.textMuted,
                            fontSize: 13,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      ConsoleSegmented<BindingBehavior>(
                        key: const Key('midi_mapping_behavior'),
                        selected: sw.behavior,
                        onChanged: (value) =>
                            onChanged(sw.copyWith(behavior: value)),
                        options: [
                          ConsoleSegment(
                            value: BindingBehavior.toggle,
                            label: l10n.pedalAssignToggle,
                          ),
                          ConsoleSegment(
                            value: BindingBehavior.momentary,
                            label: l10n.pedalAssignMomentary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            },
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ConsoleActionChip(
                  key: const Key('midi_mapping_relearn'),
                  label: l10n.midiLearnRelearn,
                  icon: Icons.podcasts,
                  onPressed: onRelearn,
                ),
                const SizedBox(width: 10),
                ConsoleActionChip(
                  key: const Key('midi_mapping_remove'),
                  label: l10n.removeEffectTooltip,
                  icon: Icons.delete_outline,
                  destructive: true,
                  onPressed: onRemove,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's footer: one "add" per trigger shape, each opening a picker of
/// the targets that shape can drive.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ControlCubit>();
    final looper = context.read<LooperRepository>();

    Future<void> add({required bool continuous}) async {
      final options = continuous
          ? [
              for (final target in looper.availableValueTargets())
                ConsolePickerOption(
                  value: target.canonicalString(),
                  label: valueTargetLabel(l10n, looper, target),
                ),
            ]
          : [
              for (final target in looper.availableBindingTargets())
                ConsolePickerOption(
                  value: target.canonicalString(),
                  label: bindingTargetLabel(l10n, target),
                ),
            ];
      final chosen = await showConsolePickerSheet<String>(
        context,
        title: continuous ? l10n.midiLearnAddSweep : l10n.midiLearnAddSwitch,
        options: options,
      );
      if (chosen == null) return;
      cubit.learnControllerBinding(target: chosen, continuous: continuous);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ConsoleSmallButton(
            key: const Key('midi_add_sweep'),
            label: l10n.midiLearnAddSweep,
            large: true,
            // A mapping cannot be learned from a device that is not there:
            // the capture would listen forever.
            onPressed: connected
                ? () => unawaited(add(continuous: true))
                : null,
          ),
          const SizedBox(width: 10),
          ConsoleSmallButton(
            key: const Key('midi_add_switch'),
            label: l10n.midiLearnAddSwitch,
            large: true,
            onPressed: connected
                ? () => unawaited(add(continuous: false))
                : null,
          ),
        ],
      ),
    );
  }
}
