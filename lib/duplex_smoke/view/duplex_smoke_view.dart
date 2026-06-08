import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/duplex_smoke/cubit/duplex_smoke_cubit.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// The Phase-1 "hello duplex" smoke view.
///
/// Lets the user start/stop a duplex passthrough stream, watch live input and
/// output levels and frame counters, and run a loopback round-trip latency
/// measurement.
class DuplexSmokeView extends StatelessWidget {
  /// Creates a [DuplexSmokeView].
  const DuplexSmokeView({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<DuplexSmokeCubit>();
    final state = cubit.state;
    final snapshot = state.snapshot;
    final isRunning = state.status == DuplexSmokeStatus.running;

    return Scaffold(
      appBar: AppBar(title: const Text('Loopy — Duplex Engine Smoke Test')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                FilledButton.icon(
                  key: const Key('duplexSmoke_startStop_button'),
                  onPressed: isRunning ? cubit.stop : cubit.start,
                  icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(isRunning ? 'Stop' : 'Start passthrough'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const Key('duplexSmoke_measureLatency_button'),
                  onPressed: isRunning ? cubit.measureLatency : null,
                  icon: const Icon(Icons.timer_outlined),
                  label: const Text('Measure latency'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (state.status == DuplexSmokeStatus.error)
              Text(
                state.errorMessage ?? 'Unknown error',
                key: const Key('duplexSmoke_error_text'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            _StatusGrid(state: state, snapshot: snapshot),
            const SizedBox(height: 24),
            _LevelMeter(label: 'Input RMS', value: snapshot.inputRms),
            _LevelMeter(label: 'Input peak', value: snapshot.inputPeak),
            _LevelMeter(label: 'Output RMS', value: snapshot.outputRms),
            const Spacer(),
            Text(
              cubit.engineVersion,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusGrid extends StatelessWidget {
  const _StatusGrid({required this.state, required this.snapshot});

  final DuplexSmokeState state;
  final EngineSnapshot snapshot;

  String get _latencyLabel => switch (snapshot.latencyState) {
    LatencyState.idle => '—',
    LatencyState.measuring => 'measuring…',
    LatencyState.timeout => 'no loopback detected',
    LatencyState.done => '${snapshot.measuredLatencyMs.toStringAsFixed(2)} ms',
  };

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Status', state.status.name),
      ('Device', state.deviceName.isEmpty ? '—' : state.deviceName),
      ('Sample rate', '${snapshot.sampleRate} Hz'),
      ('Buffer', '${snapshot.bufferFrames} frames'),
      ('Channels', '${snapshot.channels}'),
      ('Frames processed', '${snapshot.framesProcessed}'),
      ('Xruns', '${snapshot.xrunCount}'),
      ('Round-trip latency', _latencyLabel),
    ];

    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label),
                Text(value),
              ],
            ),
          ),
      ],
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          LinearProgressIndicator(value: value.clamp(0.0, 1.0)),
        ],
      ),
    );
  }
}
