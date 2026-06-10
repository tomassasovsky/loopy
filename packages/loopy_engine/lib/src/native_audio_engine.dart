import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/src/audio_device.dart';
import 'package:loopy_engine/src/audio_engine.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/ffi_strings.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:loopy_engine/src/loopback_info.dart';
import 'package:loopy_engine/src/track_effect.dart';

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
    _trackPtr = calloc<le_track_snapshot>();
    _vizPtr = calloc<Float>(LE_VIZ_POINTS);
  }

  /// Capacity of the device-enumeration buffer; devices beyond this are not
  /// reported (far more than any realistic host exposes).
  static const int _maxDevices = 64;

  final LoopyEngineBindings _bindings;
  late final Pointer<le_engine> _engine;
  late final Pointer<le_snapshot> _snapshotPtr;
  late final Pointer<le_track_snapshot> _trackPtr;
  late final Pointer<Float> _vizPtr;
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
    final count = _snapshotPtr.ref.track_count;
    final tracks = <TrackSnapshot>[];
    for (var i = 0; i < count; i++) {
      _bindings.le_engine_get_track(_engine, i, _trackPtr);
      tracks.add(TrackSnapshot.fromNative(_trackPtr.ref));
    }
    return EngineSnapshot.fromNative(_snapshotPtr.ref, tracks);
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
  List<AudioDevice> enumerateDevices() {
    _checkAlive();
    return [
      ..._enumerate(isInput: false),
      ..._enumerate(isInput: true),
    ];
  }

  /// Reads one direction's devices via the matching native enumeration call.
  /// Capacity is fixed; any devices beyond [_maxDevices] are not reported.
  List<AudioDevice> _enumerate({required bool isInput}) {
    final outPtr = calloc<le_device_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = isInput
          ? _bindings.le_enumerate_capture_devices(
              outPtr,
              _maxDevices,
              countPtr,
            )
          : _bindings.le_enumerate_playback_devices(
              outPtr,
              _maxDevices,
              countPtr,
            );
      if (code != 0) return const [];
      final count = countPtr.value;
      return [
        for (var i = 0; i < count; i++)
          AudioDevice(
            id: readNativeString((outPtr + i).ref.id),
            name: readNativeString((outPtr + i).ref.name),
            isDefault: (outPtr + i).ref.is_default != 0,
            isInput: isInput,
          ),
      ];
    } finally {
      calloc
        ..free(outPtr)
        ..free(countPtr);
    }
  }

  @override
  EngineResult measureLatency() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_measure_latency(_engine));
  }

  @override
  EngineResult record({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_record(_engine, channel),
    );
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_stop_track(_engine, channel),
    );
  }

  @override
  EngineResult play({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_play(_engine, channel));
  }

  @override
  EngineResult clear({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_clear(_engine, channel));
  }

  @override
  EngineResult undo({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_undo(_engine, channel));
  }

  @override
  EngineResult redo({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_redo(_engine, channel));
  }

  @override
  EngineResult setTrackVolume(double volume, {int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_volume(_engine, channel, volume),
    );
  }

  @override
  EngineResult setTrackMute({required bool muted, int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_mute(_engine, channel, muted ? 1 : 0),
    );
  }

  @override
  EngineResult setInputMask({required int channel, required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_input_mask(_engine, channel, mask),
    );
  }

  @override
  EngineResult setOutputMask({required int channel, required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_mask(_engine, channel, mask),
    );
  }

  @override
  EngineResult setRecordOffset(int frames) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_record_offset(_engine, frames),
    );
  }

  @override
  EngineResult setQuantize({required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_quantize(_engine, enabled ? 1 : 0),
    );
  }

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    _checkAlive();
    final mode = enabled == null ? -1 : (enabled ? 1 : 0);
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_quantize(_engine, channel, mode),
    );
  }

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_multiple(_engine, channel, multiple),
    );
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_default_multiple(_engine, multiple),
    );
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_rec_dub(_engine, enabled ? 1 : 0),
    );
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_auto_record(_engine, enabled ? 1 : 0),
    );
  }

  @override
  EngineResult setMonitorInputMask({required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_mask(_engine, mask),
    );
  }

  @override
  EngineResult setMonitorOutputMask({required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_output_mask(_engine, mask),
    );
  }

  @override
  EngineResult setTrackFx({
    required int channel,
    required int slot,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx(_engine, channel, slot, type.code),
    );
  }

  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int slot,
    required int index,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_param(
        _engine,
        channel,
        slot,
        index,
        value,
      ),
    );
  }

  @override
  Float32List readVisual() {
    _checkAlive();
    final n = _bindings.le_engine_read_visual(_engine, _vizPtr, LE_VIZ_POINTS);
    if (n <= 0) return Float32List(0);
    return Float32List.fromList(_vizPtr.asTypedList(n));
  }

  @override
  Float32List readTrackVisual(int channel) {
    _checkAlive();
    final n = _bindings.le_engine_read_track_visual(
      _engine,
      channel,
      _vizPtr,
      LE_VIZ_POINTS,
    );
    if (n <= 0) return Float32List(0);
    return Float32List.fromList(_vizPtr.asTypedList(n));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_engine_destroy(_engine);
    calloc
      ..free(_snapshotPtr)
      ..free(_trackPtr)
      ..free(_vizPtr);
  }
}
