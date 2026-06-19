import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/loopy_engine_ffi.dart';
import 'package:meta/meta.dart';
import 'package:midi_client/src/midi_device.dart';
import 'package:midi_client/src/native_library.dart';

/// Thrown when the native MIDI handle cannot be allocated.
class MidiException implements Exception {
  /// Creates a [MidiException].
  const MidiException(this.message);

  /// A human-readable description.
  final String message;

  @override
  String toString() => 'MidiException: $message';
}

/// A thin, typed wrapper over the native `le_midi_*` capture seam.
///
/// Owns a single native MIDI handle (`le_midi`). `bindings` may be injected for
/// tests (e.g. a `FakeLoopyEngineBindings`); when omitted the platform shared
/// library is opened, exactly like `NativeAudioEngine`.
///
/// This is a low-level seam: callers pass a native `le_midi_event_cb` to [open]
/// and are responsible for its lifetime. `MidiControllerSource` is the
/// higher-level adapter that owns the `NativeCallable` and the streams.
class MidiClient {
  /// Creates a [MidiClient], allocating the native MIDI handle.
  ///
  /// Throws a [MidiException] when the platform has no MIDI backend or the
  /// handle cannot be allocated.
  MidiClient({LoopyEngineBindings? bindings})
    : _bindings = bindings ?? LoopyEngineBindings(openLoopyEngineLibrary()) {
    _handle = _bindings.le_midi_create();
    if (_handle == nullptr) {
      throw const MidiException('failed to allocate native MIDI handle');
    }
  }

  /// Capacity of the enumeration buffer; ports beyond this are not reported
  /// (far more than any realistic host exposes).
  static const int _maxDevices = 64;

  final LoopyEngineBindings _bindings;
  late final Pointer<le_midi> _handle;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw const MidiException('MIDI client has been disposed');
    }
  }

  /// Enumerates the host's MIDI input ports.
  ///
  /// Returns an empty list when the platform has no backend or no ports. Safe
  /// to call while a device is open (the native side uses a transient handle).
  List<MidiDevice> enumerate() {
    _checkAlive();
    final outPtr = calloc<le_midi_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = _bindings.le_midi_enumerate(outPtr, _maxDevices, countPtr);
      if (code != 0) return const [];
      final count = countPtr.value;
      return [
        for (var i = 0; i < count; i++)
          MidiDevice(
            id: readNativeString((outPtr + i).ref.id),
            name: readNativeString((outPtr + i).ref.name),
            isDefault: (outPtr + i).ref.is_default != 0,
          ),
      ];
    } finally {
      calloc
        ..free(outPtr)
        ..free(countPtr);
    }
  }

  /// Opens the input port whose id is [id], delivering messages to [cb].
  ///
  /// Re-opening switches the device (the previous port is closed first).
  /// Returns the native result code: `0` (LE_OK) on success, non-zero on
  /// failure (e.g. the port was not found or is in use).
  int open(String id, le_midi_event_cb cb) {
    _checkAlive();
    final idPtr = id.toNativeUtf8();
    try {
      return _bindings.le_midi_open(_handle, idPtr.cast<Char>(), cb);
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Stops capture and closes the open port. Idempotent (a no-op when nothing
  /// is open). After it returns the callback passed to [open] is guaranteed not
  /// to be invoked again. Returns the native result code.
  int close() {
    _checkAlive();
    return _bindings.le_midi_close(_handle);
  }

  /// Closes any open port and frees the native handle. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_midi_destroy(_handle);
  }

  /// Whether [dispose] has been called.
  @visibleForTesting
  bool get isDisposed => _disposed;
}
