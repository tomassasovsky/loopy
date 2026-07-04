import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// The Tracks top bar: mode + bank controls on the left, and the global
/// transport / navigation actions on the right. Presentational — the enabled
/// flags and the mode / play-stop / clear callbacks come from the host view so
/// the keyboard path and the buttons dispatch through one shared place.
class TracksToolbar extends StatelessWidget {
  /// Creates a [TracksToolbar].
  const TracksToolbar({
    required this.mode,
    required this.activeBank,
    required this.anyActive,
    required this.playStopEnabled,
    required this.transportEnabled,
    required this.onToggleMode,
    required this.onPlayStopAll,
    required this.onClearAll,
    super.key,
  });

  /// The active system mode (drives the [ModeIndicator]).
  final LooperMode mode;

  /// The active bank index (drives the [BankSwitch]).
  final int activeBank;

  /// Whether any track is active — flips the Play/Stop All icon and tooltip.
  final bool anyActive;

  /// Whether the Play/Stop All control is enabled.
  final bool playStopEnabled;

  /// Whether the Clear All control is enabled.
  final bool transportEnabled;

  /// Invoked when the mode chip is tapped (shares the `M` key's dispatch).
  final VoidCallback onToggleMode;

  /// Invoked when the Play/Stop All control is pressed.
  final VoidCallback onPlayStopAll;

  /// Invoked when the Clear All control is pressed.
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        ModeIndicator(mode: mode, onToggle: onToggleMode),
        const SizedBox(width: 12),
        BankSwitch(active: activeBank),
        const Spacer(),
        // Play/Stop All — state-aware toggle mirroring `Space`.
        IconButton(
          key: const Key('tracks_playStopAll'),
          tooltip: anyActive ? l10n.stopAllTooltip : l10n.playAllTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          color: Colors.white70,
          icon: Icon(anyActive ? Icons.stop : Icons.play_arrow),
          onPressed: playStopEnabled ? onPlayStopAll : null,
        ),
        // Clear All — instant, mirroring `C`.
        IconButton(
          key: const Key('tracks_clearAll'),
          tooltip: l10n.clearAllTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          color: Colors.white70,
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: transportEnabled ? onClearAll : null,
        ),
        // Fullscreen — desktop only, mirroring `F`.
        if (loopySupportsDesktopWindowing)
          IconButton(
            key: const Key('tracks_fullscreen'),
            tooltip: l10n.fullscreenTooltip,
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            color: Colors.white70,
            icon: const Icon(Icons.fullscreen),
            onPressed: () => unawaited(toggleLoopyFullScreen()),
          ),
        IconButton(
          key: const Key('tracks_openSignal'),
          tooltip: l10n.signalTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          color: Colors.white70,
          icon: const Icon(Icons.account_tree_outlined),
          onPressed: () => unawaited(showSignalPage(context)),
        ),
        // Settings is also reachable by `S` or right-click; this surfaces it
        // for pointer/touch users.
        IconButton(
          key: const Key('tracks_openSettings'),
          tooltip: l10n.settingsTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          color: Colors.white70,
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => unawaited(openLoopySettings()),
        ),
        const SizedBox(width: 4),
        const SessionMenu(),
      ],
    );
  }
}

/// A full-width affordance shown when the engine isn't running (no first-run
/// gate exists anymore). Tapping it opens settings, where the engine can be
/// (re)started by choosing a device.
class AudioNotRunningBanner extends StatelessWidget {
  /// Creates an [AudioNotRunningBanner].
  const AudioNotRunningBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: const Key('tracks_audioNotRunning'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => unawaited(openLoopySettings()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(context.l10n.engineStoppedBanner)),
              const Icon(Icons.settings, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// A session action chosen from the [SessionMenu].
enum _SessionAction { save, load, exportMixdown, exportStems }

/// The session menu in the top bar: save / load the `.loopy` bundle and export
/// a mixdown or per-track stems. Drives the [SessionCubit]; outcomes are
/// surfaced by the view's [BlocListener] (a live-region SnackBar).
///
/// A [PopupMenuButton] is keyboard-operable and screen-reader labelled (via
/// its tooltip) out of the box, so it satisfies WCAG 2.1.1 / 4.1.2 without
/// extra wiring.
class SessionMenu extends StatelessWidget {
  /// Creates a [SessionMenu].
  const SessionMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<_SessionAction>(
      key: const Key('tracks_session_menu'),
      tooltip: l10n.a11ySessionMenu,
      icon: const Icon(Icons.folder_outlined, color: Colors.white70),
      onSelected: (action) {
        final cubit = context.read<SessionCubit>();
        switch (action) {
          case _SessionAction.save:
            unawaited(cubit.saveSession());
          case _SessionAction.load:
            unawaited(cubit.loadSession());
          case _SessionAction.exportMixdown:
            unawaited(cubit.exportMixdown());
          case _SessionAction.exportStems:
            unawaited(cubit.exportStems());
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('tracks_session_save'),
          value: _SessionAction.save,
          child: Text(l10n.saveSession),
        ),
        PopupMenuItem(
          key: const Key('tracks_session_load'),
          value: _SessionAction.load,
          child: Text(l10n.loadSession),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const Key('tracks_session_exportMixdown'),
          value: _SessionAction.exportMixdown,
          child: Text(l10n.exportMixdown),
        ),
        PopupMenuItem(
          key: const Key('tracks_session_exportStems'),
          value: _SessionAction.exportStems,
          child: Text(l10n.exportStems),
        ),
      ],
    );
  }
}

/// Shows the active system mode (REC / PLAY). Tap to toggle.
class ModeIndicator extends StatelessWidget {
  /// Creates a [ModeIndicator].
  const ModeIndicator({required this.mode, required this.onToggle, super.key});

  /// The mode to display.
  final LooperMode mode;

  /// Invoked on tap; the host wires this to the shared mode toggle (which
  /// also announces the landing mode to assistive tech).
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final recording = mode == LooperMode.record;
    final color = recording ? looper.recordColor : theme.colorScheme.primary;
    final modeName = recording ? l10n.looperModeRec : l10n.looperModePlay;

    return FocusableTapTarget(
      key: const Key('tracks_mode_indicator'),
      semanticLabel: l10n.a11yModeToggle(modeName),
      borderRadius: 10,
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              recording ? Icons.fiber_manual_record : Icons.play_arrow_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              modeName,
              style: theme.textTheme.labelLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small A | B segmented control for switching between the two track banks.
class BankSwitch extends StatelessWidget {
  /// Creates a [BankSwitch].
  const BankSwitch({required this.active, super.key});

  /// The index of the active bank (highlighted tab).
  final int active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final accent = theme.colorScheme.primary;
    final overlay = context.read<ControlCubit>();

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: looper.tileBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < ControlState.bankCount; i++)
            FocusableTapTarget(
              key: Key('tracks_bank_$i'),
              semanticLabel: context.l10n.a11yBankTab(
                String.fromCharCode(0x41 + i),
              ),
              selected: i == active,
              borderRadius: 8,
              onTap: () => overlay.browseBank(i),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: i == active ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  String.fromCharCode(0x41 + i),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: i == active ? Colors.black : Colors.white70,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
