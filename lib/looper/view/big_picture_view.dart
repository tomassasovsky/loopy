import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/theme/theme.dart';

const _thumbFrame = Duration(milliseconds: 50); // ~20 fps

/// The full-screen "Big Picture" performance view (Chewie-Monsta style): a row
/// of tall colored track columns, each showing its own loop-waveform thumbnail
/// and editable name. Tapping a column selects it (white highlight) and toggles
/// record/overdub; long-press stops. The master output waveform is in a
/// separate window.
class BigPictureView extends StatefulWidget {
  /// Creates a [BigPictureView].
  const BigPictureView({super.key});

  @override
  State<BigPictureView> createState() => _BigPictureViewState();
}

class _BigPictureViewState extends State<BigPictureView> {
  Timer? _poll;
  List<Float32List> _waveforms = const [];

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_thumbFrame, (_) => _pollWaveforms());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _pollWaveforms() {
    if (!mounted) return;
    final looper = context.read<LooperRepository>();
    final count = context.read<LooperBloc>().state.tracks.length;
    setState(() {
      _waveforms = [
        for (var i = 0; i < count; i++) looper.readTrackWaveform(i),
      ];
    });
  }

  Float32List _waveformFor(int channel) =>
      channel < _waveforms.length ? _waveforms[channel] : Float32List(0);

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
                      if (bank.enabled) ...[
                        const SizedBox(width: 12),
                        _BankSwitch(active: bank.activeBank),
                      ],
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 14),
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
                                  name: big.nameOf(track.channel),
                                  selected:
                                      track.channel == big.selectedChannel,
                                  waveform: _waveformFor(track.channel),
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
  /// Both modes: `M` switch mode · `S` settings · `Space` play/pause all ·
  /// `C` clear all · `Cmd/Ctrl+Z` undo · `Cmd/Ctrl+Y` (or `Shift+Z`) redo.
  /// Record mode: `1`–`8` select · `R` record/overdub · `P` play/pause.
  /// Play mode: `1`–`8` select + mute/unmute.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final bloc = context.read<LooperBloc>();
    final big = context.read<BigPictureCubit>();
    final selected = big.state.selectedChannel;

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
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(openLoopySettings());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      final playing = bloc.state.tracks.any(
        (t) =>
            t.state == TrackState.playing || t.state == TrackState.overdubbing,
      );
      bloc.add(
        playing ? const LooperStopAllPressed() : const LooperPlayAllPressed(),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      bloc.add(const LooperClearAllPressed());
      return KeyEventResult.handled;
    }

    // Number keys 1–8 select a track (auto-revealing its bank). In play mode
    // they also toggle mute on that track.
    final digit = _digitOf(key);
    if (digit != null) {
      final channel = digit - 1;
      final bankEnabled = context.read<BankCubit>().state.enabled;
      if (channel <= (bankEnabled ? 7 : 3)) {
        if (bankEnabled) {
          context.read<BankCubit>().selectBank(
            channel ~/ BankState.tracksPerBank,
          );
        }
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

/// Shows the active performance mode (REC / PLAY). Tap to toggle.
class _ModeIndicator extends StatelessWidget {
  const _ModeIndicator({required this.mode});

  final PerformanceMode mode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final recording = mode == PerformanceMode.record;
    final color = recording ? looper.recordColor : looper.trackColor(0);

    return GestureDetector(
      key: const Key('bigpicture_mode_indicator'),
      onTap: context.read<BigPictureCubit>().toggleMode,
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
              recording ? 'REC' : 'PLAY',
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
    final accent = looper.trackColor(0);
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
              onTap: () => cubit.selectBank(i),
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
    required this.waveform,
  });

  final Track track;
  final String name;
  final bool selected;
  final Float32List waveform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final accent = looper.trackColor(track.channel);
    final recording = track.state == TrackState.recording;
    final bloc = context.read<LooperBloc>();
    final borderColor = selected
        ? Colors.white
        : (track.isCapturing ? accent : looper.tileBorder);

    return GestureDetector(
      key: Key('bigpicture_tile_${track.channel}'),
      onTap: () {
        context.read<BigPictureCubit>().select(track.channel);
        bloc.add(LooperRecordPressed(track.channel));
      },
      onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
      child: Container(
        decoration: BoxDecoration(
          color: looper.tileBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: selected ? 3 : 1.5),
          boxShadow: track.isCapturing
              ? [
                  BoxShadow(
                    color: (recording ? looper.recordColor : accent).withValues(
                      alpha: 0.45,
                    ),
                    blurRadius: 18,
                  ),
                ]
              : null,
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
                    '×${track.multiple}',
                    style: theme.textTheme.labelMedium?.copyWith(color: accent),
                  ),
              ],
            ),
            Expanded(
              child: Visibility.maintain(
                visible: track.hasContent,
                child: _PeakBar(
                  channel: track.channel,
                  color: accent,
                  recordingColor: looper.recordColor,
                  recording: recording,
                ),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              key: Key('bigpicture_name_${track.channel}'),
              onTap: () => _rename(context),
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
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final cubit = context.read<BigPictureCubit>();
    final controller = TextEditingController(text: name);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(
          key: const Key('bigpicture_rename_field'),
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('bigpicture_rename_save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await cubit.rename(track.channel, result);
  }
}

class _PeakBar extends StatefulWidget {
  const _PeakBar({
    required this.channel,
    required this.color,
    required this.recordingColor,
    required this.recording,
  });

  final int channel;
  final Color color;
  final Color recordingColor;
  final bool recording;

  @override
  State<_PeakBar> createState() => _PeakBarState();
}

class _PeakBarState extends State<_PeakBar> {
  Timer? _timer;
  double _peak = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_thumbFrame, (_) => _poll());
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _poll() {
    if (!mounted) return;
    final tracks = context.read<LooperBloc>().state.tracks;
    if (widget.channel >= tracks.length) return;
    final next = tracks[widget.channel].peak;
    if (next == _peak) return;
    setState(() => _peak = next);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: (_peak * 10).clamp(0.01, 1.0),
        child: Container(
          color: widget.recording ? widget.recordingColor : widget.color,
        ),
      ),
    );
  }
}
