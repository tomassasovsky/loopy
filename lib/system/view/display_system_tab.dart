import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/shortcuts_help_sheet.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';

/// The Display tab of the console's System domain, drawn to `SYSTEM / display`
/// and `waveform-failed`: what the rig shows, how fast it redraws it, and
/// where the shortcut legend lives.
class DisplaySystemTab extends StatelessWidget {
  /// Creates a [DisplaySystemTab].
  const DisplaySystemTab({
    required this.waveformFailed,
    required this.onRetryWaveform,
    super.key,
  });

  /// Whether the second window refused to open.
  final bool waveformFailed;

  /// Tries to open it again.
  final VoidCallback onRetryWaveform;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final waveform = context.watch<WaveformWindowCubit>();
    final contrast = context.watch<HighContrastCubit>();
    final tracks = context.watch<TracksCubit>();
    final refresh = context.watch<RefreshRateCubit>();

    return KeyedSubtree(
      key: const Key('display_system_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.systemViewGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                // The failure rides at the top of the list it belongs to, in
                // the words the toast already uses — the setting that failed
                // is the row below it.
                if (waveformFailed)
                  ConsoleBanner(
                    key: const Key('system_waveform_failed'),
                    message: l10n.waveformWindowFailedBanner,
                    failed: true,
                    actionKey: const Key('system_waveform_retry'),
                    actionLabel: l10n.networkTryAgainAction,
                    onAction: onRetryWaveform,
                  ),
                ConsoleRow(
                  key: const Key('system_waveform_row'),
                  title: l10n.waveformWindowTitle,
                  subtitle: l10n.waveformWindowSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('system_waveform_switch'),
                    value: waveform.state,
                    semanticLabel: l10n.waveformWindowTitle,
                    onChanged: (on) =>
                        unawaited(waveform.setEnabled(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('system_contrast_row'),
                  title: l10n.highContrastTitle,
                  subtitle: l10n.highContrastSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('system_contrast_switch'),
                    value: contrast.state,
                    semanticLabel: l10n.highContrastTitle,
                    onChanged: (on) =>
                        unawaited(contrast.setEnabled(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('system_indicators_row'),
                  divider: false,
                  title: l10n.trackIndicatorsTitle,
                  subtitle: l10n.trackIndicatorsSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('system_indicators_switch'),
                    value: tracks.state.showIndicators,
                    semanticLabel: l10n.trackIndicatorsTitle,
                    onChanged: (on) =>
                        unawaited(tracks.setShowIndicators(value: on)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemPerformanceGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('system_refresh_row'),
                  divider: false,
                  title: l10n.systemRefreshRateTitle,
                  subtitle: l10n.systemRefreshRateSubtitle,
                  value: l10n.refreshRateHz(refresh.state),
                  onTap: () => unawaited(_pickRefreshRate(context, refresh)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemHelpGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('system_shortcuts_row'),
                  divider: false,
                  title: l10n.a11yShortcutsHelp,
                  onTap: () => unawaited(showShortcutsHelp(context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickRefreshRate(
    BuildContext context,
    RefreshRateCubit refresh,
  ) async {
    final l10n = context.l10n;
    final chosen = await showConsoleChipDialog<int>(
      context,
      title: l10n.systemRefreshRateTitle,
      explanation: l10n.systemRefreshRateSubtitle,
      selected: refresh.state,
      options: [
        for (final hz in RefreshRateCubit.options)
          ConsoleSegment(value: hz, label: l10n.refreshRateHz(hz)),
      ],
    );
    if (chosen == null) return;
    await refresh.setHz(chosen);
  }
}
