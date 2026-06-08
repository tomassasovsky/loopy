import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';

/// The single-track looper view: a Chewie-2-style channel strip with transport
/// controls, level meter, volume, and the master loop position.
class LooperView extends StatelessWidget {
  /// Creates a [LooperView].
  const LooperView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LooperBloc>().state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Loopy'),
        actions: [
          IconButton(
            key: const Key('looper_openSetup_button'),
            tooltip: 'Audio setup',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AudioSetupPage(
                  repository: context.read<LooperRepository>(),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MasterLoopBar(transport: state.transport),
            const SizedBox(height: 16),
            if (!state.transport.isRunning)
              const _EngineStoppedBanner()
            else
              const SizedBox.shrink(),
            const SizedBox(height: 8),
            _TrackStrip(track: state.track),
            const Spacer(),
            _StatusFooter(status: state.status),
          ],
        ),
      ),
    );
  }
}

class _MasterLoopBar extends StatelessWidget {
  const _MasterLoopBar({required this.transport});

  final TransportState transport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Master loop', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          key: const Key('looper_masterLoop_progress'),
          value: transport.hasLoop ? transport.progress : 0,
          minHeight: 8,
        ),
      ],
    );
  }
}

class _EngineStoppedBanner extends StatelessWidget {
  const _EngineStoppedBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('looper_engineStopped_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text('Audio engine stopped — open setup to start.'),
          ),
        ],
      ),
    );
  }
}

class _TrackStrip extends StatelessWidget {
  const _TrackStrip({required this.track});

  final Track track;

  String get _recordLabel => switch (track.state) {
    TrackState.empty => 'Record',
    TrackState.recording => 'Finish loop',
    TrackState.overdubbing => 'Stop overdub',
    TrackState.playing => 'Overdub',
    TrackState.stopped => 'Overdub',
  };

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<LooperBloc>();
    final theme = Theme.of(context);
    final isStopped = track.state == TrackState.stopped;
    final canStop = track.isCapturing || track.state == TrackState.playing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Track ${track.channel + 1}',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Chip(
                  key: const Key('looper_trackState_chip'),
                  label: Text(track.state.name),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('looper_record_button'),
                  onPressed: () => bloc.add(const LooperRecordPressed()),
                  icon: Icon(
                    track.isCapturing
                        ? Icons.layers
                        : Icons.fiber_manual_record,
                  ),
                  label: Text(_recordLabel),
                ),
                OutlinedButton.icon(
                  key: const Key('looper_stop_button'),
                  onPressed: canStop
                      ? () => bloc.add(const LooperStopPressed())
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                OutlinedButton.icon(
                  key: const Key('looper_play_button'),
                  onPressed: isStopped
                      ? () => bloc.add(const LooperPlayPressed())
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                OutlinedButton.icon(
                  key: const Key('looper_undo_button'),
                  onPressed: track.canUndo
                      ? () => bloc.add(const LooperUndoPressed())
                      : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo'),
                ),
                OutlinedButton.icon(
                  key: const Key('looper_clear_button'),
                  onPressed: track.hasContent
                      ? () => bloc.add(const LooperClearPressed())
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  key: const Key('looper_mute_button'),
                  tooltip: track.muted ? 'Unmute' : 'Mute',
                  icon: Icon(track.muted ? Icons.volume_off : Icons.volume_up),
                  onPressed: () => bloc.add(const LooperMuteToggled()),
                ),
                Expanded(
                  child: Slider(
                    key: const Key('looper_volume_slider'),
                    value: track.volume.clamp(0.0, 1.0),
                    label: track.volume.toStringAsFixed(2),
                    onChanged: (v) => bloc.add(LooperVolumeChanged(v)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _LevelMeter(label: 'Level', value: track.peak),
          ],
        ),
      ),
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 2),
        LinearProgressIndicator(value: value.clamp(0.0, 1.0)),
      ],
    );
  }
}

class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.status});

  final EngineStatus status;

  String get _latency => switch (status.latencyState) {
    LatencyState.done => '${status.measuredLatencyMs.toStringAsFixed(2)} ms',
    LatencyState.measuring => 'measuring…',
    LatencyState.timeout => 'no loopback',
    LatencyState.idle => '—',
  };

  @override
  Widget build(BuildContext context) {
    final device = status.deviceName.isEmpty ? 'no device' : status.deviceName;
    return Text(
      '$device · ${status.sampleRate} Hz · ${status.bufferFrames} frames · '
      'latency $_latency',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
