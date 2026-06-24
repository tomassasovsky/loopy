import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/cubit/track_indicators_cubit.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// The full-screen "Big Picture" performance view (Chewie-Monsta style): a row
/// of tall colored track columns, each a level meter with an editable name.
/// Tapping a column selects it (white highlight) and toggles record/overdub;
/// long-press stops. The master output waveform is in a separate window.
class BigPictureView extends StatefulWidget {
  /// Creates a [BigPictureView].
  const BigPictureView({super.key});

  @override
  State<BigPictureView> createState() => _BigPictureViewState();
}

class _BigPictureViewState extends State<BigPictureView> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LooperBloc>().state;
    final big = context.watch<BigPictureCubit>().state;
    final bank = context.watch<BankCubit>().state;
    final tracks = [
      for (final track in state.tracks)
        if (bank.contains(track.channel)) track,
    ];

    // Settings are reachable from the performance view by right-clicking
    // anywhere or pressing `S` (and from the macOS menu bar). Kept chromeless
    // and minimal otherwise.
    return BlocListener<SessionCubit, SessionState>(
      // Only react to a settled action — a save/load/export that finished or
      // failed — never the transient `working` tick.
      listenWhen: (previous, current) =>
          current.status != previous.status &&
          (current.status == SessionStatus.success ||
              current.status == SessionStatus.failure),
      listener: _showSessionOutcome,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          key: const Key('bigpicture_settings_secondaryTap'),
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (_) => unawaited(openLoopySettings()),
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _ModeIndicator(mode: big.mode),
                        const SizedBox(width: 12),
                        _BankSwitch(active: bank.activeBank),
                        const Spacer(),
                        IconButton(
                          key: const Key('bigpicture_openSignal'),
                          tooltip: context.l10n.signalTooltip,
                          visualDensity: VisualDensity.compact,
                          iconSize: 20,
                          color: Colors.white70,
                          icon: const Icon(Icons.account_tree_outlined),
                          onPressed: () => unawaited(showSignalPage(context)),
                        ),
                        const SizedBox(width: 4),
                        const _SessionMenu(),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // With no first-run gate, a stopped engine lands here; a
                    // full-width affordance opens settings to (re)start it.
                    if (!state.status.isConnected) ...[
                      const _AudioNotRunningBanner(),
                      const SizedBox(height: 14),
                    ],
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final track in tracks)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: _TrackColumn(
                                    track: track,
                                    name: context.l10n.displayTrackName(
                                      big.nameOf(track.channel),
                                      track.channel,
                                    ),
                                    selected:
                                        track.channel == big.selectedChannel,
                                    playMode: big.mode == PerformanceMode.play,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Shows a transient SnackBar surfacing the last session action's outcome —
  /// a localized success line, or a localized, human-readable error for the
  /// known refusals (sample-rate mismatch, newer manifest version), falling
  /// back to the raw message otherwise. The content is a live region so it is
  /// announced to assistive tech as it appears (WCAG 4.1.3).
  void _showSessionOutcome(BuildContext context, SessionState state) {
    final l10n = context.l10n;
    final message = switch (state.status) {
      SessionStatus.success => switch (state.outcome) {
        SessionOutcome.saved => l10n.sessionSaved,
        SessionOutcome.loaded => l10n.sessionLoaded,
        SessionOutcome.mixdownExported => l10n.mixdownExported,
        SessionOutcome.stemsExported => l10n.stemsExported,
        null => null,
      },
      SessionStatus.failure => switch (state.error) {
        SessionError.sampleRateMismatch => l10n.sessionErrorSampleRate,
        SessionError.unsupportedVersion => l10n.sessionErrorUnsupportedVersion,
        SessionError.unknown ||
        null => l10n.sessionErrorGeneric(state.errorMessage ?? ''),
      },
      SessionStatus.idle || SessionStatus.working => null,
    };
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          key: const Key('bigpicture_session_snackbar'),
          content: Semantics(liveRegion: true, child: Text(message)),
        ),
      );
  }

  /// The performance keyboard map. Plain keys are consumed (so macOS does not
  /// beep) and dispatched to the looper; modifier combos other than undo/redo
  /// pass through to OS / menu shortcuts.
  ///
  /// Both modes: `M` switch mode · `S` settings · `G` signal · `F` fullscreen ·
  /// `Space` play/pause all · `C` clear all · `Cmd/Ctrl+Z` undo · `Cmd/Ctrl+Y`
  /// (or `Shift+Z`) redo.
  /// Record mode: `1`–`8` select · `R` record/overdub · `P` play/pause.
  /// Play mode: `1`–`8` select + mute/unmute.
  /// Announces a transient state change to assistive tech (WCAG 4.1.3). The
  /// performance surface is otherwise silent — state lives in colour and meter
  /// fills a screen-reader cannot perceive.
  void _announce(String message) {
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Let Tab / Shift+Tab fall through so keyboard focus can traverse into the
    // interactive track tiles, mode toggle, and bank switch (WCAG 2.1.2 / 2.4.3)
    // — otherwise the catch-all "swallow plain keys" below would trap focus.
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final bloc = context.read<LooperBloc>();
    final big = context.read<BigPictureCubit>();
    final l10n = context.l10n;
    final selected = big.state.selectedChannel;
    final playing = bloc.state.tracks
        .map((t) => t.state)
        .toList()
        .any(
          (t) => [
            TrackState.playing,
            TrackState.overdubbing,
            TrackState.recording,
          ].contains(t),
        );

    if (keyboard.isMetaPressed || keyboard.isControlPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (keyboard.isShiftPressed) {
          bloc.add(LooperRedoPressed(selected));
          _announce(l10n.a11yRedone);
        } else {
          bloc.add(LooperUndoPressed(selected));
          _announce(l10n.a11yUndone);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        bloc.add(LooperRedoPressed(selected));
        _announce(l10n.a11yRedone);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // let OS / menu shortcuts through
    }

    // Common to both modes.
    if (key == LogicalKeyboardKey.keyM) {
      big.toggleMode();
      _announce(
        big.state.mode == PerformanceMode.record
            ? l10n.a11yModeRecord
            : l10n.a11yModePlay,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(openLoopySettings());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyG) {
      unawaited(showSignalPage(context));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      unawaited(toggleLoopyFullScreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      bloc.add(
        playing ? const LooperStopAllPressed() : const LooperPlayAllPressed(),
      );
      _announce(playing ? l10n.a11yStoppedAll : l10n.a11yPlayingAll);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      bloc.add(const LooperClearAllPressed());
      _announce(l10n.a11yAllCleared);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      final currentBank = context.read<BankCubit>().state.activeBank;
      final nextBank = currentBank == 0 ? 1 : 0;
      context.read<BankCubit>().selectBank(nextBank);
      context.read<BigPictureCubit>().select(currentBank == 0 ? 4 : 0);
      _announce(l10n.a11yBankSelected(String.fromCharCode(0x41 + nextBank)));
      return KeyEventResult.handled;
    }
    // `U` undoes the latest overdub layer; on a track that holds only its base
    // loop (nothing to undo) it clears the track instead. The bloc decides.
    if (key == LogicalKeyboardKey.keyU) {
      context.read<LooperBloc>().add(LooperUndoPressed(selected));
      _announce(l10n.a11yUndone);
      return KeyEventResult.handled;
    }

    // Number keys 1–8 select a track (auto-revealing its bank). In play mode
    // they also toggle mute on that track.
    final digit = _digitOf(key);
    if (digit != null) {
      final channel = digit - 1;
      if (channel <= 7) {
        context.read<BankCubit>().selectBank(
          channel ~/ BankState.tracksPerBank,
        );
        big.select(channel);
        if (big.state.mode == PerformanceMode.play) {
          bloc.add(LooperMuteToggled(channel));
        }
      }
      return KeyEventResult.handled;
    }

    // Record-mode actions on the selected track.
    if (big.state.mode == PerformanceMode.record) {
      if (key == LogicalKeyboardKey.keyR) {
        bloc.add(LooperRecordPressed(selected));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyP) {
        final track = bloc.state.tracks.firstWhere(
          (t) => t.channel == selected,
          orElse: () => const Track(),
        );
        final playing =
            track.state == TrackState.playing ||
            track.state == TrackState.overdubbing ||
            track.state == TrackState.recording;
        bloc.add(
          playing ? LooperStopPressed(selected) : LooperPlayPressed(selected),
        );
        _announce(playing ? l10n.a11yStopped : l10n.a11yPlaying);
        return KeyEventResult.handled;
      }
    }

    // Swallow other plain keys so macOS does not beep.
    return KeyEventResult.handled;
  }

  /// Maps a `1`–`8` digit key to its number, or `null`. Digit keys have
  /// sequential key ids (ASCII `'1'`–`'8'`), so a range check avoids a map
  /// keyed on the (non-primitive-equality) [LogicalKeyboardKey].
  int? _digitOf(LogicalKeyboardKey key) {
    final id = key.keyId;
    if (id >= LogicalKeyboardKey.digit1.keyId &&
        id <= LogicalKeyboardKey.digit8.keyId) {
      return id - LogicalKeyboardKey.digit0.keyId;
    }
    return null;
  }
}

/// A full-width affordance shown when the engine isn't running (no first-run
/// gate exists anymore). Tapping it opens settings, where the engine can be
/// (re)started by choosing a device.
class _AudioNotRunningBanner extends StatelessWidget {
  const _AudioNotRunningBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: const Key('bigpicture_audioNotRunning'),
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

/// A session action chosen from the [_SessionMenu].
enum _SessionAction { save, load, exportMixdown, exportStems }

/// The session menu in the top bar: save / load the `.loopy` bundle and export
/// a mixdown or per-track stems. Drives the [SessionCubit]; outcomes are
/// surfaced by the view's [BlocListener] (a live-region SnackBar).
///
/// A [PopupMenuButton] is keyboard-operable and screen-reader labelled (via
/// its tooltip) out of the box, so it satisfies WCAG 2.1.1 / 4.1.2 without
/// extra wiring.
class _SessionMenu extends StatelessWidget {
  const _SessionMenu();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<_SessionAction>(
      key: const Key('bigpicture_session_menu'),
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
          key: const Key('bigpicture_session_save'),
          value: _SessionAction.save,
          child: Text(l10n.saveSession),
        ),
        PopupMenuItem(
          key: const Key('bigpicture_session_load'),
          value: _SessionAction.load,
          child: Text(l10n.loadSession),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const Key('bigpicture_session_exportMixdown'),
          value: _SessionAction.exportMixdown,
          child: Text(l10n.exportMixdown),
        ),
        PopupMenuItem(
          key: const Key('bigpicture_session_exportStems'),
          value: _SessionAction.exportStems,
          child: Text(l10n.exportStems),
        ),
      ],
    );
  }
}

/// Shows the active performance mode (REC / PLAY). Tap to toggle.
class _ModeIndicator extends StatelessWidget {
  const _ModeIndicator({required this.mode});

  final PerformanceMode mode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final recording = mode == PerformanceMode.record;
    final color = recording ? looper.recordColor : theme.colorScheme.primary;
    final modeName = recording
        ? l10n.performanceModeRec
        : l10n.performanceModePlay;

    return FocusableTapTarget(
      key: const Key('bigpicture_mode_indicator'),
      semanticLabel: l10n.a11yModeToggle(modeName),
      borderRadius: 10,
      onTap: () {
        final cubit = context.read<BigPictureCubit>()..toggleMode();
        unawaited(
          SemanticsService.sendAnnouncement(
            View.of(context),
            cubit.state.mode == PerformanceMode.record
                ? l10n.a11yModeRecord
                : l10n.a11yModePlay,
            Directionality.of(context),
          ),
        );
      },
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
class _BankSwitch extends StatelessWidget {
  const _BankSwitch({required this.active});

  final int active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final accent = theme.colorScheme.primary;
    final cubit = context.read<BankCubit>();

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
          for (var i = 0; i < BankState.bankCountMax; i++)
            FocusableTapTarget(
              key: Key('bigpicture_bank_$i'),
              semanticLabel: context.l10n.a11yBankTab(
                String.fromCharCode(0x41 + i),
              ),
              selected: i == active,
              borderRadius: 8,
              onTap: () => cubit.selectBank(i),
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

class _TrackColumn extends StatelessWidget {
  const _TrackColumn({
    required this.track,
    required this.name,
    required this.selected,
    required this.playMode,
  });

  final Track track;
  final String name;
  final bool selected;
  final bool playMode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final bloc = context.read<LooperBloc>();

    // The border is always white; selection only changes its weight. The meter
    // bar color is one table lookup on the track's meter state (muted included;
    // see LooperTheme.meterColors).
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final barColor = looper.meterColor(meterState, playMode: playMode);
    // The meter conveys state through colour only (WCAG 1.4.1); name the state
    // in words so it reaches the tile's accessible label.
    final stateWord = switch (meterState) {
      LooperMeterState.empty => l10n.trackStateEmpty,
      LooperMeterState.recording => l10n.trackStateRecording,
      LooperMeterState.overdubbing => l10n.trackStateOverdubbing,
      LooperMeterState.playing => l10n.trackStatePlaying,
      LooperMeterState.stopped => l10n.trackStateStopped,
      LooperMeterState.muted => l10n.trackStateMuted,
    };

    return Container(
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: 3,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${track.channel + 1}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const Spacer(),
              if (track.isMultiple)
                Text(
                  l10n.loopMultipleLabel(track.multiple),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          Expanded(
            child: FocusableTapTarget(
              key: Key('bigpicture_tile_${track.channel}'),
              semanticLabel: l10n.a11yTrackTile(name, stateWord),
              selected: selected,
              borderRadius: 8,
              onTap: () {
                context.read<BigPictureCubit>().select(track.channel);
                bloc.add(LooperRecordPressed(track.channel));
              },
              child: GestureDetector(
                key: Key('bigpicture_tileStop_${track.channel}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
                child: _PeakBar(
                  peak: track.peak,
                  color: barColor,
                  hasContent: track.hasContent,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          FocusableTapTarget(
            key: Key('bigpicture_name_${track.channel}'),
            semanticLabel: l10n.a11yRenameTrack(name),
            onTap: () => showRenameTrackDialog(
              context: context,
              cubit: context.read<BigPictureCubit>(),
              channel: track.channel,
              current: name,
            ),
            child: Text(
              name,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
          // A discrete arm/readiness strip, shown only when the view preference
          // is on. When off the widget is absent and the tile reflows.
          if (context.watch<TrackIndicatorsCubit>().state) ...[
            const SizedBox(height: 6),
            _TrackIndicator(
              key: Key('bigpicture_indicator_${track.channel}'),
              status: TrackIndicator.of(
                track.state,
                muted: track.muted,
                selected: selected,
                playMode: playMode,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A static, full-width status strip below a track name. Its colour is the
/// track's [TrackIndicator] state. Carries no semantics of its own
/// ([ExcludeSemantics]): the tile already names its state for screen readers,
/// so a second label here would double-announce. Static colour ⇒ no motion.
class _TrackIndicator extends StatelessWidget {
  const _TrackIndicator({required this.status, super.key});

  final TrackIndicator status;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: looper.indicatorColor(status),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const SizedBox(height: 5, width: double.infinity),
      ),
    );
  }
}

/// A bottom-anchored level meter driven by the track's current [peak]. Updates
/// with the watched looper state — no own timer.
class _PeakBar extends StatelessWidget {
  const _PeakBar({
    required this.peak,
    required this.color,
    required this.hasContent,
  });

  final double peak;
  final Color color;
  final bool hasContent;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        // A track with nothing recorded has no bar (height 0); otherwise the
        // bar tracks the live peak.
        heightFactor: hasContent ? peakMeterFill(peak) : 0.0,
        child: Container(color: color),
      ),
    );
  }
}
