import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/looper/view/track_routing_dialog.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:pedal_repository/pedal_repository.dart'
    show PedalBindStatus, PedalTrackLed;

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
    return Focus(
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
                      const _StopPlayButton(),
                      const SizedBox(width: 12),
                      const _ClearAllButton(),
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
    );
  }

  /// The performance keyboard map. Plain keys are consumed (so macOS does not
  /// beep) and dispatched to the looper; modifier combos other than undo/redo
  /// pass through to OS / menu shortcuts.
  ///
  /// Both modes: `M` switch mode · `S` settings · `F` fullscreen · `Space`
  /// play/pause all · `C` clear all · `Cmd/Ctrl+Z` undo · `Cmd/Ctrl+Y` (or
  /// `Shift+Z`) redo.
  /// Record mode: `1`–`8` select · `R` record/overdub · `P` play/pause.
  /// Play mode: `1`–`8` select + mute/unmute.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final bloc = context.read<LooperBloc>();
    final big = context.read<BigPictureCubit>();
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
        bloc.add(
          keyboard.isShiftPressed
              ? LooperRedoPressed(selected)
              : LooperUndoPressed(selected),
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        bloc.add(LooperRedoPressed(selected));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // let OS / menu shortcuts through
    }

    // Common to both modes.
    if (key == LogicalKeyboardKey.keyM) {
      big.toggleMode();
      context.read<PedalCubit>().toggleMode();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(openLoopySettings());
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
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      bloc.add(const LooperClearAllPressed());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      final currentBank = context.read<BankCubit>().state.activeBank;
      final nextBank = currentBank == 0 ? 1 : 0;
      context.read<BankCubit>().selectBank(nextBank);
      context.read<PedalCubit>().selectBank(nextBank);
      context.read<BigPictureCubit>().select(nextBank == 0 ? 0 : 4);
      return KeyEventResult.handled;
    }
    // `U` undoes the latest overdub layer; on a track that holds only its base
    // loop (nothing to undo) it clears the track instead. The bloc decides.
    if (key == LogicalKeyboardKey.keyU) {
      context.read<LooperBloc>().add(LooperUndoPressed(selected));
      return KeyEventResult.handled;
    }

    // Number keys 1–8 select a track (auto-revealing its bank). In play mode
    // they also toggle mute on that track.
    final digit = _digitOf(key);
    if (digit != null) {
      final channel = digit - 1;
      if (channel <= 7) {
        final pedal = context.read<PedalCubit>();
        context.read<BankCubit>().selectBank(
          channel ~/ BankState.tracksPerBank,
        );
        big.select(channel);
        if (big.state.mode == PerformanceMode.play) {
          pedal.togglePlayArm(channel);
          bloc.add(LooperMuteToggled(channel));
        } else {
          pedal.armTrack(channel);
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

    return GestureDetector(
      key: const Key('bigpicture_mode_indicator'),
      onTap: () {
        context.read<BigPictureCubit>().toggleMode();
        context.read<PedalCubit>().toggleMode();
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
              recording ? l10n.performanceModeRec : l10n.performanceModePlay,
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
            GestureDetector(
              key: Key('bigpicture_bank_$i'),
              onTap: () {
                cubit.selectBank(i);
                context.read<PedalCubit>().selectBank(i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
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
    final pedal = context.watch<PedalCubit>();
    final showLedBar = pedal.state.bindStatus != PedalBindStatus.bound;
    final trackLed = pedal.trackLedFor(track.channel);

    // The border is always white; selection only changes its weight. The meter
    // bar color is one table lookup on the track's meter state (muted included;
    // see LooperTheme.meterColors).
    final barColor = looper.meterColor(
      LooperMeterState.of(track.state, muted: track.muted),
      playMode: playMode,
    );

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
              const SizedBox(width: 10),
              IconButton(
                key: Key('bigpicture_undo_${track.channel}'),
                tooltip: 'Undo',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 18,
                color: Colors.white70,
                icon: const Icon(Icons.replay),
                onPressed: track.canUndo
                    ? () => bloc.add(LooperUndoPressed(track.channel))
                    : null,
              ),
              IconButton(
                key: Key('bigpicture_redo_${track.channel}'),
                tooltip: 'Redo',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 18,
                color: Colors.white70,
                icon: Transform.scale(
                  scaleX: -1,
                  child: const Icon(Icons.replay),
                ),
                onPressed: track.canRedo
                    ? () => bloc.add(LooperRedoPressed(track.channel))
                    : null,
              ),
              const SizedBox(width: 10),
              IconButton(
                key: Key('bigpicture_routing_${track.channel}'),
                tooltip: l10n.ioRoutingTooltip,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 18,
                color: Colors.white70,
                icon: const Icon(Icons.alt_route),
                onPressed: () => unawaited(
                  showTrackRoutingDialog(
                    context: context,
                    channel: track.channel,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: GestureDetector(
              key: Key('bigpicture_tile_${track.channel}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                context.read<BigPictureCubit>().select(track.channel);
                context.read<PedalCubit>().armTrack(track.channel);
                if (context.read<BigPictureCubit>().state.mode ==
                    PerformanceMode.record) {
                  bloc.add(LooperRecordPressed(track.channel));
                } else {
                  bloc.add(LooperMuteToggled(track.channel));
                  pedal.togglePlayArm(track.channel);
                }
              },
              onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
              child: _PeakBar(
                peak: track.peak,
                color: barColor,
                hasContent: track.hasContent,
              ),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            key: Key('bigpicture_name_${track.channel}'),
            behavior: HitTestBehavior.opaque,
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
          if (showLedBar) ...[
            const SizedBox(height: 6),
            _TrackLedBar(
              key: Key('bigpicture_led_bar_${track.channel}'),
              led: trackLed,
            ),
          ],
        ],
      ),
    );
  }
}

/// A thin horizontal strip emulating a pedal track LED when MIDI feedback is
/// off.
class _TrackLedBar extends StatelessWidget {
  const _TrackLedBar({
    required this.led,
    super.key,
  });

  final PedalTrackLed led;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: looper.pedalLedColor(led),
        borderRadius: BorderRadius.circular(2),
      ),
      child: const SizedBox(height: 4, width: double.infinity),
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

class _ClearAllButton extends StatelessWidget {
  const _ClearAllButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('bigpicture_clear_all_button'),
      onTap: () =>
          context.read<LooperBloc>().add(const LooperClearAllPressed()),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.red),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.clear_all, size: 16, color: Colors.red),
            SizedBox(width: 6),
            Text('Clear All', style: TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );
  }
}

class _StopPlayButton extends StatelessWidget {
  const _StopPlayButton();

  @override
  Widget build(BuildContext context) {
    final isStopped = context.watch<LooperBloc>().state.tracks.every(
      (t) => t.state == TrackState.stopped || t.state == TrackState.empty,
    );

    return GestureDetector(
      key: const Key('bigpicture_stop_play_button'),
      onTap: () {
        if (isStopped) {
          context.read<LooperBloc>().add(const LooperPlayAllPressed());
        } else {
          context.read<LooperBloc>().add(const LooperStopAllPressed());
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blue),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isStopped ? Icons.play_arrow_rounded : Icons.stop_rounded,
          size: 16,
          color: Colors.blue,
        ),
      ),
    );
  }
}
