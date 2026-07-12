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
import 'package:loopy_engine/src/performance_render_progress.dart';
import 'package:loopy_engine/src/plugin_descriptor.dart';
import 'package:loopy_engine/src/track_effect.dart';
import 'package:meta/meta.dart';

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
///
/// A `LOOPY_ENGINE_LIB` environment variable overrides the lookup with an
/// explicit path on every platform — how the device-free test suites (the
/// sequence fuzzer via [PumpedNativeEngine]) point at a freshly built library
/// outside an app bundle.
DynamicLibrary _openLibrary() {
  final override = Platform.environment['LOOPY_ENGINE_LIB'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
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
  List<AudioDevice> enumerateAsioDrivers() {
    _checkAlive();
    // Modeled on _enumerate, but the native call returns DUPLEX drivers (one
    // driver = all I/O), so each result is tagged isInput: false and carries the
    // probed channel counts rather than being split by direction. Off Windows /
    // on the default build the native symbol is a stub returning 0 drivers.
    final outPtr = calloc<le_device_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = _bindings.le_enumerate_asio_drivers(
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
            isInput: false,
            inputChannels: (outPtr + i).ref.input_channels,
            outputChannels: (outPtr + i).ref.output_channels,
            bufferSizes: [
              for (var b = 0; b < (outPtr + i).ref.asio_buffer_count; b++)
                (outPtr + i).ref.asio_buffer_sizes[b],
            ],
            sampleRates: [
              for (var s = 0; s < (outPtr + i).ref.asio_sample_rate_count; s++)
                (outPtr + i).ref.asio_sample_rates[s],
            ],
          ),
      ];
    } finally {
      calloc
        ..free(outPtr)
        ..free(countPtr);
    }
  }

  @override
  EngineResult scanBegin({bool rescan = false}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_plugin_scan_begin(_engine, rescan ? 1 : 0),
    );
  }

  @override
  PluginScanProgress scanPoll() {
    _checkAlive();
    final donePtr = calloc<Int32>();
    final foundPtr = calloc<Int32>();
    final scannedPtr = calloc<Int32>();
    final totalPtr = calloc<Int32>();
    try {
      _bindings.le_plugin_scan_poll(
        _engine,
        donePtr,
        foundPtr,
        scannedPtr,
        totalPtr,
      );
      return PluginScanProgress(
        done: donePtr.value != 0,
        found: foundPtr.value,
        scanned: scannedPtr.value,
        total: totalPtr.value,
      );
    } finally {
      calloc
        ..free(donePtr)
        ..free(foundPtr)
        ..free(scannedPtr)
        ..free(totalPtr);
    }
  }

  @override
  List<PluginDescriptor> scanResults() {
    _checkAlive();
    // The native `found` count is monotonic, so polling it here bounds the read
    // to the entries published so far — a mid-scan call returns a valid prefix,
    // a post-`done` call returns the full set.
    final found = scanPoll().found;
    if (found <= 0) return const [];
    final descPtr = calloc<le_plugin_desc>();
    try {
      final result = <PluginDescriptor>[];
      for (var i = 0; i < found; i++) {
        if (_bindings.le_plugin_scan_get(_engine, i, descPtr) != 0) continue;
        result.add(
          PluginDescriptor(
            id: readNativeString(descPtr.ref.id),
            name: readNativeString(descPtr.ref.name, capacity: 128),
            vendor: readNativeString(descPtr.ref.vendor, capacity: 128),
            path: readNativeString(descPtr.ref.path, capacity: 1024),
            format: PluginFormat.fromCode(descPtr.ref.format),
            version: descPtr.ref.version,
          ),
        );
      }
      return result;
    } finally {
      calloc.free(descPtr);
    }
  }

  @override
  EngineResult scanCancel() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_plugin_scan_cancel(_engine));
  }

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => _loadPlugin(
    pluginId,
    (idPtr, outSlot) => _bindings.le_engine_set_lane_plugin(
      _engine,
      channel,
      lane,
      index,
      idPtr,
      outSlot,
    ),
  );

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => _loadPlugin(
    pluginId,
    (idPtr, outSlot) => _bindings.le_engine_set_monitor_plugin(
      _engine,
      input,
      index,
      idPtr,
      outSlot,
    ),
  );

  /// Shared marshalling for the two plugin-load calls: passes [pluginId] as a C
  /// string + an out-slot pointer to [call], and wraps the published handle.
  PluginSlotHandle? _loadPlugin(
    String pluginId,
    int Function(Pointer<Char> idPtr, Pointer<Pointer<le_plugin_slot>> outSlot)
    call,
  ) {
    _checkAlive();
    final idPtr = pluginId.toNativeUtf8();
    final outSlot = calloc<Pointer<le_plugin_slot>>();
    try {
      final code = call(idPtr.cast(), outSlot);
      if (code != 0) return null;
      return _NativePluginSlotHandle(outSlot.value);
    } finally {
      malloc.free(idPtr);
      calloc.free(outSlot);
    }
  }

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_clear_lane_plugin(_engine, channel, lane, index),
    );
  }

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_clear_monitor_plugin(_engine, input, index),
    );
  }

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return const [];
    final countPtr = calloc<Int32>();
    final infoPtr = calloc<le_plugin_param_info>();
    try {
      if (_bindings.le_plugin_param_count(slot.pointer, countPtr) != 0) {
        return const [];
      }
      final count = countPtr.value;
      final result = <PluginParamInfo>[];
      for (var i = 0; i < count; i++) {
        if (_bindings.le_plugin_param_info_at(slot.pointer, i, infoPtr) != 0) {
          continue;
        }
        result.add(
          PluginParamInfo(
            id: infoPtr.ref.id,
            name: readNativeString(infoPtr.ref.name, capacity: 128),
            unit: readNativeString(infoPtr.ref.unit, capacity: 32),
            min: infoPtr.ref.min,
            max: infoPtr.ref.max,
            def: infoPtr.ref.def,
            stepCount: infoPtr.ref.step_count,
            flags: infoPtr.ref.flags,
          ),
        );
      }
      return result;
    } finally {
      calloc
        ..free(countPtr)
        ..free(infoPtr);
    }
  }

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return 0;
    final out = calloc<Double>();
    try {
      if (_bindings.le_plugin_param_get(slot.pointer, paramId, out) != 0) {
        return 0;
      }
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return null;
    const capacity = 128;
    final out = calloc<Char>(capacity);
    try {
      final code = _bindings.le_plugin_param_value_text(
        slot.pointer,
        paramId,
        value,
        out,
        capacity,
      );
      if (code != 0) return null; // unsupported / invalid -> no text
      return out.cast<Utf8>().toDartString();
    } finally {
      calloc.free(out);
    }
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_plugin_param_set(slot.pointer, paramId, value),
    );
  }

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(_bindings.le_plugin_editor_open(slot.pointer));
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_plugin_editor_close(slot.pointer),
    );
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return false;
    final out = calloc<Int32>();
    try {
      if (_bindings.le_plugin_editor_is_open(slot.pointer, out) != 0) {
        return false;
      }
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return Uint8List(0);
    final sizePtr = calloc<Int32>();
    try {
      if (_bindings.le_plugin_state_size(slot.pointer, sizePtr) != 0) {
        return Uint8List(0);
      }
      final size = sizePtr.value;
      if (size <= 0) return Uint8List(0);
      final buf = calloc<Uint8>(size);
      final written = calloc<Int32>();
      try {
        if (_bindings.le_plugin_state_get(slot.pointer, buf, size, written) !=
            0) {
          return Uint8List(0);
        }
        // Copy out of native memory before it's freed. Clamp to the allocated
        // size: `buf` was sized from le_plugin_state_size, but `written` comes
        // from le_plugin_state_get's own (later) size query — if the plugin's
        // state grew between the two calls, an unclamped length would read past
        // the buffer.
        final n = written.value < size ? written.value : size;
        return Uint8List.fromList(buf.asTypedList(n));
      } finally {
        calloc
          ..free(buf)
          ..free(written);
      }
    } finally {
      calloc.free(sizePtr);
    }
  }

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    if (state.isEmpty) {
      return EngineResult.fromCode(
        _bindings.le_plugin_state_set(slot.pointer, nullptr, 0),
      );
    }
    final buf = calloc<Uint8>(state.length);
    try {
      buf.asTypedList(state.length).setAll(0, state);
      return EngineResult.fromCode(
        _bindings.le_plugin_state_set(slot.pointer, buf, state.length),
      );
    } finally {
      calloc.free(buf);
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
  Float32List exportTrackLane(int channel, int lane) {
    _checkAlive();
    _bindings.le_engine_get_lane(_engine, channel, lane, _lanePtr);
    final frames = _lanePtr.ref.length_frames;
    // Per-lane buffers are mono: one sample per frame.
    if (frames <= 0) return Float32List(0);
    final buf = calloc<Float>(frames);
    try {
      final n = _bindings.le_engine_export_track_lane(
        _engine,
        channel,
        lane,
        buf,
        frames,
      );
      if (n <= 0) return Float32List(0);
      return Float32List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) =>
      importTrackLane(channel, 0, pcm);

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) {
    _checkAlive();
    // Per-lane buffers are mono: one sample per frame.
    final frames = pcm.length;
    if (frames <= 0) return EngineResult.invalid;
    final buf = calloc<Float>(pcm.length);
    try {
      buf.asTypedList(pcm.length).setAll(0, pcm);
      return EngineResult.fromCode(
        _bindings.le_engine_import_track_lane(
          _engine,
          channel,
          lane,
          buf,
          frames,
        ),
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
  EngineResult setMasterGain(double gain) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_master_gain(_engine, gain),
    );
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_limiter(_engine, enabled ? 1 : 0, ceiling),
    );
  }

  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_enabled(
        _engine,
        output,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setOverdubFeedback(double feedback) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_overdub_feedback(_engine, feedback),
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
  int laneFxFingerprint({required int channel, required int lane}) =>
      _bindings.le_engine_lane_fx_fingerprint(_engine, channel, lane);

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input(
        _engine,
        input,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_output(_engine, input, mask),
    );
  }

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_volume(_engine, input, volume),
    );
  }

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_mute(
        _engine,
        input,
        muted ? 1 : 0,
      ),
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
  int monitorFxFingerprint({required int input}) =>
      _bindings.le_engine_monitor_fx_fingerprint(_engine, input);

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
  EngineResult perfArm(String captureDir) {
    _checkAlive();
    final dirPtr = captureDir.toNativeUtf8();
    try {
      return EngineResult.fromCode(
        _bindings.le_perf_arm(_engine, dirPtr.cast()),
      );
    } finally {
      malloc.free(dirPtr);
    }
  }

  @override
  EngineResult perfDisarm() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_perf_disarm(_engine));
  }

  @override
  EngineResult renderBegin(String captureDir) {
    _checkAlive();
    final dirPtr = captureDir.toNativeUtf8();
    try {
      return EngineResult.fromCode(
        _bindings.le_perf_render_begin(_engine, dirPtr.cast()),
      );
    } finally {
      malloc.free(dirPtr);
    }
  }

  @override
  PerformanceRenderProgress renderPoll() {
    _checkAlive();
    final donePtr = calloc<Int32>();
    final progressPtr = calloc<Int32>();
    try {
      _bindings.le_perf_render_poll(_engine, donePtr, progressPtr, nullptr);
      return PerformanceRenderProgress(
        done: donePtr.value != 0,
        progressPercent: progressPtr.value,
      );
    } finally {
      calloc
        ..free(donePtr)
        ..free(progressPtr);
    }
  }

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() {
    _checkAlive();
    final countPtr = calloc<Int32>();
    final channelPtr = calloc<Int32>();
    final succeededPtr = calloc<Int32>();
    try {
      _bindings.le_perf_render_poll(_engine, nullptr, nullptr, countPtr);
      final count = countPtr.value;
      if (count <= 0) return const [];
      final result = <PerformanceRenderTrackStatus>[];
      for (var i = 0; i < count; i++) {
        if (_bindings.le_perf_render_track_status(
              _engine,
              i,
              channelPtr,
              succeededPtr,
            ) !=
            0) {
          continue;
        }
        result.add(
          PerformanceRenderTrackStatus(
            channel: channelPtr.value,
            succeeded: succeededPtr.value != 0,
          ),
        );
      }
      return result;
    } finally {
      calloc
        ..free(countPtr)
        ..free(channelPtr)
        ..free(succeededPtr);
    }
  }

  @override
  EngineResult renderCancel() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_perf_render_cancel(_engine));
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

/// A device-free [NativeAudioEngine] for deterministic tests.
///
/// [start] only CONFIGURES the native engine — no audio device is opened —
/// and [pump] drives the same block processor the real device callback runs
/// (`le_engine_process`), exactly like the native test suite pumps it. Every
/// other call (record/undo/effects/snapshot/…) is the production FFI path on
/// the same handle, so a test harness exercises the real engine end to end
/// with fully controlled time. Lives here (not a test helper file) because it
/// needs the engine handle/bindings the production class keeps private —
/// exported from the package barrel like the mock engine.
class PumpedNativeEngine extends NativeAudioEngine {
  /// Creates a [PumpedNativeEngine]; see [NativeAudioEngine.new] for
  /// [bindings]. The library lookup honours the `LOOPY_ENGINE_LIB`
  /// environment override, which is how test runs point at a freshly built
  /// engine library.
  PumpedNativeEngine({super.bindings});

  int _sampleRate = 48000;

  /// Configures the engine (tracks/buffers/sample rate) WITHOUT opening a
  /// device. The engine is then fully drivable via [pump].
  @override
  EngineResult start(EngineConfig config) {
    _checkAlive();
    _sampleRate = config.sampleRate > 0 ? config.sampleRate : 48000;
    return EngineResult.fromCode(
      _bindings.le_engine_configure(
        _engine,
        _sampleRate,
        config.inputChannels > 0 ? config.inputChannels : 1,
        config.outputChannels > 0 ? config.outputChannels : 1,
        config.maxLoopFrames,
      ),
    );
  }

  /// No device to stop; the configuration (and all content) stays live.
  @override
  EngineResult stop() => EngineResult.ok;

  /// Processes [frames] frames of constant [input] through the engine's block
  /// processor — the audio callback, minus the device. `frames == 0` still
  /// drains the command/event rings and advances per-block maintenance (the
  /// native suites' `drain` idiom).
  void pump({int frames = 512, double input = 0}) {
    _checkAlive();
    if (frames < 0) return;
    final inPtr = calloc<Float>(frames == 0 ? 1 : frames);
    final outPtr = calloc<Float>(frames == 0 ? 1 : frames);
    try {
      for (var i = 0; i < frames; i++) {
        inPtr[i] = input;
      }
      _bindings.le_engine_process(_engine, outPtr, inPtr, frames);
    } finally {
      calloc
        ..free(inPtr)
        ..free(outPtr);
    }
  }

  /// The pump reports a live, present "device": without this the repository's
  /// reconnect supervisor would read the never-started engine as a lost
  /// device and stop/start it mid-test, resetting every track.
  @override
  EngineSnapshot snapshot() {
    final s = super.snapshot();
    return EngineSnapshot(
      isRunning: true,
      devicePresent: true,
      sampleRate: s.sampleRate > 0 ? s.sampleRate : _sampleRate,
      bufferFrames: s.bufferFrames,
      framesProcessed: s.framesProcessed,
      xrunCount: s.xrunCount,
      inputRms: s.inputRms,
      inputPeak: s.inputPeak,
      outputRms: s.outputRms,
      latencyState: s.latencyState,
      measuredLatencyMs: s.measuredLatencyMs,
      inputChannels: s.inputChannels,
      outputChannels: s.outputChannels,
      excludedInputMask: s.excludedInputMask,
      outputEnabledMask: s.outputEnabledMask,
      masterLengthFrames: s.masterLengthFrames,
      masterPositionFrames: s.masterPositionFrames,
      recordOffsetFrames: s.recordOffsetFrames,
      fxAddedLatencyFrames: s.fxAddedLatencyFrames,
      masterGain: s.masterGain,
      activeBackend: s.activeBackend,
      isPerfArmed: s.isPerfArmed,
      perfFrames: s.perfFrames,
      perfOverruns: s.perfOverruns,
      tracks: s.tracks,
    );
  }
}

/// A [PluginSlotHandle] wrapping the native `le_plugin_slot*`. The pointer is
/// owned by the engine (freed when the slot is cleared / the engine is
/// disposed); this is only a token, never freed here.
@immutable
class _NativePluginSlotHandle implements PluginSlotHandle {
  const _NativePluginSlotHandle(this.pointer);

  /// The opaque native slot pointer.
  final Pointer<le_plugin_slot> pointer;

  @override
  bool operator ==(Object other) =>
      other is _NativePluginSlotHandle && other.pointer == pointer;

  @override
  int get hashCode => pointer.hashCode;
}
