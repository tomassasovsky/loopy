import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The looper feature's own mode-picker settings surface (index plan's UI
/// conventions — same "lives in the looper feature, not `audio_setup`"
/// posture as `TempoSettingsSection`): the five-mode axis
/// (Multi/Sync/Song/Band/Free, D4).
///
/// Mode is read live from [LooperBloc]'s `TransportState` (like
/// `TempoSettingsSection` reads tempo/click state), so a controller/pedal- or
/// session-load-driven mode change shows up immediately with no second cache.
///
/// D4 UX: switching mode while any track has content would otherwise be a
/// SILENT no-op (the engine rejects it, D4's content lock) — this section
/// never lets that happen. Selecting a different mode while
/// [LooperState.hasContent] shows an explicit confirmation dialog
/// (confirm-then-clear-then-switch); selecting the mode already active, or
/// switching with nothing recorded, applies immediately.
class LooperModeSection extends StatelessWidget {
  /// Creates a [LooperModeSection].
  const LooperModeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looperState = context.watch<LooperBloc>().state;
    final mode = looperState.transport.looperMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.looperModeIntro, style: setupBody),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.looperModeGroupLabel),
        const SizedBox(height: 12),
        _ModePicker(
          selected: mode,
          onSelected: (next) => unawaited(
            _requestModeChange(context, current: mode, next: next),
          ),
        ),
      ],
    );
  }

  /// Applies [next] directly when it is already selected or nothing would be
  /// lost; otherwise shows the D4 clear-all confirmation and only proceeds —
  /// clear, then switch — on an explicit confirm. Never dispatches the mode
  /// change without either condition holding, so the engine's silent D4
  /// no-op can never surface as a picker that "did nothing" for no visible
  /// reason — and on the (rare) bounded-wait timeout, where the dispatch is
  /// withheld for the same reason, a SnackBar makes that outcome visible too
  /// (independent review of #295: the confirm dialog is already dismissed by
  /// then, so without it the timeout looked identical to a tap that never
  /// registered).
  static Future<void> _requestModeChange(
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
}

/// The five-mode selector (Multi/Sync/Song/Band/Free).
class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.selected, required this.onSelected});

  final LooperMode selected;
  final ValueChanged<LooperMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      LooperMode.multi: (l10n.looperModeMultiLabel, l10n.looperModeMultiSub),
      LooperMode.sync: (l10n.looperModeSyncLabel, l10n.looperModeSyncSub),
      LooperMode.song: (l10n.looperModeSongLabel, l10n.looperModeSongSub),
      LooperMode.band: (l10n.looperModeBandLabel, l10n.looperModeBandSub),
      LooperMode.free: (l10n.looperModeFreeLabel, l10n.looperModeFreeSub),
    };
    return SetupOptionRow<LooperMode>(
      selected: selected,
      onSelected: onSelected,
      options: [
        for (final mode in LooperMode.values)
          SetupOption(
            value: mode,
            label: labels[mode]!.$1,
            sub: labels[mode]!.$2,
            optionKey: Key('looperMode_option_${mode.name}'),
          ),
      ],
    );
  }
}
