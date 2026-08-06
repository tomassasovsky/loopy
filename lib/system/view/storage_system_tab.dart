import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';

/// How old a capture has to be before the housekeeping action offers to
/// delete it, as the mockups state it.
const int kOldCaptureDays = 30;

/// The Storage tab of the console's System domain, drawn to `SYSTEM / storage`:
/// what is using the disk, and the two housekeeping actions.
class StorageSystemTab extends StatelessWidget {
  /// Creates a [StorageSystemTab].
  const StorageSystemTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<ConsoleFactsCubit>();
    final usage = cubit.state.usage;

    return KeyedSubtree(
      key: const Key('storage_system_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.systemThisConsoleGroup),
            const SizedBox(height: 10),
            if (!usage.known)
              // Zeroes drawn as facts would be worse than saying nothing: a
              // desktop build has no appliance disk to account for.
              ConsoleEmptyCard(message: l10n.systemStorageUnknown)
            else
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('storage_sessions'),
                    title: l10n.systemStorageSessions,
                    value: _gb(l10n, usage.sessions),
                    showDisclosure: false,
                  ),
                  ConsoleRow(
                    key: const Key('storage_captures'),
                    title: l10n.systemStorageCaptures,
                    subtitle: l10n.systemStorageCapturesSub,
                    value: _gb(l10n, usage.captures),
                    showDisclosure: false,
                  ),
                  ConsoleRow(
                    key: const Key('storage_plugins'),
                    title: l10n.systemStoragePlugins,
                    subtitle: l10n.systemStoragePluginsSub(usage.pluginCount),
                    value: _gb(l10n, usage.plugins),
                    showDisclosure: false,
                  ),
                  ConsoleRow(
                    key: const Key('storage_system'),
                    title: l10n.systemStorageSystem,
                    subtitle: l10n.systemStorageSystemSub,
                    value: _gb(l10n, usage.system),
                    showDisclosure: false,
                  ),
                  ConsoleRow(
                    key: const Key('storage_free'),
                    divider: false,
                    title: l10n.systemStorageFree,
                    value: _gb(l10n, usage.free),
                    showDisclosure: false,
                  ),
                ],
              ),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemHousekeepingGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('storage_delete_old'),
                  title: l10n.systemDeleteOldCaptures,
                  subtitle: l10n.systemDeleteOldCapturesSub(kOldCaptureDays),
                  // Deleting recordings asks first, like every destructive
                  // action on the console does.
                  onTap: cubit.state.busy || !usage.known
                      ? null
                      : () => unawaited(_confirmDelete(context, cubit)),
                ),
                ConsoleRow(
                  key: const Key('storage_export_usb'),
                  divider: false,
                  title: l10n.systemExportUsb,
                  // Nowhere to export to is a fact about the rig, not a
                  // failure — the row says so instead of failing on tap.
                  value: cubit.state.canExport
                      ? null
                      : l10n.systemExportUsbNoTarget,
                  onTap: cubit.state.canExport ? () {} : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ConsoleFactsCubit cubit,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showConsoleForgetDialog(
      context,
      title: l10n.systemDeleteOldCaptures,
      body: l10n.systemDeleteOldCapturesSub(kOldCaptureDays),
      confirmKey: const Key('storage_delete_confirm'),
      confirmLabel: l10n.systemDeleteOldCaptures,
    );
    if (!confirmed) return;
    await cubit.deleteCapturesOlderThan(kOldCaptureDays);
  }

  static String _gb(AppLocalizations l10n, int bytes) {
    const gb = 1024 * 1024 * 1024;
    return l10n.systemGigabytes((bytes / gb).toStringAsFixed(1));
  }
}
