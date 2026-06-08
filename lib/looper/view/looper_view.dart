import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:settings_repository/settings_repository.dart';

/// The multi-track looper view: a Chewie-2-style grid of channel strips with
/// transport controls, level meters, volume, and the master loop position.
class LooperView extends StatelessWidget {
  /// Creates a [LooperView].
  const LooperView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LooperBloc>().state;
    final bloc = context.read<LooperBloc>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Loopy'),
        actions: [
          IconButton(
            key: const Key('looper_playAll_button'),
            tooltip: 'Play all',
            icon: const Icon(Icons.playlist_play),
            onPressed: () => bloc.add(const LooperPlayAllPressed()),
          ),
          IconButton(
            key: const Key('looper_stopAll_button'),
            tooltip: 'Stop all',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: () => bloc.add(const LooperStopAllPressed()),
          ),
          IconButton(
            key: const Key('looper_openSetup_button'),
            tooltip: 'Audio setup',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AudioSetupPage(
                  repository: context.read<LooperRepository>(),
                  settings: context.read<SettingsRepository>(),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MasterLoopBar(transport: state.transport),
            const SizedBox(height: 8),
            _TempoBar(transport: state.transport),
            const SizedBox(height: 12),
            if (!state.transport.isRunning) const _EngineStoppedBanner(),
            Expanded(
              child: ListView.builder(
                itemCount: state.tracks.length,
                itemBuilder: (_, i) => _TrackStrip(track: state.tracks[i]),
              ),
            ),
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

class _TempoBar extends StatelessWidget {
  const _TempoBar({required this.transport});

  final TransportState transport;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<LooperBloc>();
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '${transport.tempoBpm.round()} BPM',
          key: const Key('looper_bpm_text'),
          style: theme.textTheme.titleMedium,
        ),
        if (transport.countingIn) ...[
          const SizedBox(width: 8),
          Text('count-in…', style: theme.textTheme.labelMedium),
        ],
        const Spacer(),
        OutlinedButton.icon(
          key: const Key('looper_tap_button'),
          onPressed: () => bloc.add(const LooperTapTempo()),
          icon: const Icon(Icons.touch_app),
          label: const Text('Tap'),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const Key('looper_metronome_button'),
          tooltip: transport.metronomeOn ? 'Metronome on' : 'Metronome off',
          isSelected: transport.metronomeOn,
          icon: const Icon(Icons.av_timer),
          onPressed: () => bloc.add(const LooperMetronomeToggled()),
        ),
        IconButton(
          key: const Key('looper_countIn_button'),
          tooltip: transport.countInEnabled ? 'Count-in on' : 'Count-in off',
          isSelected: transport.countInEnabled,
          icon: const Icon(Icons.timer_3),
          onPressed: () => bloc.add(const LooperCountInToggled()),
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
      margin: const EdgeInsets.only(bottom: 8),
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
    TrackState.recording => 'Finish',
    TrackState.overdubbing => 'Stop dub',
    TrackState.playing => 'Overdub',
    TrackState.stopped => 'Overdub',
  };

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<LooperBloc>();
    final theme = Theme.of(context);
    final ch = track.channel;
    final isStopped = track.state == TrackState.stopped;
    final canStop = track.isCapturing || track.state == TrackState.playing;

    return Card(
      key: Key('looper_track_$ch'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Track ${ch + 1}', style: theme.textTheme.titleSmall),
                const Spacer(),
                Chip(
                  key: Key('looper_trackState_chip_$ch'),
                  label: Text(track.state.name),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: Key('looper_record_button_$ch'),
                  onPressed: () => bloc.add(LooperRecordPressed(ch)),
                  icon: Icon(
                    track.isCapturing
                        ? Icons.layers
                        : Icons.fiber_manual_record,
                  ),
                  label: Text(_recordLabel),
                ),
                OutlinedButton.icon(
                  key: Key('looper_stop_button_$ch'),
                  onPressed: canStop
                      ? () => bloc.add(LooperStopPressed(ch))
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                OutlinedButton.icon(
                  key: Key('looper_play_button_$ch'),
                  onPressed: isStopped
                      ? () => bloc.add(LooperPlayPressed(ch))
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                OutlinedButton.icon(
                  key: Key('looper_undo_button_$ch'),
                  onPressed: track.canUndo
                      ? () => bloc.add(LooperUndoPressed(ch))
                      : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo'),
                ),
                OutlinedButton.icon(
                  key: Key('looper_redo_button_$ch'),
                  onPressed: track.canRedo
                      ? () => bloc.add(LooperRedoPressed(ch))
                      : null,
                  icon: const Icon(Icons.redo),
                  label: const Text('Redo'),
                ),
                OutlinedButton.icon(
                  key: Key('looper_clear_button_$ch'),
                  onPressed: track.hasContent
                      ? () => bloc.add(LooperClearPressed(ch))
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  key: Key('looper_mute_button_$ch'),
                  tooltip: track.muted ? 'Unmute' : 'Mute',
                  icon: Icon(track.muted ? Icons.volume_off : Icons.volume_up),
                  onPressed: () => bloc.add(LooperMuteToggled(ch)),
                ),
                Expanded(
                  child: Slider(
                    key: Key('looper_volume_slider_$ch'),
                    value: track.volume.clamp(0.0, 1.0),
                    label: track.volume.toStringAsFixed(2),
                    onChanged: (v) => bloc.add(LooperVolumeChanged(ch, v)),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(
                    value: track.peak.clamp(0.0, 1.0),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
