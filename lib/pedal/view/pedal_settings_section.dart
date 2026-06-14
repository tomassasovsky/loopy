import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart' show PedalBindStatus;

/// The bidirectional-pedal block in the audio/I-O settings: a MIDI **output**
/// device dropdown (with a "None" item) for the pedal's LED feedback link and a
/// live bind-status line. Driven by [PedalCubit]; independent of the audio
/// engine, so it renders even in Windows ASIO-only mode.
///
/// The pedal's *input* (footswitches) shares the MIDI input device selected in
/// the MIDI input section; this only binds the output destination loopy pushes
/// state frames to.
class PedalSettingsSection extends StatelessWidget {
  /// Creates a [PedalSettingsSection].
  const PedalSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<PedalCubit>();
    final outputs = cubit.availableOutputs();
    final boundId = cubit.boundOutputId;

    return Column(
      key: const Key('pedalSettings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.pedalOutputGroup),
        const SizedBox(height: 12),
        if (outputs.isEmpty && boundId == null)
          const _PedalEmptyState()
        else
          _PedalDropdown(
            outputs: outputs,
            boundId: boundId,
            onSelectNone: cubit.selectNone,
            onSelected: cubit.selectOutput,
          ),
        const SizedBox(height: 12),
        _PedalStatusLine(
          status: cubit.state.bindStatus,
          deviceName: _boundName(outputs, boundId),
        ),
        const SizedBox(height: 12),
        Text(l10n.pedalOutputHint, style: setupBody),
      ],
    );
  }

  String _boundName(List<MidiDevice> outputs, String? boundId) {
    if (boundId == null) return '';
    for (final device in outputs) {
      if (device.id == boundId) return device.name;
    }
    return boundId;
  }
}

/// Shown when the host exposes no MIDI output ports and none is bound. The
/// looper and the pedal's footswitches still work — only LED feedback is idle.
class _PedalEmptyState extends StatelessWidget {
  const _PedalEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('pedalSettings_empty'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.surface.line),
      ),
      child: Text(context.l10n.pedalNoOutputs, style: setupBody),
    );
  }
}

/// The dark-styled pedal output dropdown: a "None" item plus the enumerated
/// output destinations.
class _PedalDropdown extends StatelessWidget {
  const _PedalDropdown({
    required this.outputs,
    required this.boundId,
    required this.onSelectNone,
    required this.onSelected,
  });

  final List<MidiDevice> outputs;
  final String? boundId;
  final VoidCallback onSelectNone;
  final ValueChanged<MidiDevice> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final present = outputs.any((d) => d.id == boundId);
    final value = (boundId != null && present) ? boundId : '';

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
          key: const Key('pedalSettings_device_picker'),
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
                l10n.pedalNone,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final device in outputs)
              DropdownMenuItem(
                value: device.id,
                child: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            if (id == null || id.isEmpty) {
              onSelectNone();
              return;
            }
            for (final device in outputs) {
              if (device.id == id) {
                onSelected(device);
                return;
              }
            }
          },
        ),
      ),
    );
  }
}

/// A one-line bind status for the pedal output link, exposed to screen readers
/// via the text itself (semantics, not color-only).
class _PedalStatusLine extends StatelessWidget {
  const _PedalStatusLine({required this.status, required this.deviceName});

  final PedalBindStatus status;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (message, isError) = switch (status) {
      PedalBindStatus.none => (l10n.pedalStatusNone, false),
      PedalBindStatus.connecting => (l10n.pedalStatusConnecting, false),
      PedalBindStatus.bound => (l10n.pedalStatusBound(deviceName), false),
      PedalBindStatus.error => (l10n.pedalStatusError(deviceName), true),
    };
    return Text(
      message,
      key: const Key('pedalSettings_status'),
      style: setupBody.copyWith(
        color: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}
