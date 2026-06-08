import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';

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
  static const _thumbFrame = Duration(milliseconds: 50); // ~20 fps
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
              _BigHeader(transport: state.transport),
              const SizedBox(height: 16),
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
                            child: FractionallySizedBox(
                              heightFactor: track.channel == big.selectedChannel
                                  ? 1.0
                                  : 0.68,
                              child: _TrackColumn(
                                track: track,
                                name: big.nameOf(track.channel),
                                selected: track.channel == big.selectedChannel,
                                waveform: _waveformFor(track.channel),
                              ),
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
          '${transport.tempoBpm.round()}',
          style: theme.textTheme.displaySmall?.copyWith(
            color: looper.waveformColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 6),
        Text('BPM', style: theme.textTheme.titleMedium),
        if (transport.syncLoopToTempo && transport.loopBars > 0) ...[
          const SizedBox(width: 16),
          Text(
            '${transport.loopBars} bars',
            key: const Key('bigpicture_bars_text'),
            style: theme.textTheme.titleMedium,
          ),
        ],
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
        : (track.isCapturing || track.armed ? accent : looper.tileBorder);

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
                if (track.armed)
                  Text(
                    'ARMED',
                    key: Key('bigpicture_armed_${track.channel}'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: looper.armedColor,
                    ),
                  )
                else if (track.isMultiple)
                  Text(
                    '×${track.multiple}',
                    style: theme.textTheme.labelMedium?.copyWith(color: accent),
                  ),
              ],
            ),
            Expanded(
              child: Center(
                child: track.hasContent || track.isCapturing
                    ? WaveformView(
                        key: Key('bigpicture_waveform_${track.channel}'),
                        samples: waveform,
                        color: recording ? looper.recordColor : accent,
                      )
                    : const SizedBox.shrink(),
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
