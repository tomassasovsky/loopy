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

  @override
  String get version => 'fake-engine';

  @override
  String get deviceName => deviceNameValue;

  @override
  EngineResult start(EngineConfig config) {
    lastConfig = config;
    calls.add('start');
    return EngineResult.ok;
  }

  @override
  EngineResult stop() {
    calls.add('stop');
    return EngineResult.ok;
  }

  @override
  EngineSnapshot snapshot() => nextSnapshot;

  @override
  EngineResult measureLatency() {
    calls.add('measureLatency');
    return EngineResult.ok;
  }

  @override
  EngineResult record() {
    calls.add('record');
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack() {
    calls.add('stopTrack');
    return EngineResult.ok;
  }

  @override
  EngineResult play() {
    calls.add('play');
    return EngineResult.ok;
  }

  @override
  EngineResult clear() {
    calls.add('clear');
    return EngineResult.ok;
  }

  @override
  EngineResult undo() {
    calls.add('undo');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackVolume(double volume) {
    lastVolume = volume;
    calls.add('setTrackVolume');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackMute({required bool muted}) {
    lastMuted = muted;
    calls.add('setTrackMute');
    return EngineResult.ok;
  }

  @override
  void dispose() => calls.add('dispose');
}
