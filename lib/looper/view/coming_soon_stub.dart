import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';

/// Shows a shared placeholder for a settings-tray feature with no real
/// functionality yet (Tuner). Dismissed by tap-outside or the close button;
/// the tray stays open underneath — this isn't a real navigation, so nothing
/// auto-closes it.
Future<void> showComingSoonStub(
  BuildContext context, {
  required String feature,
}) {
  final l10n = context.l10n;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('comingSoonStub_dialog'),
      content: Text(l10n.trayComingSoonMessage(feature)),
      actions: [
        TextButton(
          key: const Key('comingSoonStub_close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}
