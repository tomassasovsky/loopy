import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes a `performance.json` matching the shape `perf_drain.c` (parts 2-5)
/// actually produces, into [dir] — the fields `PerformanceRepository._finalize`
/// reads back (`sample_rate`, `channel_layout`, `capture_frames`,
/// `overrun_count`, `overrun_gaps`, `layers`) plus the always-`false`
/// `finalized` the drain thread writes on every cycle while armed.
void writeNativeSidecar(
  String dir, {
  int sampleRate = 48000,
  int masterChannels = 2,
  List<int> capturedInputs = const [],
  int captureFrames = 0,
  int overrunCount = 0,
  List<Map<String, dynamic>> layers = const [],
  bool finalized = false,
}) {
  final json = {
    'slug': dir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last,
    'sample_rate': sampleRate,
    'channel_layout': {
      'master_channels': masterChannels,
      'captured_inputs': capturedInputs,
    },
    'capture_frames': captureFrames,
    'overrun_count': overrunCount,
    'overrun_gaps': <Map<String, dynamic>>[],
    'layers': layers,
    'finalized': finalized,
  };
  File(
    '$dir/performance.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// Writes [samples] as raw little-endian float32 bytes to [path] — the format
/// `perf_drain.c` writes `master.pcm` / `input-<n>.pcm` in (no WAV header).
void writeRawPcm(String path, Float32List samples) {
  final bytes = ByteData(samples.length * 4);
  for (var i = 0; i < samples.length; i++) {
    bytes.setFloat32(i * 4, samples[i], Endian.little);
  }
  File(path).writeAsBytesSync(bytes.buffer.asUint8List());
}
