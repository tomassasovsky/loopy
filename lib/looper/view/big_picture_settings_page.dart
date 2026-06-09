import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';

/// Settings for the Big Picture performance view, reachable from the view via
/// right-click or the `S` key, and from the system menu bar on macOS.
///
/// Laid out like the audio onboarding panel: a dark centered surface with a
/// left context rail and a scrollable right pane of grouped controls.
class BigPictureSettingsPage extends StatelessWidget {
  /// Creates a [BigPictureSettingsPage].
  const BigPictureSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final big = context.watch<BigPictureCubit>();
    final mode = context.watch<UiModeCubit>().state;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state;
    final bankEnabled = context.watch<BankCubit>().state.enabled;

    return SetupSurfacePanel(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(width: 264, child: _SettingsRail()),
              const VerticalDivider(
                width: 1,
                thickness: 1,
                color: SetupSurfaceColors.line,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(34, 34, 30, 26),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Tune the performance view, waveform window, and '
                          'track layout.',
                          style: setupBody,
                        ),
                        const SizedBox(height: 28),
                        const SetupGroupLabel('VIEW'),
                        const SizedBox(height: 12),
                        SetupToggleRow(
                          toggleKey: const Key('bpSettings_bigPicture_switch'),
                          title: 'Big Picture mode',
                          subtitle: 'Full-screen performance layout',
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
                        const SizedBox(height: 12),
                        SetupToggleRow(
                          toggleKey: const Key(
                            'bpSettings_waveformWindow_switch',
                          ),
                          title: 'Output waveform window',
                          subtitle:
                              'Open a second window showing the whole-loop '
                              'output waveform',
                          value: waveformEnabled,
                          onChanged: (on) => context
                              .read<WaveformWindowCubit>()
                              .setEnabled(value: on),
                        ),
                        const SizedBox(height: 28),
                        const SetupGroupLabel('AUDIO'),
                        const SizedBox(height: 12),
                        SetupNavRow(
                          rowKey: const Key('bpSettings_audioSetup_tile'),
                          title: 'Audio device setup',
                          subtitle: 'Sample rate, buffer, monitoring, latency',
                          icon: Icons.settings_input_component,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const AudioSetupPage(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        const SetupGroupLabel('TRACKS'),
                        const SizedBox(height: 12),
                        SetupToggleRow(
                          toggleKey: const Key('bpSettings_bank_switch'),
                          title: 'Second bank (8 tracks)',
                          subtitle:
                              'Adds a second bank of four tracks, switchable '
                              'as A / B',
                          value: bankEnabled,
                          onChanged: (on) =>
                              context.read<BankCubit>().setEnabled(value: on),
                        ),
                        const SizedBox(height: 12),
                        for (var i = 0; i < big.state.names.length; i++) ...[
                          SetupTrackNameRow(
                            rowKey: Key('bpSettings_trackName_$i'),
                            channel: i,
                            name: big.state.names[i],
                            onTap: () => showRenameTrackDialog(
                              context: context,
                              cubit: context.read<BigPictureCubit>(),
                              channel: i,
                              current: big.state.names[i],
                            ),
                          ),
                          if (i < big.state.names.length - 1)
                            const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 10,
            right: 10,
            child: IconButton(
              key: const Key('bpSettings_close_button'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.close,
                size: 18,
                color: SetupSurfaceColors.t2,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsRail extends StatelessWidget {
  const _SettingsRail();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 32, 22, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: SetupSurfaceColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'SETTINGS',
                style: setupKicker.copyWith(color: SetupSurfaceColors.t2),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text('Big Picture', style: setupTitle),
          const SizedBox(height: 10),
          const Text(
            'Rename tracks, reach audio setup, and switch layouts.',
            style: setupBody,
          ),
        ],
      ),
    );
  }
}
