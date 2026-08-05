import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_knob.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/surface_theme.dart';

/// The MIDI-learn block in the audio/I-O settings: every external-MIDI mapping
/// as a row, each with the control it listens to, what it drives, its travel,
/// and a Learn button (R28).
///
/// Driven by [ControlCubit] — the mapping set is stored intent it owns, and the
/// same cubit dispatches what the mappings resolve to, so a row edited here and
/// a control moved on stage can never disagree about what is bound.
///
/// Mappings are GLOBAL (R19): they belong to the rig, not the loaded session,
/// which is what the intro line tells the user before they invest in a layout.
class MidiLearnSection extends StatelessWidget {
  /// Creates a [MidiLearnSection].
  const MidiLearnSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<ControlCubit>();
    final bindings = cubit.state.controllerBindings;
    final learn = cubit.state.controllerLearn;
    // A mapping cannot fire while nothing is delivering MIDI, so every row goes
    // inert rather than pretending to be live (flow err-3). The selection is
    // kept — the device may simply be unplugged — and each row still offers the
    // one-tap relearn that re-points it at whatever IS connected.
    final connected =
        context.watch<MidiSetupCubit>().state.connection.status ==
        MidiConnectionStatus.connected;

    return Column(
      key: const Key('midiLearn_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.midiLearnGroup),
        const SizedBox(height: 12),
        Text(l10n.midiLearnHint, style: context.setupBody),
        if (!connected) ...[
          const SizedBox(height: 12),
          _Notice(
            key: const Key('midiLearn_deviceMissing'),
            text: l10n.midiLearnDeviceMissing,
            warning: true,
          ),
        ],
        const SizedBox(height: 16),
        if (bindings.isEmpty)
          _Notice(key: const Key('midiLearn_empty'), text: l10n.midiLearnEmpty)
        else
          for (final binding in bindings.bindings)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _MappingRow(
                binding: binding,
                // Matched by the mapping's KEY, not its value: the row stays
                // editable while it listens, and a nudged knob must not make
                // the listening state (and its Cancel) disappear.
                learn: learn?.replacingKey == binding.key ? learn : null,
                connected: connected,
              ),
            ),
        const SizedBox(height: 8),
        _AddRow(learn: learn?.replacingKey == null ? learn : null),
      ],
    );
  }
}

/// The "add a mapping" controls: one target picker per trigger shape, plus the
/// listening / replace-confirm states of a capture for a mapping that does not
/// exist yet.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.learn});

  /// The capture in progress for a NEW mapping, or `null`.
  final ControllerLearn? learn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final current = learn;
    if (current != null) {
      return _LearnStatus(learn: current);
    }
    // Both enumerations always offer at least the Master insert (it exists on
    // every rig), so there is no empty-picker state to render here.
    final valueTargets = looper.availableValueTargets();
    final switchTargets = looper.availableBindingTargets();
    return Row(
      children: [
        PopupMenuButton<ControlValueTarget>(
          key: const Key('midiLearn_addSweep'),
          tooltip: l10n.midiLearnAddSweep,
          onSelected: (target) => cubit.learnControllerBinding(
            target: target.canonicalString(),
          ),
          itemBuilder: (context) => [
            for (final target in valueTargets)
              PopupMenuItem(
                value: target,
                child: Text(valueTargetLabel(l10n, looper, target)),
              ),
          ],
          child: Text(l10n.midiLearnAddSweep),
        ),
        const SizedBox(width: 16),
        PopupMenuButton<FxBindingTarget>(
          key: const Key('midiLearn_addSwitch'),
          tooltip: l10n.midiLearnAddSwitch,
          onSelected: (target) => cubit.learnControllerBinding(
            target: target.canonicalString(),
            continuous: false,
          ),
          itemBuilder: (context) => [
            for (final target in switchTargets)
              PopupMenuItem(
                value: target,
                child: Text(bindingTargetLabel(l10n, target)),
              ),
          ],
          child: Text(l10n.midiLearnAddSwitch),
        ),
      ],
    );
  }
}

/// One mapping: the control, the target, the travel controls, and the row
/// actions.
class _MappingRow extends StatelessWidget {
  const _MappingRow({
    required this.binding,
    required this.learn,
    required this.connected,
  });

  final ControllerBinding binding;

  /// The capture in progress FOR THIS ROW (a relearn), or `null`.
  final ControllerLearn? learn;

  /// Whether a MIDI input is delivering right now. A disconnected rig renders
  /// every row inert — the mapping is kept, it simply cannot fire.
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<ControlCubit>();
    final looper = context.read<LooperRepository>();
    final capture = learn;
    final resolved = _resolve(l10n, looper, binding);
    final label = resolved ?? l10n.midiLearnStale;
    final control = controlLabel(l10n, binding.trigger);

    return Semantics(
      label: l10n.a11yMidiLearnRow(control, label),
      child: Container(
        key: const Key('midiLearn_row'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: surface.cardHigh,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            // The established missing-target convention (R25) — the same
            // tertiary outline a broken pedal binding and an unavailable
            // plugin already use.
            color: resolved != null && connected
                ? surface.line
                : surface.textTertiary.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (resolved == null) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    key: const Key('midiLearn_staleGlyph'),
                    size: 16,
                    color: surface.warning,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  control,
                  style: signalMono(
                    color: connected
                        ? surface.textSecondary
                        : surface.textTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: resolved != null && connected
                          ? surface.textPrimary
                          : surface.textTertiary,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('midiLearn_learn'),
                  onPressed: learn != null
                      ? null
                      : () => cubit.learnControllerBinding(
                          target: binding.target,
                          replacing: binding,
                        ),
                  // A disconnected row's Learn button IS the one-tap relearn:
                  // it re-points the mapping at whatever controller is plugged
                  // in now, which is the only repair the user can make without
                  // finding the original device.
                  child: Text(
                    connected ? l10n.midiLearnLearn : l10n.midiLearnRelearn,
                  ),
                ),
                TextButton(
                  key: const Key('midiLearn_clear'),
                  onPressed: () =>
                      unawaited(cubit.removeControllerBinding(binding)),
                  child: Text(l10n.midiLearnClear),
                ),
              ],
            ),
            if (resolved == null) ...[
              const SizedBox(height: 6),
              Text(
                l10n.midiLearnStaleDetail,
                key: const Key('midiLearn_staleDetail'),
                style: TextStyle(color: surface.textTertiary, fontSize: 12),
              ),
            ],
            if (capture != null) ...[
              const SizedBox(height: 10),
              _LearnStatus(learn: capture),
            ],
            const SizedBox(height: 10),
            switch (binding) {
              final ContinuousBinding sweep => _RangeControls(binding: sweep),
              final DiscreteBinding stomp => _SwitchControls(binding: stomp),
            },
          ],
        ),
      ),
    );
  }

  /// The live label of what [binding] drives, or `null` when the target no
  /// longer resolves (or never decoded at all).
  String? _resolve(
    AppLocalizations l10n,
    LooperRepository looper,
    ControllerBinding binding,
  ) {
    switch (binding) {
      case ContinuousBinding():
        final target = ControlValueTarget.tryParse(binding.target);
        if (target == null || !looper.valueTargetResolves(target)) return null;
        return valueTargetLabel(l10n, looper, target);
      case DiscreteBinding():
        final target = FxBindingTarget.tryParse(binding.target);
        if (target == null || !looper.bindingResolves(target)) return null;
        return bindingTargetLabel(l10n, target);
    }
  }
}

/// The LO/HI travel of a continuous mapping — the two ends a full CC sweep
/// lands on, in the target's own normalized domain.
class _RangeControls extends StatelessWidget {
  const _RangeControls({required this.binding});

  final ContinuousBinding binding;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<ControlCubit>();
    return Row(
      children: [
        SignalKnob(
          knobKey: const Key('midiLearn_lo'),
          value: binding.lo,
          onChanged: (value) => unawaited(
            cubit.updateControllerBinding(binding, binding.copyWith(lo: value)),
          ),
          label: l10n.midiLearnLo,
          semanticLabel: l10n.a11yMidiLearnLo,
          color: surface.accent,
          size: 36,
          readoutBuilder: _percent,
        ),
        const SizedBox(width: 16),
        SignalKnob(
          knobKey: const Key('midiLearn_hi'),
          value: binding.hi,
          onChanged: (value) => unawaited(
            cubit.updateControllerBinding(binding, binding.copyWith(hi: value)),
          ),
          label: l10n.midiLearnHi,
          semanticLabel: l10n.a11yMidiLearnHi,
          color: surface.accent,
          size: 36,
          readoutBuilder: _percent,
        ),
      ],
    );
  }
}

/// The threshold + behavior of a discrete mapping.
class _SwitchControls extends StatelessWidget {
  const _SwitchControls({required this.binding});

  final DiscreteBinding binding;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<ControlCubit>();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SignalKnob(
          knobKey: const Key('midiLearn_threshold'),
          value: binding.threshold / 127,
          onChanged: (value) => unawaited(
            cubit.updateControllerBinding(
              binding,
              binding.copyWith(
                threshold: (value * 127).round().clamp(
                  DiscreteBinding.minThreshold,
                  127,
                ),
              ),
            ),
          ),
          label: l10n.midiLearnThreshold,
          semanticLabel: l10n.a11yMidiLearnThreshold,
          color: surface.accent,
          size: 36,
          readoutBuilder: (value) => '${(value * 127).round()}',
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.midiLearnBehavior,
              style: TextStyle(color: surface.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SegmentedButton<BindingBehavior>(
              key: const Key('midiLearn_behavior'),
              segments: [
                ButtonSegment(
                  value: BindingBehavior.toggle,
                  label: Text(l10n.pedalAssignToggle),
                  tooltip: l10n.pedalAssignToggleHint,
                ),
                ButtonSegment(
                  value: BindingBehavior.momentary,
                  label: Text(l10n.pedalAssignMomentary),
                  tooltip: l10n.pedalAssignMomentaryHint,
                ),
              ],
              selected: {binding.behavior},
              onSelectionChanged: (s) => unawaited(
                cubit.updateControllerBinding(
                  binding,
                  binding.copyWith(behavior: s.first),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A capture in progress: "listening…" with a cancel, or the replace
/// confirmation once a control that is already mapped has been caught (R28).
class _LearnStatus extends StatelessWidget {
  const _LearnStatus({required this.learn});

  final ControllerLearn learn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<ControlCubit>();
    final captured = learn.captured;
    return Row(
      key: const Key('midiLearn_status'),
      children: [
        Expanded(
          child: Text(
            captured == null
                ? l10n.midiLearnListening
                : l10n.midiLearnReplacePrompt(controlLabel(l10n, captured)),
            style: TextStyle(color: surface.textSecondary),
          ),
        ),
        if (captured != null)
          TextButton(
            key: const Key('midiLearn_replace'),
            onPressed: () => unawaited(cubit.confirmControllerLearn()),
            child: Text(l10n.midiLearnReplace),
          ),
        TextButton(
          key: const Key('midiLearn_cancel'),
          onPressed: cubit.cancelControllerLearn,
          child: Text(
            captured == null ? l10n.midiLearnCancel : l10n.midiLearnKeep,
          ),
        ),
      ],
    );
  }
}

/// A plain explanatory block — the empty, no-targets and device-missing
/// states, which are information rather than an editable row.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warning = false, super.key});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.line),
      ),
      child: Row(
        children: [
          if (warning) ...[
            Icon(
              Icons.usb_off_rounded,
              size: 16,
              color: surface.textTertiary,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(text, style: TextStyle(color: surface.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// A normalized `0..1` value as a whole percent — the readout every LO/HI knob
/// shows, since the domain is normalized whatever the target actually is.
String _percent(double value) => '${(value * 100).round()}%';
