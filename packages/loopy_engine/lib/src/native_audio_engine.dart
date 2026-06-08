import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/src/audio_engine.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

/// The shared-library file name produced by the FFI plugin per platform.
String _defaultLibraryName() {
  if (Platform.isMacOS || Platform.isIOS) {
    return 'loopy_engine.framework/loopy_engine';
  }
  if (Platform.isWindows) return 'loopy_engine.dll';
  return 'libloopy_engine.so';
}

/// Opens the bundled native engine library for the current platform.
DynamicLibrary _openLibrary() => DynamicLibrary.open(_defaultLibraryName());

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
  EngineResult measureLatency() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_measure_latency(_engine));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_engine_destroy(_engine);
    calloc.free(_snapshotPtr);
  }
}
