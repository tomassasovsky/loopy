import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/view/audio_device_picker.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_view.dart';
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
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final status = state.engineStatus;
    final measuring = status.latencyState == LatencyState.measuring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Choose the audio device and check the measured round-trip latency.',
          style: setupBody,
        ),
        const SizedBox(height: 28),
        const SetupGroupLabel('OUTPUT DEVICE'),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSettings_playbackDevice_picker',
          devices: state.playbackDevices,
          selectedId: state.playbackDeviceId,
          onSelected: cubit.setPlaybackDevice,
        ),
        const SizedBox(height: 24),
        const SetupGroupLabel('INPUT DEVICE'),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSettings_captureDevice_picker',
          devices: state.captureDevices,
          selectedId: state.captureDeviceId,
          onSelected: cubit.setCaptureDevice,
        ),
        const SizedBox(height: 28),
        const SetupGroupLabel('MONITORING'),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_monitor_switch'),
          title: 'Monitor input',
          subtitle: 'Hear the live input through the outputs',
          value: state.monitorInput,
          onChanged: (on) => cubit.setMonitorInput(monitorInput: on),
        ),
        if (state.monitorInput) ..._monitorRouting(context, status),
        const SizedBox(height: 28),
        const SetupGroupLabel('RECORDING'),
        const SizedBox(height: 12),
        const Text(
          'Maximum loop length per track. A higher cap reserves more memory '
          'per track. Changing it reopens the device.',
          style: setupBody,
        ),
        const SizedBox(height: 12),
        SetupOptionRow<int>(
          selected: state.maxLoopMinutes,
          onSelected: cubit.setMaxLoopMinutes,
          options: [
            for (final m in AudioSetupState.maxLoopMinuteOptions)
              SetupOption(
                value: m,
                // 0 uses the engine's built-in cap (sample_rate * 30 = 30 s).
                label: m == 0 ? 'Default (30 s)' : '$m min',
                optionKey: Key('audioSettings_maxLoop_$m'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_quantize_switch'),
          title: 'Quantize recording',
          subtitle:
              'Snap record start/stop to the loop grid. The default for '
              'all tracks; override per track from its routing dialog.',
          value: context.watch<QuantizeCubit>().state,
          onChanged: (on) =>
              unawaited(context.read<QuantizeCubit>().setEnabled(value: on)),
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_recDub_switch'),
          title: 'Overdub on second press',
          subtitle:
              'A second record press keeps layering (rec/dub) instead of '
              'stopping and playing back',
          value: context.watch<RecordOptionsCubit>().state.recDub,
          onChanged: (on) => unawaited(
            context.read<RecordOptionsCubit>().setRecDub(value: on),
          ),
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('audioSettings_autoRecord_switch'),
          title: 'Sound-activated recording',
          subtitle:
              'After pressing record, capture starts when the input '
              'signal begins, instead of immediately',
          value: context.watch<RecordOptionsCubit>().state.autoRecord,
          onChanged: (on) => unawaited(
            context.read<RecordOptionsCubit>().setAutoRecord(value: on),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Default loop length for new recordings. Auto rounds up to whole '
          'base loops; a fixed length records exactly that many. Override it '
          'per track from its routing dialog.',
          style: setupBody,
        ),
        const SizedBox(height: 12),
        SetupOptionRow<int>(
          selected: context.watch<RecordOptionsCubit>().state.defaultMultiple,
          onSelected: (m) => unawaited(
            context.read<RecordOptionsCubit>().setDefaultMultiple(m),
          ),
          options: const [
            SetupOption(
              value: 0,
              label: 'Auto',
              optionKey: Key('audioSettings_defaultMultiple_0'),
            ),
            SetupOption(
              value: 1,
              label: '×1',
              optionKey: Key('audioSettings_defaultMultiple_1'),
            ),
            SetupOption(
              value: 2,
              label: '×2',
              optionKey: Key('audioSettings_defaultMultiple_2'),
            ),
            SetupOption(
              value: 3,
              label: '×3',
              optionKey: Key('audioSettings_defaultMultiple_3'),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const SetupGroupLabel('STATUS'),
        const SizedBox(height: 12),
        SetupInfoTable(
          rows: [
            (
              'Device',
              status.deviceName.isEmpty ? 'Not running' : status.deviceName,
            ),
            (
              'Sample rate',
              status.sampleRate > 0 ? '${status.sampleRate} Hz' : '—',
            ),
            (
              'Buffer',
              status.bufferFrames > 0 ? '${status.bufferFrames} frames' : '—',
            ),
            ('Round-trip latency', _latencyText(status)),
            ('Record offset', '${status.recordOffsetFrames} frames'),
          ],
        ),
        const SizedBox(height: 12),
        SetupNavRow(
          rowKey: const Key('audioSettings_measure_button'),
          title: measuring ? 'Measuring…' : 'Measure round-trip latency',
          subtitle: 'Re-run the loopback latency measurement',
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
    if (status.inputChannels <= 0) {
      return const [
        SizedBox(height: 8),
        Text('Start the engine to choose monitor channels.', style: setupBody),
      ];
    }
    return [
      const SizedBox(height: 12),
      const Text(
        'Monitor inputs live through their own effects (wet) and/or as a clean '
        'dry send — routed to the outputs you pick. Never recorded.',
        style: setupBody,
      ),
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
          label: const Text('Configure input monitoring'),
        ),
      ),
    ];
  }

  String _latencyText(EngineStatus s) => switch (s.latencyState) {
    LatencyState.measuring => 'Measuring…',
    LatencyState.done => '${s.measuredLatencyMs.toStringAsFixed(2)} ms',
    LatencyState.timeout => 'No signal detected',
    LatencyState.idle => 'Not measured',
  };
}
