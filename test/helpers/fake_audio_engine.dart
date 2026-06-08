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

  @override
  EngineResult measureLatency() {
    measureLatencyCalls++;
    return EngineResult.ok;
  }

  @override
  void dispose() => disposeCalls++;
}
