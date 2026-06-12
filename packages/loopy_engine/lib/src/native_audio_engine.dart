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
    _lanePtr = calloc<le_lane_snapshot>();
    _vizPtr = calloc<Float>(LE_VIZ_POINTS);
  }

  /// Capacity of the device-enumeration buffer; devices beyond this are not
  /// reported (far more than any realistic host exposes).
  static const int _maxDevices = 64;

  final LoopyEngineBindings _bindings;
  late final Pointer<le_engine> _engine;
  late final Pointer<le_snapshot> _snapshotPtr;
  late final Pointer<le_track_snapshot> _trackPtr;
  late final Pointer<le_lane_snapshot> _lanePtr;
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
      // The native track snapshot can't expose its lane array directly over
      // this ffi version, so read each active lane individually.
      final laneCount = _trackPtr.ref.lane_count;
      final lanes = <LaneSnapshot>[];
      for (var l = 0; l < laneCount; l++) {
        _bindings.le_engine_get_lane(_engine, i, l, _lanePtr);
        lanes.add(LaneSnapshot.fromNative(_lanePtr.ref));
      }
      tracks.add(TrackSnapshot.fromNative(_trackPtr.ref, lanes));
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
            inputChannels: (outPtr + i).ref.input_channels,
            outputChannels: (outPtr + i).ref.output_channels,
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
  EngineResult setLaneCount({required int channel, required int count}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_count(_engine, channel, count),
    );
  }

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_volume(_engine, channel, lane, volume),
    );
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_mute(_engine, channel, lane, muted ? 1 : 0),
    );
  }

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_input(_engine, channel, lane, inputChannel),
    );
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_output(_engine, channel, lane, mask),
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
  Float32List exportTrack(int channel) {
    _checkAlive();
    _bindings.le_engine_get_track(_engine, channel, _trackPtr);
    final frames = _trackPtr.ref.length_frames;
    // Per-track buffers are mono: one sample per frame.
    if (frames <= 0) return Float32List(0);
    final buf = calloc<Float>(frames);
    try {
      final n = _bindings.le_engine_export_track(_engine, channel, buf, frames);
      if (n <= 0) return Float32List(0);
      return Float32List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) {
    _checkAlive();
    // Per-track buffers are mono: one sample per frame.
    final frames = pcm.length;
    if (frames <= 0) return EngineResult.invalid;
    final buf = calloc<Float>(pcm.length);
    try {
      buf.asTypedList(pcm.length).setAll(0, pcm);
      return EngineResult.fromCode(
        _bindings.le_engine_import_track(_engine, channel, buf, frames),
      );
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult commitSession(int baseFrames) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_commit_session(_engine, baseFrames),
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
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx(_engine, channel, lane, index, type.code),
    );
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_count(_engine, channel, lane, count),
    );
  }

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_param(
        _engine,
        channel,
        lane,
        index,
        param,
        value,
      ),
    );
  }

  @override
  EngineResult setMonitorInput({
    required int input,
    required bool enabled,
    required int outputMask,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input(
        _engine,
        input,
        enabled ? 1 : 0,
        outputMask,
      ),
    );
  }

  @override
  EngineResult setMonitorInputDry({
    required int input,
    required int dryOutputMask,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_dry(_engine, input, dryOutputMask),
    );
  }

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx(
        _engine,
        input,
        index,
        type.code,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_count(_engine, input, count),
    );
  }

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_param(
        _engine,
        input,
        index,
        param,
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
      ..free(_lanePtr)
      ..free(_vizPtr);
  }
}
