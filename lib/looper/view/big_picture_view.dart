import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';

/// The full-screen "Big Picture" performance view: a bold grid of colored loop
/// tiles (Chewie-Monsta style). Tapping a tile records/overdubs it — the
/// primary hands-free gesture. The master output waveform lives in a separate
/// window (see the visualizer); this view is the track grid.
class BigPictureView extends StatelessWidget {
  /// Creates a [BigPictureView].
  const BigPictureView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LooperBloc>().state;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BigHeader(transport: state.transport),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 2.4,
                  children: [
                    for (final track in state.tracks)
                      _BigTrackTile(track: track),
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

class _BigTrackTile extends StatelessWidget {
  const _BigTrackTile({required this.track});

  final Track track;

  String get _label => switch (track.state) {
    TrackState.empty => 'RECORD',
    TrackState.recording => 'RECORDING',
    TrackState.overdubbing => 'OVERDUB',
    TrackState.playing => 'PLAYING',
    TrackState.stopped => 'STOPPED',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final accent = looper.trackColor(track.channel);
    final active = track.isCapturing || track.armed;
    final bloc = context.read<LooperBloc>();

    return GestureDetector(
      key: Key('bigpicture_tile_${track.channel}'),
      onTap: () => bloc.add(LooperRecordPressed(track.channel)),
      onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: looper.tileBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? accent : looper.tileBorder,
            width: active ? 3 : 1.5,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.4),
                    blurRadius: 18,
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 8, backgroundColor: accent),
                const SizedBox(width: 10),
                Text(
                  'TRACK ${track.channel + 1}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                if (track.armed)
                  Text(
                    'ARMED',
                    key: Key('bigpicture_armed_${track.channel}'),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: looper.armedColor,
                    ),
                  )
                else if (track.isMultiple)
                  Text(
                    '×${track.multiple}',
                    style: theme.textTheme.labelLarge?.copyWith(color: accent),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              _label,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: track.state == TrackState.recording
                    ? looper.recordColor
                    : accent,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: track.peak.clamp(0.0, 1.0),
              minHeight: 6,
              color: accent,
              backgroundColor: looper.tileBorder,
            ),
          ],
        ),
      ),
    );
  }
}
