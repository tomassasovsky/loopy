import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/view/console/device_audio_tab.dart';
import 'package:segno/audio_setup/view/console/recording_audio_tab.dart';
import 'package:segno/audio_setup/view/console/status_audio_tab.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';

/// The Audio domain: what the rig plays through, what pressing record does,
/// and what it is actually doing right now, as three tabs of one rail entry.
///
/// Same construction as Control, Loop and Tracks — a title above a [PillTabs]
/// strip, no chrome bar, a Flutter-free tab enum the tray cubit can hold
/// without importing a view, and the selected tab kept across navigation in
/// `SettingsTrayState`.
///
/// What differs is [AudioTab.status]: it is the console's one **read-only**
/// tab. The settings that decide those figures live on Device, and a figure
/// editable in two places is a figure that disagrees with itself.
class AudioTrayPanel extends StatelessWidget {
  /// Creates an [AudioTrayPanel].
  const AudioTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tab = context.watch<SettingsTrayCubit>().state.audioTab;
    final cubit = context.read<SettingsTrayCubit>();

    return KeyedSubtree(
      key: const Key('audio_tray_panel'),
      child: ConsoleDomainPanel<AudioTab>(
        title: l10n.trayAudioLabel,
        tabsKey: const Key('audio_tabs'),
        selected: tab,
        onChanged: cubit.showAudioTab,
        tabs: [
          PillTab(value: AudioTab.device, label: l10n.audioDeviceTab),
          PillTab(value: AudioTab.recording, label: l10n.audioRecordingTab),
          PillTab(value: AudioTab.status, label: l10n.audioStatusTab),
        ],
        body: switch (tab) {
          AudioTab.device => const DeviceAudioTab(),
          AudioTab.recording => const RecordingAudioTab(),
          AudioTab.status => const StatusAudioTab(),
        },
      ),
    );
  }
}
