import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/src/audio_engine.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:loopy_engine/src/loopback_info.dart';

/// Opens the bundled native engine library for the current platform.
///
/// On Apple platforms the engine is compiled directly into the application
/// binary (Swift Package Manager static-links the plugin into the Runner; the
/// CocoaPods fallback embeds it as a framework). In both cases its exported
/// symbols live in the process's global namespace, so [DynamicLibrary.process]
/// resolves them — there is no standalone library file to open. This relies on
/// the `LE_EXPORT` symbols being marked `visibility("default")` + `used` so the
/// linker keeps them. See macos/loopy_engine/Package.swift.
///
/// On Linux/Windows the engine is a separate shared library opened by name.
DynamicLibrary _openLibrary() {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) return DynamicLibrary.open('loopy_engine.dll');
  return DynamicLibrary.open('libloopy_engine.so');
}

/// Production [AudioEngine] that drives the native miniaudio engine over FFI.
///
/// Owns a single native engine handle. Exactly one instance should own the
/// audio device at a time (the main isolate); the visualizer window consumes
/// pushed frames rather than sharing this handle.
class NativeAudioEngine implements AudioEngine {
  /// Creates a [NativeAudioEngine], loading the bundled native library and
  /// allocating the underlying engine.
  ///
  /// [bindings] may be injected (e.g. against a statically linked test binary);
  /// when omitted, the platform shared library is opened.
  NativeAudioEngine({LoopyEngineBindings? bindings})
    : _bindings = bindings ?? LoopyEngineBindings(_openLibrary()) {
    _engine = _bindings.le_engine_create();
    if (_engine == nullptr) {
      throw const EngineException(
        EngineResult.invalid,
        'failed to allocate native engine',
      );
    }
    _snapshotPtr = calloc<le_snapshot>();
  }

  final LoopyEngineBindings _bindings;
  late final Pointer<le_engine> _engine;
  late final Pointer<le_snapshot> _snapshotPtr;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw const EngineException(
        EngineResult.invalid,
        'engine has been disposed',
      );
    }
  }

  @override
  String get version => _bindings.le_version().cast<Utf8>().toDartString();

  @override
  String get deviceName {
    _checkAlive();
    return _bindings.le_engine_device_name(_engine).cast<Utf8>().toDartString();
  }

  @override
  EngineResult start(EngineConfig config) {
    _checkAlive();
    final cfgPtr = calloc<le_config>();
    try {
      config.writeTo(cfgPtr);
      return EngineResult.fromCode(_bindings.le_engine_start(_engine, cfgPtr));
    } finally {
      calloc.free(cfgPtr);
    }
  }

  @override
  EngineResult stop() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_stop(_engine));
  }

  @override
  EngineSnapshot snapshot() {
    _checkAlive();
    _bindings.le_engine_get_snapshot(_engine, _snapshotPtr);
    return EngineSnapshot.fromNative(_snapshotPtr.ref);
  }

  @override
  LoopbackInfo detectLoopback() {
    final ptr = calloc<le_loopback_info>();
    try {
      // Returns LE_OK on success; on failure it still zero-fills the struct
      // (available == 0), so mapping the result is safe either way.
      _bindings.le_detect_loopback(ptr);
      return LoopbackInfo.fromNative(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  EngineResult measureLatency() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_measure_latency(_engine));
  }

  @override
  EngineResult record() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_record(_engine));
  }

  @override
  EngineResult stopTrack() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_stop_track(_engine));
  }

  @override
  EngineResult play() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_play(_engine));
  }

  @override
  EngineResult clear() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_clear(_engine));
  }

  @override
  EngineResult undo() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_undo(_engine));
  }

  @override
  EngineResult setTrackVolume(double volume) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_volume(_engine, volume),
    );
  }

  @override
  EngineResult setTrackMute({required bool muted}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_mute(_engine, muted ? 1 : 0),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_engine_destroy(_engine);
    calloc.free(_snapshotPtr);
  }
}
