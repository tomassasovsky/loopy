import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// The Updates tab of the console's System domain, drawn to `SYSTEM / update`
/// and its four states — `update-available`, `update-downloading`,
/// `update-staged`, `update-error`.
///
/// One banner carries the whole flow, its dot and its action changing with
/// the phase, because that is what the mockups draw: a rig that is up to date
/// and a rig that failed to check are the same row saying different things.
///
/// Nothing downloads until asked. The automatic switch looks; it never
/// fetches or installs — the subtitle says so and [UpdateCubit] enforces it.
class UpdatesSystemTab extends StatelessWidget {
  /// Creates an [UpdatesSystemTab].
  const UpdatesSystemTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<UpdateCubit>();
    final state = cubit.state;

    return KeyedSubtree(
      key: const Key('updates_system_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('system_version_row'),
                  title: l10n.systemInstalledVersion,
                  // `v` prefix from the same string Settings uses, so one rig
                  // never reads two ways.
                  value: state.currentVersion == null
                      ? l10n.emDash
                      : l10n.updatesVersionValue('${state.currentVersion}'),
                  showDisclosure: false,
                ),
                ConsoleRow(
                  key: const Key('system_channel_row'),
                  divider: false,
                  title: l10n.systemChannel,
                  value: state.channel,
                  showDisclosure: false,
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemAutomaticGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('system_autocheck_row'),
                  title: l10n.systemAutoCheckTitle,
                  subtitle: l10n.systemAutoCheckSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('system_autocheck_switch'),
                    value: state.autoCheck,
                    semanticLabel: l10n.systemAutoCheckTitle,
                    onChanged: (on) => unawaited(cubit.setAutoCheck(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('system_channel_switch_row'),
                  divider: false,
                  title: l10n.systemExperimentalTitle,
                  subtitle: l10n.systemExperimentalSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('system_experimental_switch'),
                    value: state.channel == 'experimental',
                    semanticLabel: l10n.systemExperimentalTitle,
                    onChanged: (on) =>
                        unawaited(cubit.setExperimentalChannel(value: on)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleCard(children: [_banner(context, cubit)]),
          ],
        ),
      ),
    );
  }

  /// The flow, in one strip: what the rig knows and what it offers to do.
  Widget _banner(BuildContext context, UpdateCubit cubit) {
    final l10n = context.l10n;
    final state = cubit.state;
    final offered = state.available == null
        ? ''
        : l10n.updatesVersionValue('${state.available!.version}');

    if (!state.supported) {
      return ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateUnsupported,
      );
    }
    return switch (state.phase) {
      UpdatePhase.checking => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateChecking,
      ),
      UpdatePhase.available => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateAvailable(offered),
        actionKey: const Key('system_update_action'),
        actionLabel: l10n.systemDownloadInstall,
        onAction: () => unawaited(cubit.startDownload()),
      ),
      UpdatePhase.downloading => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateDownloading(
          offered,
          (state.progress * 100).round(),
        ),
        progress: state.progress,
      ),
      UpdatePhase.staged => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateStaged(offered),
        settled: true,
        actionKey: const Key('system_update_action'),
        actionLabel: l10n.systemRestartNow,
        onAction: () => unawaited(cubit.applyAndRestart()),
      ),
      UpdatePhase.error => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: state.errorMessage ?? l10n.systemUpdateIdle,
        failed: true,
        actionKey: const Key('system_update_action'),
        actionLabel: l10n.networkTryAgainAction,
        onAction: () => unawaited(cubit.check()),
      ),
      // Checked, and there was nothing — the offer to check again stays, so
      // the row is never a dead end.
      UpdatePhase.upToDate => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateUpToDate,
        settled: true,
        actionKey: const Key('system_update_action'),
        actionLabel: l10n.systemCheckNow,
        onAction: () => unawaited(cubit.check()),
      ),
      UpdatePhase.idle => ConsoleBanner(
        key: const Key('system_update_banner'),
        message: l10n.systemUpdateIdle,
        settled: true,
        actionKey: const Key('system_update_action'),
        actionLabel: l10n.systemCheckNow,
        onAction: () => unawaited(cubit.check()),
      ),
    };
  }
}
