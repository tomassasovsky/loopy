import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';

/// Shows a dialog to rename track [channel] (current name [current]) and
/// persists the result through [cubit]. Shared by the Big Picture grid and the
/// settings page so the rename UX stays in one place.
Future<void> showRenameTrackDialog({
  required BuildContext context,
  required BigPictureCubit cubit,
  required int channel,
  required String current,
}) async {
  final l10n = context.l10n;
  final controller = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.renameTrackTitle(channel + 1)),
      content: TextField(
        key: const Key('renameTrack_field'),
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('renameTrack_save'),
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: Text(l10n.save),
        ),
      ],
    ),
  );
  if (result != null) {
    final trimmed = result.trim();
    if (trimmed.isNotEmpty) await cubit.rename(channel, trimmed);
  }
}
