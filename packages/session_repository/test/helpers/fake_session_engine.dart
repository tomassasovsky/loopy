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
    framesProcessed: 0,
    xrunCount: 0,
    inputRms: 0,
    inputPeak: 0,
    outputRms: 0,
    latencyState: LatencyState.idle,
    measuredLatencyMs: -1,
    masterLengthFrames: masterLength,
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
  EngineResult setLaneCount({required int channel, required int count}) =>
      EngineResult.ok;

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    _tracks[channel].volume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
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
  List<AudioDevice> enumerateDevices() => const [];
  @override
  List<AudioDevice> enumerateAsioDrivers() => const [];
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
  EngineResult setRecordOffset(int frames) => EngineResult.ok;
  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setQuantize({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackMultiple({
    required int channel,
    required int multiple,
  }) => EngineResult.ok;
  @override
  EngineResult setDefaultMultiple({required int multiple}) => EngineResult.ok;
  @override
  EngineResult setRecDub({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setMasterGain(double gain) => EngineResult.ok;
  @override
  EngineResult setAutoRecord({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      EngineResult.ok;
  @override
  EngineResult setOverdubFeedback(double feedback) => EngineResult.ok;
  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneCount({
    required int input,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneOutput({
    required int input,
    required int lane,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneVolume({
    required int input,
    required int lane,
    required double volume,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneMute({
    required int input,
    required int lane,
    required bool muted,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneFx({
    required int input,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneFxCount({
    required int input,
    required int lane,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorLaneFxParam({
    required int input,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  Float32List readVisual() => Float32List(0);
  @override
  Float32List readTrackVisual(int channel) => Float32List(0);
  @override
  void dispose() {}
}
