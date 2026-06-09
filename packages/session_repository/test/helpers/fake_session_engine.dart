import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

class _FakeTrack {
  TrackState state = TrackState.empty;
  double volume = 1;
  bool muted = false;
  int multiple = 1;
  int lengthFrames = 0;
  Float32List pcm = Float32List(0);
}

/// A stateful in-memory [AudioEngine] that models the looper state, settings,
/// and per-track PCM closely enough to exercise the session repository's
/// save/load without the native engine.
class FakeSessionEngine implements AudioEngine {
  FakeSessionEngine({this.channels = 1, this.sampleRate = 48000});

  final int channels;
  final int sampleRate;

  final List<_FakeTrack> _tracks = List.generate(4, (_) => _FakeTrack());
  int masterLength = 0;
  double tempo = 120;
  bool sync = true;
  QuantizeMode quantize = QuantizeMode.bar;
  bool metronome = false;
  bool countIn = false;

  /// Seeds a playing track with [pcm] and sets the base loop length from it.
  /// Seed consistent tracks (same base) — the last call wins.
  void seedTrack(
    int channel,
    Float32List pcm, {
    int multiple = 1,
    double volume = 1,
    bool muted = false,
  }) {
    final frames = pcm.length ~/ channels;
    _tracks[channel]
      ..state = TrackState.playing
      ..pcm = pcm
      ..lengthFrames = frames
      ..multiple = multiple
      ..volume = volume
      ..muted = muted;
    masterLength = frames ~/ multiple;
  }

  @override
  EngineSnapshot snapshot() => EngineSnapshot(
    isRunning: true,
    sampleRate: sampleRate,
    bufferFrames: 128,
    channels: channels,
    framesProcessed: 0,
    xrunCount: 0,
    inputRms: 0,
    inputPeak: 0,
    outputRms: 0,
    latencyState: LatencyState.idle,
    measuredLatencyMs: -1,
    masterLengthFrames: masterLength,
    tempoBpm: tempo,
    syncLoopToTempo: sync,
    quantizeMode: quantize,
    metronomeOn: metronome,
    countInEnabled: countIn,
    tracks: [
      for (final t in _tracks)
        TrackSnapshot(
          state: t.state,
          volume: t.volume,
          muted: t.muted,
          lengthFrames: t.lengthFrames,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          multiple: t.multiple,
        ),
    ],
  );

  @override
  Float32List exportTrack(int channel) =>
      Float32List.fromList(_tracks[channel].pcm);

  @override
  EngineResult importTrack(int channel, Float32List pcm) {
    final track = _tracks[channel];
    if (track.state != TrackState.empty) return EngineResult.invalid;
    track
      ..pcm = Float32List.fromList(pcm)
      ..lengthFrames = pcm.length ~/ channels;
    return EngineResult.ok;
  }

  @override
  EngineResult commitSession(int baseFrames) {
    if (baseFrames <= 0) return EngineResult.invalid;
    masterLength = baseFrames;
    for (final track in _tracks) {
      if (track.state == TrackState.empty && track.lengthFrames > 0) {
        track
          ..multiple = track.lengthFrames ~/ baseFrames
          ..state = TrackState.playing;
      }
    }
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    _tracks[channel]
      ..state = TrackState.empty
      ..lengthFrames = 0
      ..multiple = 1
      ..volume = 1
      ..muted = false
      ..pcm = Float32List(0);
    if (_tracks.every((t) => t.state == TrackState.empty)) masterLength = 0;
    return EngineResult.ok;
  }

  @override
  EngineResult setTempo(double bpm) {
    tempo = bpm;
    return EngineResult.ok;
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    sync = on;
    return EngineResult.ok;
  }

  @override
  EngineResult setQuantize(QuantizeMode mode) {
    quantize = mode;
    return EngineResult.ok;
  }

  @override
  EngineResult setMetronome({required bool on}) {
    metronome = on;
    return EngineResult.ok;
  }

  @override
  EngineResult setCountIn({required bool enabled}) {
    countIn = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackVolume(double volume, {int channel = 0}) {
    _tracks[channel].volume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackMute({required bool muted, int channel = 0}) {
    _tracks[channel].muted = muted;
    return EngineResult.ok;
  }

  // ---- unused by SessionRepository: inert defaults ----
  @override
  String get version => 'fake';
  @override
  String get deviceName => 'fake';
  @override
  EngineResult start(EngineConfig config) => EngineResult.ok;
  @override
  EngineResult stop() => EngineResult.ok;
  @override
  LoopbackInfo detectLoopback() => const LoopbackInfo.none();
  @override
  EngineResult measureLatency() => EngineResult.ok;
  @override
  EngineResult record({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult stopTrack({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult play({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult undo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult redo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult tapTempo() => EngineResult.ok;
  @override
  EngineResult setRecordOffset(int frames) => EngineResult.ok;
  @override
  void dispose() {}
}
