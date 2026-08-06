import 'package:flutter/material.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/view/device_audio_tab.dart';
import 'package:segno/audio_setup/view/status_audio_tab.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// In-tray Audio face: what the rig plays through, what it does when you
/// record, and what it is actually doing — three tabs of one rail
/// destination, drawn to the `AUDIO / *` screens.
class AudioTrayPanel extends StatelessWidget {
  /// Creates an [AudioTrayPanel].
  const AudioTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final AudioTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<AudioTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return KeyedSubtree(
      key: const Key('audio_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.trayAudioLabel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<AudioTab>(
              key: const Key('audio_tabs'),
              selected: tab,
              onChanged: onTabChanged,
              tabs: [
                PillTab(value: AudioTab.device, label: l10n.audioDeviceTab),
                PillTab(
                  value: AudioTab.recording,
                  label: l10n.audioRecordingTab,
                ),
                PillTab(value: AudioTab.status, label: l10n.audioStatusTab),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (tab) {
              AudioTab.device => const DeviceAudioTab(),
              // Recording lands in its own commit.
              AudioTab.recording => const StatusAudioTab(),
              AudioTab.status => const StatusAudioTab(),
            },
          ),
        ],
      ),
    );
  }
}
