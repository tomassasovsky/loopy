import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/update/cubit/update_cubit.dart';

/// The "Updates" section of the settings surface: installed version + channel,
/// an auto-check toggle (governs only the read-only check), and a
/// phase-appropriate action area (check / available / downloading / staged).
/// Applying is always an explicit, confirmed action — never automatic.
class UpdatesSettingsSection extends StatelessWidget {
  /// Creates an [UpdatesSettingsSection].
  const UpdatesSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<UpdateCubit>().state;
    final cubit = context.read<UpdateCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.updatesIntro, style: setupBody),
        const SizedBox(height: 28),
        SetupInfoTable(
          rows: [
            (
              l10n.updatesInstalledVersionLabel,
              l10n.updatesVersionValue(state.currentVersion),
            ),
            (l10n.updatesChannelLabel, state.channel),
          ],
        ),
        const SizedBox(height: 20),
        SetupToggleRow(
          toggleKey: const Key('settings_updatesAutoCheck_switch'),
          title: l10n.updatesAutoCheckTitle,
          subtitle: l10n.updatesAutoCheckSubtitle,
          value: state.autoCheck,
          onChanged: (on) => unawaited(cubit.setAutoCheck(value: on)),
        ),
        const SizedBox(height: 20),
        ..._statusArea(context, l10n, state, cubit),
      ],
    );
  }

  List<Widget> _statusArea(
    BuildContext context,
    AppLocalizations l10n,
    UpdateState state,
    UpdateCubit cubit,
  ) {
    switch (state.phase) {
      case UpdatePhase.checking:
        return [_progressLabel(context, l10n.updatesCheckingLabel)];
      case UpdatePhase.downloading:
        return [
          _progressLabel(
            context,
            l10n.updatesDownloadingLabel((state.progress * 100).round()),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('settings_updates_progress'),
              value: state.progress,
              minHeight: 6,
            ),
          ),
        ];
      case UpdatePhase.available:
        return _availableArea(l10n, state, cubit);
      case UpdatePhase.staged:
        return [
          SetupNavRow(
            rowKey: const Key('settings_updates_restart'),
            title: l10n.updatesStagedTitle,
            subtitle: state.available == null
                ? l10n.updatesRestartBusySubtitle
                : l10n.updatesStagedSubtitle(state.available!.version),
            icon: Icons.restart_alt,
            onTap: () => unawaited(_confirmRestart(context, cubit)),
          ),
        ];
      case UpdatePhase.error:
        return [
          SetupGroupLabel(l10n.updatesErrorTitle),
          const SizedBox(height: 8),
          if (state.errorMessage != null)
            Text(state.errorMessage!, style: setupBody),
          const SizedBox(height: 12),
          _checkNowRow(l10n, cubit),
        ];
      case UpdatePhase.upToDate:
        return [
          SetupGroupLabel(l10n.updatesUpToDateTitle),
          const SizedBox(height: 8),
          Text(l10n.updatesUpToDateSubtitle(state.channel), style: setupBody),
          const SizedBox(height: 12),
          _checkNowRow(l10n, cubit),
        ];
      case UpdatePhase.idle:
        return [_checkNowRow(l10n, cubit)];
    }
  }

  List<Widget> _availableArea(
    AppLocalizations l10n,
    UpdateState state,
    UpdateCubit cubit,
  ) {
    final manifest = state.available;
    if (manifest == null) return [_checkNowRow(l10n, cubit)];
    final notes = manifest.notes.isEmpty
        ? l10n.updatesNotesFallback
        : manifest.notes;
    return [
      SetupGroupLabel(l10n.updatesAvailableTitle(manifest.version)),
      const SizedBox(height: 8),
      Text(notes, style: setupBody),
      if (manifest.size > 0) ...[
        const SizedBox(height: 4),
        Text(l10n.updatesSizeMb(_mb(manifest.size)), style: setupBody),
      ],
      const SizedBox(height: 12),
      SetupNavRow(
        rowKey: const Key('settings_updates_download'),
        title: l10n.updatesDownloadTitle,
        subtitle: l10n.updatesDownloadSubtitle(manifest.version),
        icon: Icons.download,
        onTap: () => unawaited(cubit.startDownload()),
      ),
    ];
  }

  Widget _checkNowRow(AppLocalizations l10n, UpdateCubit cubit) => SetupNavRow(
    rowKey: const Key('settings_updates_checkNow'),
    title: l10n.updatesCheckNowTitle,
    subtitle: l10n.updatesCheckNowSubtitle,
    icon: Icons.refresh,
    onTap: () => unawaited(cubit.check()),
  );

  Widget _progressLabel(BuildContext context, String label) =>
      Text(label, style: setupBody);

  Future<void> _confirmRestart(BuildContext context, UpdateCubit cubit) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.updatesStagedTitle),
        content: Text(l10n.updatesRestartBusySubtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('settings_updates_restart_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.updatesStagedTitle),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await cubit.applyAndRestart();
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
}
