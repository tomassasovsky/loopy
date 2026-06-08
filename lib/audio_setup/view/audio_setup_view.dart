import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';

/// Device configuration: sample rate, buffer size, input monitoring, plus
/// engine start/stop and round-trip latency measurement.
class AudioSetupView extends StatelessWidget {
  /// Creates an [AudioSetupView].
  const AudioSetupView({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final isRunning = state.status == AudioSetupStatus.running;

    return Scaffold(
      appBar: AppBar(title: const Text('Audio setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Dropdown(
              key: const Key('audioSetup_sampleRate_dropdown'),
              label: 'Sample rate',
              value: state.sampleRate,
              items: AudioSetupState.sampleRates,
              suffix: 'Hz',
              enabled: !isRunning,
              onChanged: cubit.setSampleRate,
            ),
            const SizedBox(height: 16),
            _Dropdown(
              key: const Key('audioSetup_bufferSize_dropdown'),
              label: 'Buffer size',
              value: state.bufferFrames,
              items: AudioSetupState.bufferSizes,
              suffix: 'frames',
              enabled: !isRunning,
              onChanged: cubit.setBufferFrames,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('audioSetup_monitor_switch'),
              title: const Text('Monitor input'),
              value: state.monitorInput,
              onChanged: isRunning
                  ? null
                  : (v) => cubit.setMonitorInput(monitorInput: v),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('audioSetup_startStop_button'),
              onPressed: isRunning ? cubit.stop : cubit.start,
              icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
              label: Text(isRunning ? 'Stop engine' : 'Start engine'),
            ),
            const SizedBox(height: 16),
            if (state.status == AudioSetupStatus.error)
              Text(
                state.errorMessage ?? 'Unknown error',
                key: const Key('audioSetup_error_text'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(height: 32),
            _StatusPanel(status: state.engineStatus),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('audioSetup_measureLatency_button'),
              onPressed: isRunning ? cubit.measureLatency : null,
              icon: const Icon(Icons.timer_outlined),
              label: const Text('Measure round-trip latency'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.suffix,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int value;
  final List<int> items;
  final String suffix;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isExpanded: true,
          items: [
            for (final item in items)
              DropdownMenuItem(value: item, child: Text('$item $suffix')),
          ],
          onChanged: enabled ? (v) => v != null ? onChanged(v) : null : null,
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.status});

  final EngineStatus status;

  String get _latency => switch (status.latencyState) {
    LatencyState.done => '${status.measuredLatencyMs.toStringAsFixed(2)} ms',
    LatencyState.measuring => 'measuring…',
    LatencyState.timeout => 'no loopback detected',
    LatencyState.idle => 'not measured',
  };

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Device', status.deviceName.isEmpty ? '—' : status.deviceName),
      ('Connected', status.isConnected ? 'yes' : 'no'),
      ('Sample rate', '${status.sampleRate} Hz'),
      ('Buffer', '${status.bufferFrames} frames'),
      ('Round-trip latency', _latency),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(label), Text(value)],
            ),
          ),
      ],
    );
  }
}
