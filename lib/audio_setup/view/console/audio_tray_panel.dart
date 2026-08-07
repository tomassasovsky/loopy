import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/audio_setup/view/console/device_audio_tab.dart';
import 'package:segno/audio_setup/view/console/recording_audio_tab.dart';
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
/// What differs is that it is TWO tabs where the design first drew three. The
/// Status tab was dissolved into [AudioTab.device]: a figure shown both beside
/// the setting that decides it and on a page of its own is a figure that can
/// disagree with itself.
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
        ],
        body: switch (tab) {
          AudioTab.device => const DeviceAudioTab(),
          AudioTab.recording => const RecordingAudioTab(),
        },
      ),
    );
  }
}
