import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/loopy_engine_ffi.dart';
import 'package:meta/meta.dart';
import 'package:midi_client/src/midi_client_base.dart' show MidiException;
import 'package:midi_client/src/midi_device.dart';
import 'package:midi_client/src/native_library.dart';

/// A thin, typed wrapper over the native `le_midi_out_*` output seam.
///
/// The send-side counterpart of `MidiClient`: owns a single native MIDI output
/// handle (`le_midi_out`) and pushes raw bytes (short messages or complete
/// SysEx) to one open destination. It has no callback and no ring — [send]
/// hands the bytes straight to the OS. `bindings` may be injected (e.g. a
/// `FakeLoopyEngineBindings`); when omitted the platform shared library is
/// opened, exactly like `MidiClient`.
///
/// loopy uses this for the pedal's LED state frames and the loop-top pulse; the
/// higher-level `NativePedalTransport` (in `pedal_repository`) owns one and
/// reuses `MidiClient`'s single capture for the inbound direction.
class MidiOutClient {
  /// Creates a [MidiOutClient], allocating the native MIDI output handle.
  ///
  /// Throws a [MidiException] when the platform has no MIDI backend or the
  /// handle cannot be allocated.
  MidiOutClient({LoopyEngineBindings? bindings})
    : _bindings = bindings ?? LoopyEngineBindings(openLoopyEngineLibrary()) {
    _handle = _bindings.le_midi_out_create();
    if (_handle == nullptr) {
      throw const MidiException('failed to allocate native MIDI output handle');
    }
  }

  /// Capacity of the enumeration buffer; ports beyond this are not reported.
  static const int _maxDevices = 64;

  final LoopyEngineBindings _bindings;
  late final Pointer<le_midi_out> _handle;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw const MidiException('MIDI output client has been disposed');
    }
  }

  /// Enumerates the host's MIDI output ports.
  ///
  /// Returns an empty list when the platform has no backend or no ports. The
  /// returned ids address *destinations* and are not interchangeable with input
  /// ids even for the same physical device.
  List<MidiDevice> enumerate() {
    _checkAlive();
    final outPtr = calloc<le_midi_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = _bindings.le_midi_out_enumerate(
        outPtr,
        _maxDevices,
        countPtr,
      );
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

  /// Opens (or switches to) the output port whose id is [id].
  ///
  /// Re-opening switches the device (the previous port is closed first).
  /// Returns the native result code: `0` (LE_OK) on success, non-zero on
  /// failure (e.g. the port was not found).
  int open(String id) {
    _checkAlive();
    final idPtr = id.toNativeUtf8();
    try {
      return _bindings.le_midi_out_open(_handle, idPtr.cast<Char>());
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Closes the open output port. Idempotent (a no-op when nothing is open).
  /// Returns the native result code.
  int close() {
    _checkAlive();
    return _bindings.le_midi_out_close(_handle);
  }

  /// Sends [bytes] to the open output port — a short message or a complete
  /// SysEx. Returns the native result code (`0` on success, non-zero when
  /// nothing is open or the OS rejected the send).
  int send(Uint8List bytes) {
    _checkAlive();
    if (bytes.isEmpty) return 0;
    final ptr = calloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _bindings.le_midi_out_send(_handle, ptr, bytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Closes any open port and frees the native handle. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_midi_out_destroy(_handle);
  }

  /// Whether [dispose] has been called.
  @visibleForTesting
  bool get isDisposed => _disposed;
}
