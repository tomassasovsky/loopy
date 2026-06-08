import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

/// A controllable in-memory [AudioEngine] for repository tests.
class FakeAudioEngine implements AudioEngine {
  /// Snapshot returned by [snapshot] (mutate between ticks in tests).
  EngineSnapshot nextSnapshot = const EngineSnapshot.initial();

  /// Device name reported by [deviceName].
  String deviceNameValue = 'Fake Device';

  /// Records the command names forwarded to the engine, in order.
  final List<String> calls = <String>[];

  double? lastVolume;
  bool? lastMuted;
  EngineConfig? lastConfig;

  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  @override
  String get version => 'fake-engine';

  @override
  String get deviceName => deviceNameValue;

  @override
  EngineResult start(EngineConfig config) {
    lastConfig = config;
    calls.add('start');
    return startResult;
  }

  @override
  EngineResult stop() {
    calls.add('stop');
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() => nextSnapshot;

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() {
    calls.add('detectLoopback');
    return loopback;
  }

  @override
  EngineResult measureLatency() {
    calls.add('measureLatency');
    return EngineResult.ok;
  }

  /// Last channel seen by a channel-scoped command.
  int? lastChannel;

  @override
  EngineResult record({int channel = 0}) {
    lastChannel = channel;
    calls.add('record');
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    lastChannel = channel;
    calls.add('stopTrack');
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    lastChannel = channel;
    calls.add('play');
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    lastChannel = channel;
    calls.add('clear');
    return EngineResult.ok;
  }

  @override
  EngineResult undo({int channel = 0}) {
    lastChannel = channel;
    calls.add('undo');
    return EngineResult.ok;
  }

  @override
  EngineResult redo({int channel = 0}) {
    lastChannel = channel;
    calls.add('redo');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackVolume(double volume, {int channel = 0}) {
    lastVolume = volume;
    lastChannel = channel;
    calls.add('setTrackVolume');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackMute({required bool muted, int channel = 0}) {
    lastMuted = muted;
    lastChannel = channel;
    calls.add('setTrackMute');
    return EngineResult.ok;
  }

  double? lastTempo;
  bool? lastMetronome;
  bool? lastCountIn;
  bool? lastSyncTempo;
  QuantizeMode? lastQuantize;

  @override
  EngineResult setTempo(double bpm) {
    lastTempo = bpm;
    calls.add('setTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setMetronome({required bool on}) {
    lastMetronome = on;
    calls.add('setMetronome');
    return EngineResult.ok;
  }

  @override
  EngineResult setCountIn({required bool enabled}) {
    lastCountIn = enabled;
    calls.add('setCountIn');
    return EngineResult.ok;
  }

  @override
  EngineResult tapTempo() {
    calls.add('tapTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    lastSyncTempo = on;
    calls.add('setSyncTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setQuantize(QuantizeMode mode) {
    lastQuantize = mode;
    calls.add('setQuantize');
    return EngineResult.ok;
  }

  int? lastRecordOffset;

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    calls.add('setRecordOffset');
    return EngineResult.ok;
  }

  @override
  void dispose() => calls.add('dispose');

  /// Waveform returned by [readVisual] (mutate in tests).
  Float32List visual = Float32List(0);

  @override
  Float32List readVisual() {
    calls.add('readVisual');
    return visual;
  }

  @override
  Float32List readTrackVisual(int channel) {
    calls.add('readTrackVisual');
    return visual;
  }
}
