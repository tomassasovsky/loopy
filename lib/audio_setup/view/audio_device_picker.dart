import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/surface_theme.dart';

/// A dark-styled dropdown that picks an audio device by id: optionally
/// "System default" (empty id) plus the enumerated [devices]. A selected id
/// that is no longer present (e.g. an unplugged pinned device) falls back so
/// the dropdown value stays valid. Used by the in-settings audio section.
class AudioDevicePicker extends StatelessWidget {
  /// Creates an [AudioDevicePicker].
  const AudioDevicePicker({
    required this.pickerKey,
    required this.devices,
    required this.selectedId,
    required this.onSelected,
    this.semanticLabel,
    this.includeSystemDefault = true,
    super.key,
  });

  /// Key for the underlying dropdown (so tests can target it).
  final String pickerKey;

  /// The accessible name for the dropdown (e.g. "Output device"). The visible
  /// group label is a detached sibling, so without this the control announces
  /// only its current value with no role context (WCAG 3.3.2).
  final String? semanticLabel;

  /// The selectable devices (one direction).
  final List<AudioDevice> devices;

  /// The currently selected device id, or empty for the system default.
  final String selectedId;

  /// Called with the chosen device id (empty for system default when
  /// [includeSystemDefault] is true).
  final ValueChanged<String> onSelected;

  /// Whether to offer the empty-id "System default" item. Off on the console
  /// build, where a concrete interface must be pinned.
  final bool includeSystemDefault;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final value = _effectiveValue();
    final defaults = devices.where((d) => d.isDefault);
    final defaultName = defaults.isEmpty ? null : defaults.first.name;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.surface.card,
          borderRadius: BorderRadius.circular(SurfaceTheme.radius12),
          border: Border.all(color: context.surface.line),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            focusColor: Colors.transparent,
            key: Key(pickerKey),
            value: value,
            isExpanded: true,
            dropdownColor: context.surface.cardHigh,
            borderRadius: BorderRadius.circular(SurfaceTheme.radius12),
            icon: Icon(
              Icons.expand_more,
              color: context.surface.textSecondary,
            ),
            style: TextStyle(color: context.surface.textPrimary, fontSize: 14),
            items: [
              if (includeSystemDefault)
                DropdownMenuItem(
                  value: '',
                  child: Text(
                    defaultName == null
                        ? l10n.systemDefault
                        : l10n.systemDefaultNamed(defaultName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              for (final device in devices)
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
              if (id != null) onSelected(id);
            },
          ),
        ),
      ),
    );
  }

  /// Keeps [DropdownButton.value] in the item list: prefer [selectedId] when
  /// present, else system default (when offered), else the first concrete
  /// device so console pickers never land on a missing empty id.
  String _effectiveValue() {
    if (devices.any((d) => d.id == selectedId)) return selectedId;
    if (includeSystemDefault) return '';
    for (final device in devices) {
      if (!device.isDefault) return device.id;
    }
    return devices.isEmpty ? '' : devices.first.id;
  }
}
