import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/view/track_routing_dialog.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';

/// Session bundle actions in the looper app bar.
enum _SessionAction { save, load, exportMixdown, exportStems }

/// The multi-track looper view: a Chewie-2-style grid of channel strips with
/// transport controls, level meters, volume, and the master loop position.
class LooperView extends StatelessWidget {
  /// Creates a [LooperView].
  const LooperView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LooperBloc>().state;
    final bloc = context.read<LooperBloc>();
    final bank = context.watch<BankCubit>().state;
    final tracks = [
      for (final track in state.tracks)
        if (bank.contains(track.channel)) track,
    ];

    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) =>
          previous.status != current.status &&
          (current.status == SessionStatus.success ||
              current.status == SessionStatus.failure),
      listener: (context, sessionState) {
        final message = switch (sessionState.outcome) {
          SessionOutcome.saved => l10n.sessionSaved,
          SessionOutcome.loaded => l10n.sessionLoaded,
          SessionOutcome.mixdownExported => l10n.mixdownExported,
          SessionOutcome.stemsExported => l10n.stemsExported,
          null => sessionState.errorMessage,
        };
        if (message == null || message.isEmpty) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.looperAppBarTitle),
          actions: [
            PopupMenuButton<_SessionAction>(
              key: const Key('looper_session_button'),
              tooltip: l10n.sessionTooltip,
              icon: const Icon(Icons.folder_outlined),
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
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _SessionAction.save,
                  child: Text(l10n.saveSession),
                ),
                PopupMenuItem(
                  value: _SessionAction.load,
                  child: Text(l10n.loadSession),
                ),
                PopupMenuItem(
                  value: _SessionAction.exportMixdown,
                  child: Text(l10n.exportMixdown),
                ),
                PopupMenuItem(
                  value: _SessionAction.exportStems,
                  child: Text(l10n.exportStems),
                ),
              ],
            ),
            if (bank.enabled) ...[
              for (var i = 0; i < BankState.bankCountMax; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: TextButton(
                    key: Key('looper_bank_$i'),
                    onPressed: () => context.read<BankCubit>().selectBank(i),
                    style: TextButton.styleFrom(
                      backgroundColor: i == bank.activeBank
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      foregroundColor: i == bank.activeBank
                          ? Theme.of(context).colorScheme.onPrimary
                          : null,
                      minimumSize: const Size(40, 0),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(String.fromCharCode(0x41 + i)),
                  ),
                ),
              const SizedBox(width: 8),
            ],
            IconButton(
              key: const Key('looper_playAll_button'),
              tooltip: l10n.playAllTooltip,
              icon: const Icon(Icons.playlist_play),
              onPressed: () => bloc.add(const LooperPlayAllPressed()),
            ),
            IconButton(
              key: const Key('looper_stopAll_button'),
              tooltip: l10n.stopAllTooltip,
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => bloc.add(const LooperStopAllPressed()),
            ),
            IconButton(
              key: const Key('looper_bigPicture_button'),
              tooltip: l10n.bigPictureTooltip,
              icon: const Icon(Icons.open_in_full),
              onPressed: () =>
                  context.read<UiModeCubit>().setMode(UiMode.bigPicture),
            ),
            IconButton(
              key: const Key('looper_openSetup_button'),
              tooltip: l10n.audioSetupTooltip,
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AudioSetupPage(),
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
              const SizedBox(height: 12),
              if (!state.transport.isRunning) const _EngineStoppedBanner(),
              Expanded(
                child: ListView.builder(
                  itemCount: tracks.length,
                  itemBuilder: (_, i) => _TrackStrip(track: tracks[i]),
                ),
              ),
              _StatusFooter(status: state.status),
            ],
          ),
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
        Text(context.l10n.masterLoopLabel, style: theme.textTheme.labelMedium),
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(context.l10n.engineStoppedBanner)),
        ],
      ),
    );
  }
}

class _TrackStrip extends StatelessWidget {
  const _TrackStrip({required this.track});

  final Track track;

  String _recordLabel(AppLocalizations l10n) => switch (track.state) {
    TrackState.empty => l10n.recordButton,
    TrackState.recording => l10n.finishButton,
    TrackState.overdubbing => l10n.stopDubButton,
    TrackState.playing => l10n.overdubButton,
    TrackState.stopped => l10n.overdubButton,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                Text(
                  l10n.trackNumberLabel(ch + 1),
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (track.isMultiple) ...[
                  Chip(
                    key: Key('looper_multiple_chip_$ch'),
                    label: Text(l10n.loopMultipleLabel(track.multiple)),
                  ),
                  const SizedBox(width: 8),
                ],
                Chip(
                  key: Key('looper_trackState_chip_$ch'),
                  label: Text(l10n.trackStateLabel(track.state)),
                ),
                IconButton(
                  key: Key('looper_routing_button_$ch'),
                  tooltip: l10n.ioRoutingTooltip,
                  icon: const Icon(Icons.alt_route),
                  onPressed: () => unawaited(
                    showTrackRoutingDialog(context: context, channel: ch),
                  ),
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
                  label: Text(_recordLabel(l10n)),
                ),
                OutlinedButton.icon(
                  key: Key('looper_stop_button_$ch'),
                  onPressed: canStop
                      ? () => bloc.add(LooperStopPressed(ch))
                      : null,
                  icon: const Icon(Icons.stop),
                  label: Text(l10n.stopButton),
                ),
                OutlinedButton.icon(
                  key: Key('looper_play_button_$ch'),
                  onPressed: isStopped
                      ? () => bloc.add(LooperPlayPressed(ch))
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l10n.playButton),
                ),
                OutlinedButton.icon(
                  key: Key('looper_undo_button_$ch'),
                  onPressed: track.canUndo
                      ? () => bloc.add(LooperUndoPressed(ch))
                      : null,
                  icon: const Icon(Icons.undo),
                  label: Text(l10n.undoButton),
                ),
                OutlinedButton.icon(
                  key: Key('looper_redo_button_$ch'),
                  onPressed: track.canRedo
                      ? () => bloc.add(LooperRedoPressed(ch))
                      : null,
                  icon: const Icon(Icons.redo),
                  label: Text(l10n.redoButton),
                ),
                OutlinedButton.icon(
                  key: Key('looper_clear_button_$ch'),
                  onPressed: track.hasContent
                      ? () => bloc.add(LooperClearPressed(ch))
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.clearButton),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  key: Key('looper_mute_button_$ch'),
                  tooltip: track.muted ? l10n.unmuteTooltip : l10n.muteTooltip,
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
                    value: peakMeterFill(track.peak),
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

  String _latency(AppLocalizations l10n) => switch (status.latencyState) {
    LatencyState.done => l10n.latencyMs(
      status.measuredLatencyMs.toStringAsFixed(2),
    ),
    LatencyState.measuring => l10n.measuringLowercase,
    LatencyState.timeout => l10n.noLoopback,
    LatencyState.idle => l10n.emDash,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final device = status.deviceName.isEmpty
        ? l10n.noDevice
        : status.deviceName;
    return Text(
      l10n.engineStatusFooter(
        device,
        status.sampleRate,
        status.bufferFrames,
        status.inputChannels,
        status.outputChannels,
        _latency(l10n),
      ),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
