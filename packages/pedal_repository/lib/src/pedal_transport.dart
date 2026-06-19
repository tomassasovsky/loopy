import 'dart:typed_data';

import 'package:midi_client/midi_client.dart' show MidiDevice;

/// A raw inbound pedal message, as delivered by loopy's native 3-byte MIDI
/// capture: `status` (with channel in the low nibble), `data1`, `data2`.
///
/// Only Note-On/Note-Off/Control-Change arrive here — the native capture drops
/// SysEx and real-time messages, so the pedal's identity *reply* (SysEx) is not
/// observable through this stream.
typedef PedalRawMessage = ({int status, int data1, int data2});

/// The low-level seam between `PedalRepository` and the native MIDI transport.
///
/// The pedal binds **one** physical device but uses two directions:
///
/// * **Inbound** ([input]) is *reused* from the single MIDI input capture the
///   device-selection feature already owns — the transport never opens a second
///   capture / `NativeCallable`, so the "exactly one subscription, no double
///   events" guarantee holds.
/// * **Outbound** (everything else) is owned here: enumerate / open / close one
///   MIDI **output** destination and [send] raw bytes (state frames, loop-top
///   pulse, identity request).
///
/// Implemented by `NativePedalTransport` (FFI) in production and by a fake in
/// tests, keeping `PedalRepository` hardware-free.
abstract interface class PedalTransport {
  /// Inbound Note/CC messages from the shared capture.
  Stream<PedalRawMessage> get input;

  /// The host's MIDI output destinations.
  List<MidiDevice> enumerateOutputs();

  /// Opens (or switches to) the output destination [id]. Returns the native
  /// result code (`0` on success).
  int openOutput(String id);

  /// Closes the open output destination. Idempotent; returns the native code.
  int closeOutput();

  /// Sends [bytes] to the open output — a short message or a complete SysEx.
  /// Returns the native result code (`0` on success).
  int send(Uint8List bytes);

  /// Releases the output handle. Does not close the shared input capture (that
  /// is the input feature's lifecycle).
  Future<void> dispose();
}
