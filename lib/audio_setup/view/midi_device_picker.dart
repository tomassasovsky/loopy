import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:midi_device_repository/midi_device_repository.dart';

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
        if (state.connection.devices.isEmpty && !state.connection.hasSelection)
          const _MidiEmptyState()
        else
          _MidiDropdown(connection: state.connection, onSelected: cubit.select),
        const SizedBox(height: 12),
        _MidiStatusLine(connection: state.connection),
        const SizedBox(height: 12),
        const MidiActivityIndicator(),
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
  const _MidiDropdown({required this.connection, required this.onSelected});

  final MidiConnection connection;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showAbsentPinned =
        connection.hasSelection && !connection.isSelectedPresent;
    final value = connection.hasSelection ? connection.selectedId : '';

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
            for (final device in connection.devices)
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
                value: connection.selectedId,
                child: Text(
                  l10n.midiDeviceNotFound(
                    connection.selectedName.isEmpty
                        ? connection.selectedId
                        : connection.selectedName,
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
  const _MidiStatusLine({required this.connection});

  final MidiConnection connection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = connection.selectedName.isEmpty
        ? connection.selectedId
        : connection.selectedName;
    final (message, isError) = switch (connection.status) {
      MidiConnectionStatus.none => (l10n.midiStatusNone, false),
      MidiConnectionStatus.connecting => (l10n.midiStatusConnecting, false),
      MidiConnectionStatus.connected => (l10n.midiStatusConnected(name), false),
      MidiConnectionStatus.deviceGone => (
        l10n.midiStatusDeviceGone(name),
        false,
      ),
      MidiConnectionStatus.error => (l10n.midiStatusOpenFailed(name), true),
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
/// talking, even when a message is unmapped. Driven by [MidiSetupState]'s
/// `activityTick` (so the cubit exposes no stream). Not color-only — it pairs
/// an icon with a text label and a screen-reader [Semantics] announcement.
class MidiActivityIndicator extends StatefulWidget {
  /// Creates a [MidiActivityIndicator].
  const MidiActivityIndicator({super.key});

  @override
  State<MidiActivityIndicator> createState() => _MidiActivityIndicatorState();
}

class _MidiActivityIndicatorState extends State<MidiActivityIndicator> {
  Timer? _blinkTimer;
  bool _active = false;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = _active ? l10n.midiActivityActive : l10n.midiActivityIdle;
    final color = _active
        ? context.surface.accent
        : context.surface.textSecondary;
    return BlocListener<MidiSetupCubit, MidiSetupState>(
      listenWhen: (previous, current) =>
          previous.activityTick != current.activityTick,
      listener: (_, _) => _flash(),
      child: Semantics(
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
      ),
    );
  }
}
