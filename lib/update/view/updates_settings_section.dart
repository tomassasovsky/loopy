import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// The "Updates" section of the settings surface: installed version + channel,
/// an auto-check toggle (governs only the read-only check), a persistent
/// "check now" row, and — once an update is known — a persistent action row
/// that evolves through available → downloading → staged. Rows stay on
/// screen across phase transitions; only their icon/subtitle/enabled state
/// changes, so the layout never jumps around mid-flow. Applying is always an
/// explicit, confirmed action — never automatic.
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
        Text(l10n.updatesIntro, style: context.setupBody),
        const SizedBox(height: 28),
        SetupInfoTable(
          rows: [
            (
              l10n.updatesInstalledVersionLabel,
              l10n.updatesVersionValue('${state.currentVersion ?? '—'}'),
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
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('settings_updatesExperimentalChannel_switch'),
          title: l10n.updatesExperimentalChannelTitle,
          subtitle: l10n.updatesExperimentalChannelSubtitle,
          value: state.channel == 'experimental',
          onChanged: state.phase == UpdatePhase.downloading
              ? (_) {}
              : (on) => unawaited(cubit.setExperimentalChannel(value: on)),
        ),
        const SizedBox(height: 20),
        _CheckNowRow(state: state, onTap: cubit.check),
        if (state.phase == UpdatePhase.error && state.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(state.errorMessage!, style: context.setupBody),
        ],
        if (state.available != null) ...[
          const SizedBox(height: 20),
          _UpdateActionRow(
            state: state,
            onDownload: cubit.startDownload,
            onRestart: () => unawaited(_confirmRestart(context, cubit)),
          ),
        ],
      ],
    );
  }

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
}

/// A small busy spinner sized to replace a [SetupNavRow]'s trailing icon.
const _spinner = SizedBox(
  width: 16,
  height: 16,
  child: CircularProgressIndicator(strokeWidth: 2),
);

/// The read-only "check for updates" row. Structurally present across every
/// phase — checking/idle/upToDate/error all render this SAME row, only its
/// subtitle and enabled/busy state change (never hidden or replaced).
class _CheckNowRow extends StatelessWidget {
  const _CheckNowRow({required this.state, required this.onTap});

  final UpdateState state;
  final Future<void> Function() onTap;

  bool get _busy =>
      state.phase == UpdatePhase.checking ||
      state.phase == UpdatePhase.downloading;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final subtitle = switch (state.phase) {
      UpdatePhase.checking => l10n.updatesCheckingLabel,
      UpdatePhase.upToDate => l10n.updatesUpToDateSubtitle(state.channel),
      _ => l10n.updatesCheckNowSubtitle,
    };
    return SetupNavRow(
      rowKey: const Key('settings_updates_checkNow'),
      title: l10n.updatesCheckNowTitle,
      subtitle: subtitle,
      icon: Icons.refresh,
      trailing: state.phase == UpdatePhase.checking ? _spinner : null,
      onTap: _busy ? null : () => unawaited(onTap()),
    );
  }
}

/// The single evolving action row for a known update: available (Download &
/// install) → downloading (progress) → staged (Restart to apply). Present
/// once [UpdateState.available] is non-null and stays on screen through the
/// whole lifecycle — only its icon/title/subtitle/enabled state and the
/// progress bar change.
class _UpdateActionRow extends StatelessWidget {
  const _UpdateActionRow({
    required this.state,
    required this.onDownload,
    required this.onRestart,
  });

  final UpdateState state;
  final Future<void> Function() onDownload;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final manifest = state.available;
    if (manifest == null) return const SizedBox.shrink();

    final notes = manifest.notes.isEmpty
        ? l10n.updatesNotesFallback
        : manifest.notes;
    final version = '${manifest.version}';

    final String title;
    final String subtitle;
    final IconData icon;
    final Widget? trailing;
    final VoidCallback? onTap;
    switch (state.phase) {
      case UpdatePhase.downloading:
        title = l10n.updatesDownloadTitle;
        subtitle = l10n.updatesDownloadingLabel((state.progress * 100).round());
        icon = Icons.download;
        trailing = _spinner;
        onTap = null;
      case UpdatePhase.staged:
        title = l10n.updatesStagedTitle;
        subtitle = l10n.updatesStagedSubtitle(version);
        icon = Icons.restart_alt;
        trailing = null;
        onTap = onRestart;
      // Only reachable when `state.available` is non-null, which in practice
      // means `available` here — the other cases are enumerated (rather than
      // a `default:`) so a new UpdatePhase value can't silently fall through.
      case UpdatePhase.idle:
      case UpdatePhase.checking:
      case UpdatePhase.upToDate:
      case UpdatePhase.available:
      case UpdatePhase.error:
        title = l10n.updatesDownloadTitle;
        subtitle = l10n.updatesDownloadSubtitle(version);
        icon = Icons.download;
        trailing = null;
        onTap = () => unawaited(onDownload());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SetupGroupLabel(l10n.updatesAvailableTitle(version)),
        const SizedBox(height: 8),
        Text(notes, style: context.setupBody),
        if (manifest.size > 0) ...[
          const SizedBox(height: 4),
          Text(
            l10n.updatesSizeMb(_mb(manifest.size)),
            style: context.setupBody,
          ),
        ],
        const SizedBox(height: 12),
        SetupNavRow(
          rowKey: const Key('settings_updates_action'),
          title: title,
          subtitle: subtitle,
          icon: icon,
          trailing: trailing,
          onTap: onTap,
        ),
        if (state.phase == UpdatePhase.downloading) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('settings_updates_progress'),
              value: state.progress,
              minHeight: 6,
            ),
          ),
        ],
      ],
    );
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
}
