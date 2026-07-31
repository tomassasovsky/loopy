import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
import 'package:loopy/pedal/view/pedal_assignment_page.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:pedal_repository/pedal_repository.dart'
    show PedalBindStatus, PedalCodec, PedalOutput;

/// Dropdown value for the "None" item — not a real device id (hosts may expose
/// ports whose id is empty, which would duplicate `''` and trip
/// DropdownButton).
const _kPedalNoneValue = '__loopy_pedal_none__';

/// Dropdown value for the "not set" firmware-version item — protocol
/// versions start at 1, so 0 is never a real version.
const _kPedalVersionUnknownValue = 0;

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
    final outputs = cubit.state.availableOutputs;
    final boundId = cubit.state.boundOutputId;

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
        const SizedBox(height: 24),
        // No hint line under this one: the assignment page opens with the
        // same sentence, so repeating it here only costs height.
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('pedalSettings_openAssignments'),
            onPressed: () => showPedalAssignmentPage(context),
            icon: const Icon(Icons.piano_outlined, size: 16),
            label: Text(l10n.pedalAssignTitle),
          ),
        ),
        const SizedBox(height: 24),
        SetupGroupLabel(l10n.pedalFirmwareGroup),
        const SizedBox(height: 12),
        _PedalFirmwareVersionDropdown(
          firmwareVersion: cubit.state.firmwareVersion,
          onSelected: cubit.selectFirmwareVersion,
        ),
        const SizedBox(height: 12),
        Text(l10n.pedalFirmwareHint, style: setupBody),
        // The condition itself is the cubit's (it reads the repository's
        // resolved wire version) — this only renders the answer.
        if (cubit.state.firmwareUpdateAvailable) ...[
          const SizedBox(height: 12),
          _PedalFirmwareUpdateBanner(
            firmwareVersion: cubit.state.firmwareVersion,
          ),
        ],
      ],
    );
  }

  String _boundName(List<PedalOutput> outputs, String? boundId) {
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

/// Shown while a pedal is bound but negotiates BELOW the newest protocol
/// (flow err-4): FX mode still works — the projection never branches on the
/// pedal version (B10) — but the codec downgrades it, so the chain LEDs come
/// out green instead of blue and the pedal reads FX as mute. Explaining that
/// here is the difference between "my pedal is broken" and "my pedal is old".
///
/// Informational for now: it names the fix (flash the newer firmware, then
/// pick the version above). The one-tap update ride-along lands with the
/// auto-detect/OTA flow (#331), which owns the flashing UI.
class _PedalFirmwareUpdateBanner extends StatelessWidget {
  const _PedalFirmwareUpdateBanner({required this.firmwareVersion});

  /// The negotiated version, or `null` when not set (the v2 safety floor).
  final int? firmwareVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final version = firmwareVersion;
    final body = version == null
        ? l10n.pedalFirmwareUpdateBodyUnknown(
            PedalCodec.protocolVersion, // the unknown ⇒ v2 safety floor
            PedalCodec.protocolVersionMax,
          )
        : l10n.pedalFirmwareUpdateBody(version, PedalCodec.protocolVersionMax);

    // A live region: the banner appears and disappears as the pedal binds,
    // unbinds, or its version is set — transitions a screen reader must hear
    // without navigating back to this section (WCAG 4.1.3).
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('pedalSettings_firmwareUpdate_banner'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: context.surface.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.primary),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.pedalFirmwareUpdateTitle,
              style: setupBody.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(body, style: setupBody),
          ],
        ),
      ),
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

  final List<PedalOutput> outputs;
  final String? boundId;
  final VoidCallback onSelectNone;
  final ValueChanged<PedalOutput> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final present = boundId != null && outputs.any((d) => d.id == boundId);
    final value = present ? boundId! : _kPedalNoneValue;
    final seenIds = <String>{};

    return _PedalStyledDropdown<String>(
      pickerKey: const Key('pedalSettings_device_picker'),
      value: value,
      items: [
        DropdownMenuItem(
          value: _kPedalNoneValue,
          child: Text(
            l10n.pedalNone,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final device in outputs)
          if (seenIds.add(device.id))
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
        if (id == null || id == _kPedalNoneValue) {
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
    );
  }
}

/// The shared dark-styled dropdown shell both pedal pickers render: one
/// definition of the bordered card + [DropdownButton] chrome, so a styling
/// change lands in a single place. (The audio-setup pickers carry their own
/// copies of this chrome — unifying those is outside this feature's scope.)
class _PedalStyledDropdown<T> extends StatelessWidget {
  const _PedalStyledDropdown({
    required this.pickerKey,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  /// Placed on the inner [DropdownButton], which the widget tests target.
  final Key pickerKey;

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: context.surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.surface.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          focusColor: Colors.transparent,
          key: pickerKey,
          value: value,
          isExpanded: true,
          dropdownColor: context.surface.cardHigh,
          borderRadius: BorderRadius.circular(12),
          icon: Icon(Icons.expand_more, color: context.surface.textSecondary),
          style: TextStyle(color: context.surface.textPrimary, fontSize: 14),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// The manual pedal firmware wire-protocol version picker — the pre-#331
/// version-discovery gate (R6). "Not set" keeps outbound frames at the v2
/// safety floor; picking the flashed firmware's version lets loopy encode up
/// to it (pedal FX mode needs v3). Options span v1 through the newest
/// protocol the codec speaks, so a future bump appears here without a UI
/// change.
class _PedalFirmwareVersionDropdown extends StatelessWidget {
  const _PedalFirmwareVersionDropdown({
    required this.firmwareVersion,
    required this.onSelected,
  });

  /// The saved version, or `null` when not set (unknown).
  final int? firmwareVersion;

  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Show only a version the items actually contain (mirrors
    // _PedalDropdown's present-guard): a stored value outside the codec's
    // range — written by a newer build with a higher protocolVersionMax, or
    // a corrupted pref — renders as "not set" instead of tripping
    // DropdownButton's one-matching-item assert. The repository clamps the
    // same value independently for wire encoding.
    final known = firmwareVersion;
    final value =
        (known != null &&
            known >= PedalCodec.protocolVersionV1 &&
            known <= PedalCodec.protocolVersionMax)
        ? known
        : _kPedalVersionUnknownValue;

    return _PedalStyledDropdown<int>(
      pickerKey: const Key('pedalSettings_firmware_picker'),
      value: value,
      items: [
        DropdownMenuItem(
          value: _kPedalVersionUnknownValue,
          child: Text(
            l10n.pedalFirmwareUnknown(PedalCodec.protocolVersion),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (
          var version = PedalCodec.protocolVersionV1;
          version <= PedalCodec.protocolVersionMax;
          version++
        )
          DropdownMenuItem(
            value: version,
            child: Text(
              l10n.pedalFirmwareVersion(version),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (version) {
        if (version == null) return;
        onSelected(version == _kPedalVersionUnknownValue ? null : version);
      },
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
    // A live region so bind / connecting / error transitions are announced as
    // they happen, not only on navigation (WCAG 4.1.3).
    return Semantics(
      liveRegion: true,
      child: Text(
        message,
        key: const Key('pedalSettings_status'),
        style: setupBody.copyWith(
          color: isError ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    );
  }
}
