import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';

/// Names a looper mode, and describes what it does in one line.
///
/// Beside the mode-change rule for the same reason: the Settings section and
/// the console's Loop face must say the same words for the same mode.
(String, String) looperModeLabels(AppLocalizations l10n, LooperMode mode) =>
    switch (mode) {
      LooperMode.multi => (l10n.looperModeMultiLabel, l10n.looperModeMultiSub),
      LooperMode.sync => (l10n.looperModeSyncLabel, l10n.looperModeSyncSub),
      LooperMode.song => (l10n.looperModeSongLabel, l10n.looperModeSongSub),
      LooperMode.band => (l10n.looperModeBandLabel, l10n.looperModeBandSub),
      LooperMode.free => (l10n.looperModeFreeLabel, l10n.looperModeFreeSub),
    };

/// Switches the looper mode, clearing first when there is content to lose.
///
/// Lives on its own so the Settings section and the console's Loop face drive
/// the SAME rule. The sequence below is load-bearing (D4): the clear only
/// POSTS an engine command, and dispatching the mode change before the bloc
/// reports cleared races the content lock — the engine can still see the
/// pre-clear content and silently drop the switch. A second copy of this in
/// the tray would be a second chance to get it subtly wrong.
Future<void> requestLooperModeChange(
  BuildContext context, {
  required LooperMode current,
  required LooperMode next,
}) async {
  if (next == current) return;
  final bloc = context.read<LooperBloc>();
  if (!bloc.state.hasContent) {
    bloc.add(LooperModeChanged(next));
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('looperMode_confirm_dialog'),
      title: Text(context.l10n.modeChangeConfirmTitle),
      content: Text(context.l10n.modeChangeConfirmBody),
      actions: [
        TextButton(
          key: const Key('looperMode_confirm_cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.l10n.modeChangeConfirmCancel),
        ),
        FilledButton(
          key: const Key('looperMode_confirm_confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(context.l10n.modeChangeConfirmConfirm),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;
  await context.read<ControlCubit>().clearAll();
  if (!context.mounted) return;
  // The clear above only POSTS the engine command; LooperBloc's state
  // reflects it once the next ~16 ms poll tick republishes the snapshot
  // (LooperRepository.pollInterval), not synchronously. Dispatching the
  // mode change before that lands would race the D4 content lock — the
  // engine could still see the pre-clear content and silently drop it,
  // exactly the silent no-op this flow exists to prevent. Wait for the
  // bloc to actually report cleared (bounded, so a stuck drain — e.g. a
  // capture mid-punch-out — can't hang the switch forever).
  if (bloc.state.hasContent) {
    await bloc.stream
        .firstWhere((s) => !s.hasContent)
        .timeout(const Duration(seconds: 2), onTimeout: () => bloc.state);
  }
  // Re-check rather than dispatching unconditionally: on the (rare) timeout
  // path above, content may still be present — dispatching anyway would
  // recreate the exact silent D4 no-op this whole flow exists to prevent.
  if (!bloc.state.hasContent) {
    bloc.add(LooperModeChanged(next));
    return;
  }
  // The confirm dialog is already gone (popped above) and the picker's own
  // state is unchanged, so without an explicit signal here the timeout is
  // indistinguishable from "my tap didn't register" — surface it with a
  // SnackBar (matching `tracks_commands.dart`'s `showSessionOutcome`
  // convention for other transient outcomes) so the user knows to retry
  // rather than silently getting nothing.
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        key: const Key('looperMode_timeout_snackbar'),
        content: Semantics(
          liveRegion: true,
          child: Text(context.l10n.modeChangeTimedOut),
        ),
      ),
    );
}
