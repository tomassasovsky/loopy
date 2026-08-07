import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';

/// The five looper modes, each with the one-liner that makes it choosable.
///
/// One table, called by both the Settings section and the console's Mode face.
/// Two copies would be two chances for the two surfaces to describe the same
/// mode differently — and a picker of five bare names ("Multi", "Band") asks
/// the reader to already know the answer, so the one-liner is not decoration.
Map<LooperMode, ({String label, String sub})> looperModeLabels(
  AppLocalizations l10n,
) => {
  LooperMode.multi: (
    label: l10n.looperModeMultiLabel,
    sub: l10n.looperModeMultiSub,
  ),
  LooperMode.sync: (
    label: l10n.looperModeSyncLabel,
    sub: l10n.looperModeSyncSub,
  ),
  LooperMode.song: (
    label: l10n.looperModeSongLabel,
    sub: l10n.looperModeSongSub,
  ),
  LooperMode.band: (
    label: l10n.looperModeBandLabel,
    sub: l10n.looperModeBandSub,
  ),
  LooperMode.free: (
    label: l10n.looperModeFreeLabel,
    sub: l10n.looperModeFreeSub,
  ),
};

/// Switches the looper to [next], clearing first when the session has content.
///
/// **The D4 sequence, and the only implementation of it.** Switching mode with
/// content in the session is rejected by the engine as a SILENT no-op, so this
/// never dispatches into that: it confirms, clears, waits for the bloc to
/// *report* cleared, and only then switches. A second copy of the sequence in
/// the console tray would be a second chance to get the silent no-op subtly
/// wrong, so `LooperModeSection` and the Loop face both call this.
///
/// Resolves **true** when the change was dispatched, so a caller can shut its
/// chooser on the way through and leave it open when the confirm was declined
/// — which is what `LOOP / settings-mode-confirm` draws: the mode list is
/// still open behind the dialog.
///
/// Needs [LooperBloc] and [ControlCubit] on [context].
Future<bool> requestLooperModeChange(
  BuildContext context, {
  required LooperMode current,
  required LooperMode next,
}) async {
  if (next == current) return false;
  final l10n = context.l10n;
  final bloc = context.read<LooperBloc>();
  if (!bloc.state.hasContent) {
    bloc.add(LooperModeChanged(next));
    return true;
  }
  final confirmed = await showConsoleConfirmDialog(
    context,
    title: l10n.modeChangeConfirmTitle,
    body: l10n.modeChangeConfirmBody,
    confirmLabel: l10n.modeChangeConfirmConfirm,
    cancelLabel: l10n.modeChangeConfirmCancel,
  );
  if (!confirmed) return false;
  if (!context.mounted) return false;
  await context.read<ControlCubit>().clearAll();
  if (!context.mounted) return false;
  // The clear above only POSTS the engine command; LooperBloc's state reflects
  // it once the next ~16 ms poll tick republishes the snapshot
  // (LooperRepository.pollInterval), not synchronously. Dispatching the mode
  // change before that lands would race the D4 content lock — the engine could
  // still see the pre-clear content and silently drop it, exactly the silent
  // no-op this flow exists to prevent. Wait for the bloc to actually report
  // cleared (bounded, so a stuck drain — e.g. a capture mid-punch-out — cannot
  // hang the switch forever).
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
    return true;
  }
  // The confirm dialog is already gone and the picker's own state is
  // unchanged, so without an explicit signal here the timeout is
  // indistinguishable from "my tap didn't register" — surface it with a
  // SnackBar (matching `tracks_commands.dart`'s `showSessionOutcome`
  // convention for other transient outcomes) so the user knows to retry rather
  // than silently getting nothing.
  if (!context.mounted) return false;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        key: const Key('looperMode_timeout_snackbar'),
        content: Semantics(
          liveRegion: true,
          child: Text(l10n.modeChangeTimedOut),
        ),
      ),
    );
  return false;
}
