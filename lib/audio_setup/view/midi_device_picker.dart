import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The MIDI foot-controller block in the audio/I-O settings: a device dropdown
/// (with a "None" item and an absent-selection fallback), an empty state, a
/// live connection status line, a raw-input [MidiActivityIndicator], and the
/// fixed required-CC hint. Driven by [MidiSetupCubit]; fully independent of the
/// audio engine, so it renders even in Windows ASIO-only mode.
class MidiDevicePicker extends StatelessWidget {
  /// Creates a [MidiDevicePicker].
  const MidiDevicePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<MidiSetupCubit>();
    final state = cubit.state;

    return Column(
      key: const Key('midiSettings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.midiInputGroup),
        const SizedBox(height: 12),
        if (state.devices.isEmpty && !state.hasSelection)
          const _MidiEmptyState()
        else
          _MidiDropdown(state: state, onSelected: cubit.select),
        const SizedBox(height: 12),
        _MidiStatusLine(state: state),
        const SizedBox(height: 12),
        MidiActivityIndicator(activity: cubit.activity),
        const SizedBox(height: 12),
        Text(l10n.midiRequiredCcsHint, style: setupBody),
      ],
    );
  }
}

/// The empty state shown when the host exposes no MIDI input ports and none is
/// pinned. The looper stays fully usable — this is informational, not an error.
class _MidiEmptyState extends StatelessWidget {
  const _MidiEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('midiSettings_empty'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.surface.line),
      ),
      child: Text(context.l10n.midiNoDevicesFound, style: setupBody),
    );
  }
}

/// The dark-styled MIDI device dropdown: a "None" item plus the enumerated
/// devices. A pinned device that is currently absent is appended (labelled
/// "(not found)") so the selection stays visible and the dropdown value stays
/// valid — mirroring `AudioDevicePicker`'s absent-selection fallback.
class _MidiDropdown extends StatelessWidget {
  const _MidiDropdown({required this.state, required this.onSelected});

  final MidiSetupState state;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showAbsentPinned = state.hasSelection && !state.isSelectedPresent;
    final value = state.hasSelection ? state.selectedId : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: context.surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.surface.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          focusColor: Colors.transparent,
          key: const Key('midiSettings_device_picker'),
          value: value,
          isExpanded: true,
          dropdownColor: context.surface.cardHigh,
          borderRadius: BorderRadius.circular(12),
          icon: Icon(Icons.expand_more, color: context.surface.textSecondary),
          style: TextStyle(color: context.surface.textPrimary, fontSize: 14),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                l10n.midiNone,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final device in state.devices)
              DropdownMenuItem(
                value: device.id,
                child: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (showAbsentPinned)
              DropdownMenuItem(
                value: state.selectedId,
                child: Text(
                  l10n.midiDeviceNotFound(
                    state.selectedName.isEmpty
                        ? state.selectedId
                        : state.selectedName,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) onSelected(id);
          },
        ),
      ),
    );
  }
}

/// A one-line status for the pinned MIDI device, exposed to screen readers via
/// the surrounding text (semantics, not color-only).
class _MidiStatusLine extends StatelessWidget {
  const _MidiStatusLine({required this.state});

  final MidiSetupState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = state.selectedName.isEmpty
        ? state.selectedId
        : state.selectedName;
    final (message, isError) = switch (state.status) {
      MidiSetupStatus.none => (l10n.midiStatusNone, false),
      MidiSetupStatus.connecting => (l10n.midiStatusConnecting, false),
      MidiSetupStatus.connected => (l10n.midiStatusConnected(name), false),
      MidiSetupStatus.deviceGone => (l10n.midiStatusDeviceGone(name), false),
      MidiSetupStatus.error => (l10n.midiStatusOpenFailed(name), true),
    };
    return Text(
      message,
      key: const Key('midiSettings_status'),
      style: setupBody.copyWith(
        color: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

/// A blink indicator for raw (pre-mapping) MIDI input: it lights up briefly on
/// every recognized Note/CC message so the user can confirm the pedal is
/// talking, even when a message is unmapped. Not color-only — it pairs an icon
/// with a text label and a screen-reader [Semantics] announcement.
class MidiActivityIndicator extends StatefulWidget {
  /// Creates a [MidiActivityIndicator] driven by [activity]; a `null` stream
  /// (no MIDI backend) renders a steady idle state.
  const MidiActivityIndicator({required this.activity, super.key});

  /// The raw activity stream from [MidiSetupCubit.activity].
  final Stream<RawControllerInput>? activity;

  @override
  State<MidiActivityIndicator> createState() => _MidiActivityIndicatorState();
}

class _MidiActivityIndicatorState extends State<MidiActivityIndicator> {
  StreamSubscription<RawControllerInput>? _subscription;
  Timer? _blinkTimer;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(MidiActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity != widget.activity) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.activity?.listen((_) => _flash());
  }

  void _flash() {
    _blinkTimer?.cancel();
    if (!_active) setState(() => _active = true);
    _blinkTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _active = false);
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = _active ? l10n.midiActivityActive : l10n.midiActivityIdle;
    final color = _active
        ? context.surface.accent
        : context.surface.textSecondary;
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Row(
          key: const Key('midiSettings_activity'),
          children: [
            Icon(
              _active ? Icons.circle : Icons.circle_outlined,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 8),
            Text(label, style: setupBody.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
