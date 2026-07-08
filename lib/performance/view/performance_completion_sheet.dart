import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows the [PerformanceCompletionSheet] for the live
/// [PerformanceRecorderCubit] (read from [context]), handed down through the
/// sheet route the same way `showSessionsManager` hands `SessionCubit` to
/// its dialog.
Future<void> showPerformanceCompletionSheet(BuildContext context) async {
  final cubit = context.read<PerformanceRecorderCubit>();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider<PerformanceRecorderCubit>.value(
      value: cubit,
      child: const PerformanceCompletionSheet(),
    ),
  );
}

/// A finished capture's outcome (done / partial / stopped-early) plus
/// platform-aware reveal and rename actions. Watches
/// [PerformanceRecorderCubit] directly (rather than taking the result as a
/// constructor param) so a rename mid-sheet updates the displayed path
/// immediately.
class PerformanceCompletionSheet extends StatelessWidget {
  /// Creates a [PerformanceCompletionSheet].
  const PerformanceCompletionSheet({super.key});

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  static String _revealLabel(AppLocalizations l10n) {
    if (Platform.isMacOS) return l10n.perfRevealMacos;
    if (Platform.isWindows) return l10n.perfRevealWindows;
    return l10n.perfRevealOther;
  }

  Future<void> _reveal(String path) => launchUrl(Uri.directory(path));

  Future<void> _rename(BuildContext context, String path) async {
    final cubit = context.read<PerformanceRecorderCubit>();
    final l10n = context.l10n;
    final to = await showDialog<String>(
      context: context,
      builder: (_) => _RenameCaptureDialog(initial: _basename(path)),
    );
    if (to == null) return;
    // Only the collision is catchable here: `_RenameCaptureDialogState._submit`
    // pre-validates with the same `performanceCaptureSlug` the repository
    // itself folds `to` through, so the other failure mode
    // (`renameCapture`'s `ArgumentError` for a name that folds to nothing) is
    // structurally unreachable from this call site.
    try {
      await cubit.renameCompletedCapture(to);
    } on PerformanceNameCollision catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.perfRenameDuplicate(e.slug))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PerformanceRecorderCubit>().state;
    if (state is! PerformanceRecorderCompleted || state.result == null) {
      return const SizedBox.shrink();
    }
    final result = state.result!;
    final path = switch (result) {
      PerformanceRecordDone(:final path) => path,
      PerformanceRecordPartial(:final path) => path,
      PerformanceRecordStoppedEarly(:final path) => path,
    };
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final message = switch (result) {
      PerformanceRecordDone() => null,
      PerformanceRecordPartial() => l10n.perfPartial,
      PerformanceRecordStoppedEarly(:final reason) => switch (reason) {
        PerformanceStopReason.diskFull => l10n.perfStoppedDiskFull,
        PerformanceStopReason.deviceChanged => l10n.perfStoppedDeviceChange,
      },
    };

    return SafeArea(
      child: Padding(
        key: const Key('perfCompletion_sheet'),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.perfDone, style: theme.textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message),
            ],
            const SizedBox(height: 4),
            Text(_basename(path), style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton.icon(
                  key: const Key('perfCompletion_reveal'),
                  onPressed: () => unawaited(_reveal(path)),
                  icon: const Icon(Icons.folder_open),
                  label: Text(_revealLabel(l10n)),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const Key('perfCompletion_rename'),
                  onPressed: () => unawaited(_rename(context, path)),
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: Text(l10n.perfRenameButton),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('perfCompletion_close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.done),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameCaptureDialog extends StatefulWidget {
  const _RenameCaptureDialog({required this.initial});

  final String initial;

  @override
  State<_RenameCaptureDialog> createState() => _RenameCaptureDialogState();
}

class _RenameCaptureDialogState extends State<_RenameCaptureDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final raw = _controller.text;
    if (performanceCaptureSlug(raw) == null) {
      setState(() => _error = l10n.perfRenameInvalid);
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.perfRenameTitle),
      content: TextField(
        key: const Key('perfRename_field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: l10n.perfRenameHint,
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('perfRename_save'),
          onPressed: _submit,
          child: Text(l10n.perfRenameButton),
        ),
      ],
    );
  }
}
