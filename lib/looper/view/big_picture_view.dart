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
                  if (bank.enabled) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _BankSwitch(active: bank.activeBank),
                    ),
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

  /// Handles keyboard input on the performance surface. Opens settings on `S`
  /// and swallows other plain keys so macOS does not beep (`NSBeep`) on every
  /// unhandled key press. Modifier combos pass through to OS / menu shortcuts.
  /// The full Record/Play key map will be built here.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      unawaited(openLoopySettings());
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
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
