import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:loopy/audio_setup/view/audio_device_picker.dart';
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
                label: m == 0 ? 'Default' : '$m min',
                optionKey: Key('audioSettings_maxLoop_$m'),
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

  String _latencyText(EngineStatus s) => switch (s.latencyState) {
    LatencyState.measuring => 'Measuring…',
    LatencyState.done => '${s.measuredLatencyMs.toStringAsFixed(2)} ms',
    LatencyState.timeout => 'No signal detected',
    LatencyState.idle => 'Not measured',
  };
}
