/// Native low-latency duplex audio engine for Loopy.
///
/// Exposes a typed Dart API (`AudioEngine`) over a hand-written miniaudio
/// looping core via FFI. The generated low-level bindings are intentionally not
/// exported — depend on `AudioEngine` and the value objects instead.
library;

export 'src/audio_engine.dart' show AudioEngine, EngineException, EngineResult;
export 'src/engine_config.dart' show EngineConfig;
export 'src/engine_snapshot.dart' show EngineSnapshot, LatencyState, TrackState;
export 'src/loopback_info.dart' show LoopbackInfo, LoopbackKind;
export 'src/native_audio_engine.dart' show NativeAudioEngine;
