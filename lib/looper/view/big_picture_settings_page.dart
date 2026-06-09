import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';

/// Settings for the Big Picture performance view, reachable from the view via
/// right-click or the `S` key, and from the system menu bar on macOS.
///
/// Intentionally minimal: rename tracks, reach the audio device setup, toggle
/// the secondary waveform window, and switch back to the desktop layout.
class BigPictureSettingsPage extends StatelessWidget {
  /// Creates a [BigPictureSettingsPage].
  const BigPictureSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final big = context.watch<BigPictureCubit>();
    final mode = context.watch<UiModeCubit>().state;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state;
    final bankEnabled = context.watch<BankCubit>().state.enabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Big Picture settings'),
        leading: IconButton(
          key: const Key('bpSettings_close_button'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader('View'),
          SwitchListTile(
            key: const Key('bpSettings_bigPicture_switch'),
            title: const Text('Big Picture mode'),
            subtitle: const Text('Full-screen performance layout'),
            value: mode == UiMode.bigPicture,
            onChanged: (on) {
              unawaited(
                context.read<UiModeCubit>().setMode(
                  on ? UiMode.bigPicture : UiMode.desktop,
                ),
              );
              unawaited(Navigator.of(context).maybePop());
            },
          ),
          SwitchListTile(
            key: const Key('bpSettings_waveformWindow_switch'),
            title: const Text('Output waveform window'),
            subtitle: const Text(
              'Open a second window showing the whole-loop output waveform',
            ),
            value: waveformEnabled,
            onChanged: (on) => context.read<WaveformWindowCubit>().setEnabled(
              value: on,
            ),
          ),
          const Divider(),
          const _SectionHeader('Audio'),
          ListTile(
            key: const Key('bpSettings_audioSetup_tile'),
            leading: const Icon(Icons.settings_input_component),
            title: const Text('Audio device setup'),
            subtitle: const Text('Sample rate, buffer, monitoring, latency'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AudioSetupPage(
                  repository: context.read<LooperRepository>(),
                  settings: context.read<SettingsRepository>(),
                ),
              ),
            ),
          ),
          const Divider(),
          const _SectionHeader('Tracks'),
          SwitchListTile(
            key: const Key('bpSettings_bank_switch'),
            title: const Text('Second bank (8 tracks)'),
            subtitle: const Text(
              'Adds a second bank of four tracks, switchable as A / B',
            ),
            value: bankEnabled,
            onChanged: (on) => context.read<BankCubit>().setEnabled(value: on),
          ),
          for (var i = 0; i < big.state.names.length; i++)
            ListTile(
              key: Key('bpSettings_trackName_$i'),
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text(big.state.names[i]),
              trailing: const Icon(Icons.edit),
              onTap: () => _renameTrack(context, i, big.state.names[i]),
            ),
        ],
      ),
    );
  }

  Future<void> _renameTrack(
    BuildContext context,
    int channel,
    String current,
  ) async {
    final cubit = context.read<BigPictureCubit>();
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Rename track ${channel + 1}'),
        content: TextField(
          key: const Key('bpSettings_rename_field'),
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('bpSettings_rename_save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await cubit.rename(channel, result);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}
