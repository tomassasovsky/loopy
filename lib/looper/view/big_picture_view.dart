import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';

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

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final track in state.tracks)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _TrackColumn(
                              track: track,
                              name: big.nameOf(track.channel),
                              selected: track.channel == big.selectedChannel,
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
    );
  }
}

class _BigHeader extends StatelessWidget {
  const _BigHeader({required this.transport});

  final TransportState transport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    return Row(
      children: [
        Text(
          'LOOPY',
          style: theme.textTheme.titleLarge?.copyWith(
            color: looper.waveformColor,
            fontWeight: FontWeight.bold,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: LinearProgressIndicator(
            key: const Key('bigpicture_masterLoop_progress'),
            value: transport.hasLoop ? transport.progress : 0,
            minHeight: 10,
            color: looper.waveformColor,
            backgroundColor: looper.tileBorder,
          ),
        ),
        const SizedBox(width: 16),
        IconButton(
          key: const Key('bigpicture_exit_button'),
          tooltip: 'Exit big picture',
          icon: const Icon(Icons.close_fullscreen),
          onPressed: () => context.read<UiModeCubit>().setMode(UiMode.desktop),
        ),
      ],
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
              child: _PeakBar(
                channel: track.channel,
                color: accent,
                recordingColor: looper.recordColor,
                recording: recording,
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
