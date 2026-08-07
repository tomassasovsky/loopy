import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';

/// The Storage tab: what is using the disk, and the two housekeeping actions.
///
/// Five readouts and two actions. The readouts are not a report — they are the
/// argument for the actions, which is what keeps this from being the kind of
/// tab that only tells you things.
///
/// **Deleting captures asks first**, like every destructive action on this
/// console, and afterwards the cubit **re-reads rather than guessing** at
/// what is left. **Nowhere to export to is a fact about the rig, not a
/// failure**: the row says "no USB volume" and stops being tappable, instead
/// of failing under a finger. And when the build cannot read the disk at all,
/// the whole breakdown is replaced by a card that says so — zeroes drawn as
/// facts would be worse than saying nothing.
class StorageSystemTab extends StatefulWidget {
  /// Creates a [StorageSystemTab].
  const StorageSystemTab({super.key});

  /// How old a capture has to be for the housekeeping action to take it.
  static const int retentionDays = 30;

  @override
  State<StorageSystemTab> createState() => _StorageSystemTabState();
}

class _StorageSystemTabState extends State<StorageSystemTab> {
  @override
  void initState() {
    super.initState();
    // Re-read on open: a USB stick may have arrived since the app started,
    // and captures may have been written by the session in between.
    unawaited(context.read<ConsoleFactsCubit>().load());
  }

  Future<void> _deleteCaptures() async {
    final l10n = context.l10n;
    final cubit = context.read<ConsoleFactsCubit>();
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.storageDeleteCapturesTitle,
      body: l10n.storageDeleteCapturesConfirmBody(
        StorageSystemTab.retentionDays,
      ),
      confirmLabel: l10n.storageDeleteCapturesConfirm,
    );
    if (!confirmed) return;
    await cubit.deleteCapturesOlderThan(StorageSystemTab.retentionDays);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ConsoleFactsCubit>().state;
    final usage = state.storage;
    final destination = state.exportDestination;
    final canExport = destination.isNotEmpty && !state.busy;

    return KeyedSubtree(
      key: const Key('system_storage_tab'),
      child: ConsoleFace(
        previewKey: const Key('system_storage_upcoming'),
        lastGroupExtent:
            ConsolePinnedGroupLabel.extent +
            kConsoleRowHeight * 2 +
            ConsoleCard.borderExtent,
        groups: [
          ConsoleGroup(
            caption: l10n.systemThisConsoleGroup,
            blocks: [
              if (!state.hasStorage)
                ConsoleEmptyCard(
                  key: const Key('system_storage_unknown'),
                  message: l10n.storageUnknown,
                )
              else
                ConsoleCard(
                  key: const Key('system_storage_card'),
                  children: [
                    _usageRow(
                      key: const Key('system_storage_sessions'),
                      title: l10n.storageSessionsTitle,
                      bytes: usage.sessionBytes,
                    ),
                    _usageRow(
                      key: const Key('system_storage_captures'),
                      title: l10n.storageCapturesTitle,
                      subtitle: l10n.storageCapturesSubtitle,
                      bytes: usage.captureBytes,
                    ),
                    _usageRow(
                      key: const Key('system_storage_plugins'),
                      title: l10n.storagePluginsTitle,
                      subtitle: l10n.storagePluginsSubtitle(usage.pluginCount),
                      bytes: usage.pluginBytes,
                    ),
                    _usageRow(
                      key: const Key('system_storage_system'),
                      title: l10n.storageSystemTitle,
                      subtitle: l10n.storageSystemSubtitle,
                      bytes: usage.systemBytes,
                    ),
                    _usageRow(
                      key: const Key('system_storage_free'),
                      title: l10n.storageFreeTitle,
                      bytes: usage.freeBytes,
                      showDivider: false,
                    ),
                  ],
                ),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemHousekeepingGroup,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('system_storage_delete_captures'),
                    title: l10n.storageDeleteCapturesTitle,
                    subtitle: l10n.storageDeleteCapturesSubtitle(
                      StorageSystemTab.retentionDays,
                    ),
                    expanded: false,
                    onTap: state.hasStorage && !state.busy
                        ? () => unawaited(_deleteCaptures())
                        : null,
                  ),
                  ConsoleRow(
                    key: const Key('system_storage_export'),
                    title: l10n.storageExportTitle,
                    // Not a failure and not an error tone: there being no
                    // stick in the slot is a fact about the rig right now.
                    state: destination.isEmpty ? l10n.storageNoUsb : null,
                    value: destination.isEmpty ? null : destination,
                    // No marker when there is nowhere to go: the gutter stays
                    // (the row above reserves it for the group) but the row
                    // stops claiming it does something.
                    expanded: destination.isEmpty ? null : false,
                    showDivider: false,
                    onTap: canExport
                        ? () => unawaited(
                            context
                                .read<ConsoleFactsCubit>()
                                .exportEverything(),
                          )
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One line of the breakdown: what it is, and how much of the disk it is.
  ///
  /// The figure goes in [ConsoleRow.value] rather than `state`: `41.6 GB` is a
  /// quantity a person reads, not a machine word about the row.
  Widget _usageRow({
    required Key key,
    required String title,
    required int bytes,
    String? subtitle,
    bool showDivider = true,
  }) => ConsoleRow(
    key: key,
    title: title,
    subtitle: subtitle,
    value: context.l10n.storageGigabytes(_gigabytes(bytes)),
    showDisclosure: false,
    showDivider: showDivider,
  );

  /// Bytes as the GB figure the mockups print, to one decimal.
  ///
  /// Decimal gigabytes, not gibibytes: this is the number printed on the disk
  /// and quoted by every other appliance, and a "12.4 GB free" that disagrees
  /// with the sticker is a bug report.
  static String _gigabytes(int bytes) =>
      (bytes / 1000000000).toStringAsFixed(1);
}
