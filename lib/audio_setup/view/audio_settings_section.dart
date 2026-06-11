import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/view/audio_device_picker.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_view.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/quantize_cubit.dart';
import 'package:loopy/looper/cubit/record_options_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The audio controls embedded in the Big Picture settings "Audio" section,
/// driven by the shared [AudioSetupCubit]: pick the playback/capture device
/// (applied live while running), see the live device/latency status, and
/// re-run the round-trip latency measurement.
class AudioSettingsSection extends StatelessWidget {
  /// Creates an [AudioSettingsSection].
  const AudioSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final status = state.engineStatus;
    final measuring = status.latencyState == LatencyState.measuring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.audioSettingsIntro, style: setupBody),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.outputDeviceGroupUpper),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSettings_playbackDevice_picker',
          devices: state.playbackDevices,
          selectedId: state.playbackDeviceId,
          onSelected: cubit.setPlaybackDevice,
        ),
        const SizedBox(height: 24),
        SetupGroupLabel(l10n.inputDeviceGroupUpper),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSettings_captureDevice_picker',
          devices: state.captureDevices,
          selectedId: state.captureDeviceId,
          onSelected: cubit.setCaptureDevice,
        ),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.monitoringGroupLabel),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_monitor_switch'),
          title: l10n.monitorInputTitle,
          subtitle: l10n.monitorInputSubtitle,
          value: state.monitorInput,
          onChanged: (on) => cubit.setMonitorInput(monitorInput: on),
        ),
        if (state.monitorInput) ..._monitorRouting(context, status),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.recordingGroupLabel),
        const SizedBox(height: 12),
        Text(l10n.maxLoopLengthIntro, style: setupBody),
        const SizedBox(height: 12),
        SetupOptionRow<int>(
          selected: state.maxLoopMinutes,
          onSelected: cubit.setMaxLoopMinutes,
          options: [
            for (final m in AudioSetupState.maxLoopMinuteOptions)
              SetupOption(
                value: m,
                label: m == 0 ? l10n.maxLoopDefault30s : l10n.maxLoopMinutes(m),
                optionKey: Key('audioSettings_maxLoop_$m'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_quantize_switch'),
          title: l10n.quantizeRecording,
          subtitle: l10n.quantizeRecordingSubtitle,
          value: context.watch<QuantizeCubit>().state,
          onChanged: (on) =>
              unawaited(context.read<QuantizeCubit>().setEnabled(value: on)),
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_recDub_switch'),
          title: l10n.overdubOnSecondPressTitle,
          subtitle: l10n.overdubOnSecondPressSubtitle,
          value: context.watch<RecordOptionsCubit>().state.recDub,
          onChanged: (on) => unawaited(
            context.read<RecordOptionsCubit>().setRecDub(value: on),
          ),
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_autoRecord_switch'),
          title: l10n.soundActivatedRecordingTitle,
          subtitle: l10n.soundActivatedRecordingSubtitle,
          value: context.watch<RecordOptionsCubit>().state.autoRecord,
          onChanged: (on) => unawaited(
            context.read<RecordOptionsCubit>().setAutoRecord(value: on),
          ),
        ),
        const SizedBox(height: 16),
        Text(l10n.defaultLoopLengthIntro, style: setupBody),
        const SizedBox(height: 12),
        SetupOptionRow<int>(
          selected: context.watch<RecordOptionsCubit>().state.defaultMultiple,
          onSelected: (m) => unawaited(
            context.read<RecordOptionsCubit>().setDefaultMultiple(m),
          ),
          options: [
            SetupOption(
              value: 0,
              label: l10n.auto,
              optionKey: const Key('audioSettings_defaultMultiple_0'),
            ),
            for (final m in const [1, 2, 3])
              SetupOption(
                value: m,
                label: l10n.loopMultipleLabel(m),
                optionKey: Key('audioSettings_defaultMultiple_$m'),
              ),
          ],
        ),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.statusGroupLabel),
        const SizedBox(height: 12),
        SetupInfoTable(
          rows: [
            (
              l10n.deviceLabel,
              status.deviceName.isEmpty ? l10n.notRunning : status.deviceName,
            ),
            (
              l10n.sampleRateLabel,
              status.sampleRate > 0
                  ? l10n.sampleRateHz(status.sampleRate)
                  : l10n.emDash,
            ),
            (
              l10n.bufferLabel,
              status.bufferFrames > 0
                  ? l10n.bufferFrames(status.bufferFrames)
                  : l10n.emDash,
            ),
            (
              l10n.roundTripLatencyLabel,
              _roundTripLatency(l10n, status),
            ),
            (
              l10n.recordOffsetLabel,
              l10n.bufferFrames(status.recordOffsetFrames),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SetupNavRow(
          rowKey: const Key('audioSettings_measure_button'),
          title: measuring
              ? l10n.measuringEllipsis
              : l10n.measureRoundTripLatency,
          subtitle: l10n.measureLatencySubtitle,
          icon: Icons.timer_outlined,
          onTap: cubit.measureLatency,
        ),
      ],
    );
  }

  /// The per-input live-monitor controls shown under the monitor toggle: one
  /// tile per hardware input (enable, output routing, and its own effects).
  /// Each monitored input is heard live through its chain and never recorded.
  List<Widget> _monitorRouting(BuildContext context, EngineStatus status) {
    final l10n = context.l10n;
    if (status.inputChannels <= 0) {
      return [
        const SizedBox(height: 8),
        Text(l10n.startEngineForMonitorChannels, style: setupBody),
      ];
    }
    return [
      const SizedBox(height: 12),
      Text(l10n.monitorRoutingIntro, style: setupBody),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const Key('audioSettings_openMonitorGraph'),
          onPressed: () => unawaited(
            showMonitorRoutingPage(
              context: context,
              inputChannels: status.inputChannels,
              outputChannels: status.outputChannels,
              excludedInputMask: status.excludedInputMask,
            ),
          ),
          icon: const Icon(Icons.account_tree_outlined, size: 18),
          label: Text(l10n.configureInputMonitoring),
        ),
      ),
    ];
  }

  String _roundTripLatency(AppLocalizations l10n, EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.measuring => l10n.measuringEllipsis,
        LatencyState.done => l10n.latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.timeout => l10n.noSignalDetected,
        LatencyState.idle => l10n.notMeasured,
      };
}
