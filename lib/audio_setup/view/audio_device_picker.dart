import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

/// A dark-styled dropdown that picks an audio device by id: "System default"
/// (empty id) plus the enumerated [devices]. A selected id that is no longer
/// present (e.g. an unplugged pinned device) falls back to the default so the
/// dropdown value stays valid. Shared by the audio-setup wizard and the
/// in-settings audio section.
class AudioDevicePicker extends StatelessWidget {
  /// Creates an [AudioDevicePicker].
  const AudioDevicePicker({
    required this.pickerKey,
    required this.devices,
    required this.selectedId,
    required this.onSelected,
    super.key,
  });

  /// Key for the underlying dropdown (so tests can target it).
  final String pickerKey;

  /// The selectable devices (one direction).
  final List<AudioDevice> devices;

  /// The currently selected device id, or empty for the system default.
  final String selectedId;

  /// Called with the chosen device id (empty for system default).
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final value = devices.any((d) => d.id == selectedId) ? selectedId : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SetupSurfaceColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: Key(pickerKey),
          value: value,
          isExpanded: true,
          dropdownColor: SetupSurfaceColors.cardHi,
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.expand_more, color: SetupSurfaceColors.t2),
          style: const TextStyle(color: SetupSurfaceColors.t1, fontSize: 14),
          items: [
            const DropdownMenuItem(value: '', child: Text('System default')),
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
    );
  }
}
