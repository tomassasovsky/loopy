import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';

/// A controllable in-memory [AudioEngine] for tests.
///
/// Records interactions and returns scripted results/snapshots, so cubit and
/// widget tests never touch the native audio device.
class FakeAudioEngine implements AudioEngine {
  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  /// Snapshot returned by [snapshot].
  EngineSnapshot nextSnapshot = const EngineSnapshot.initial();

  /// The device name reported while running.
  String runningDeviceName = 'Fake Device';

  bool _running = false;

  /// The most recent config passed to [start].
  EngineConfig? lastConfig;

  /// Call counters for assertions.
  int startCalls = 0;
  int stopCalls = 0;
  int measureLatencyCalls = 0;
  int disposeCalls = 0;
  int recordCalls = 0;
  int stopTrackCalls = 0;
  int playCalls = 0;
  int clearCalls = 0;
  int undoCalls = 0;
  int redoCalls = 0;

  /// Last looper parameter values seen.
  double? lastVolume;
  bool? lastMuted;

  /// Last record offset (latency compensation) applied, in frames.
  int? lastRecordOffset;

  @override
  String get version => 'fake-engine 0.0.0';

  @override
  String get deviceName => _running ? runningDeviceName : '';

  @override
  EngineResult start(EngineConfig config) {
    startCalls++;
    lastConfig = config;
    if (startResult.isOk) _running = true;
    return startResult;
  }

  @override
  EngineResult stop() {
    stopCalls++;
    _running = false;
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() => nextSnapshot;

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() => loopback;

  /// Devices returned by [enumerateDevices].
  List<AudioDevice> devices = const [];

  @override
  List<AudioDevice> enumerateDevices() => devices;

  @override
  EngineResult measureLatency() {
    measureLatencyCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) {
    recordCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    stopTrackCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    playCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    clearCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult undo({int channel = 0}) {
    undoCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult redo({int channel = 0}) {
    redoCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackVolume(double volume, {int channel = 0}) {
    lastVolume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackMute({required bool muted, int channel = 0}) {
    lastMuted = muted;
    return EngineResult.ok;
  }

  /// Last per-track routing values seen (kept separate so input and output
  /// assertions never clobber each other).
  int? lastInputRoutingChannel;
  int? lastInputMask;
  int? lastOutputRoutingChannel;
  int? lastOutputMask;

  @override
  EngineResult setInputMask({required int channel, required int mask}) {
    lastInputRoutingChannel = channel;
    lastInputMask = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMask({required int channel, required int mask}) {
    lastOutputRoutingChannel = channel;
    lastOutputMask = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    return EngineResult.ok;
  }

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  void dispose() => disposeCalls++;
}
