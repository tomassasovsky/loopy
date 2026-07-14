import 'dart:typed_data';

import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_event.dart';
import 'package:pedal_repository/src/pedal_mode.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// The wire codec shared by loopy and the pedal firmware.
///
/// Two directions:
///
/// * **loopy → pedal:** [encodeFrame] serializes a [PedalStateFrame] to a
///   versioned, checksummed, 7-bit-packed SysEx message; [decodeFrame] is the
///   inverse (mirrors what the firmware does, and underpins the golden tests).
/// * **pedal → loopy:** [decodeMessage] turns a raw 3-byte MIDI message
///   (button Note / encoder CC) into a [PedalEvent].
///
/// ### State frame layout (loopy → pedal)
///
/// ```text
/// F0 7D <ver> <type=STATE> <packed payload…> <checksum> F7
/// ```
///
/// The **logical payload** is 17 bytes, 7-bit packed before transmission:
///
/// | byte  | meaning                                                  |
/// |-------|----------------------------------------------------------|
/// | 0     | flags: bit0 mode, bit1 clearFadeActive, bit2 goodbye,    |
/// |       | bit3 performanceArmed                                    |
/// | 1     | [GlobalColor] index                                      |
/// | 2     | active bank (0 = A, 1 = B)                               |
/// | 3     | armed track (0..7)                                       |
/// | 4..11 | [PedalTrackLed] index for tracks 0..7                    |
/// | 12..15| loop length, microseconds, unsigned 32-bit little-endian |
/// | 16    | master gain, unsigned 0..255 (`round(masterGain * 255)`) |
///
/// The mode bit encodes [PedalMode]: `0` = rec, `1` = play. The checksum is the
/// XOR of every packed payload byte, masked to 7 bits.
abstract final class PedalCodec {
  /// MIDI SysEx start byte.
  static const sysExStart = 0xF0;

  /// MIDI SysEx end byte.
  static const sysExEnd = 0xF7;

  /// Non-commercial MIDI manufacturer id used for the pedal protocol.
  static const manufacturerId = 0x7D;

  /// The protocol version carried in every state frame.
  static const protocolVersion = 0x01;

  /// Message type for a state frame.
  static const messageTypeState = 0x01;

  /// The MIDI CC number the encoder transmits (relative, binary-offset).
  static const encoderCc = 0x10;

  /// The MIDI System Real-Time "Start" status byte (`0xFA`), reused as the
  /// loop-top pulse: loopy sends one byte at each loop top. The firmware
  /// currently only records the pulse's arrival time (`g_lastLoopTopMs`) and
  /// does not use it to drive the ring — v1's ring is a fixed-cadence
  /// decorative sweep independent of loop length (see `renderRing()` in
  /// loopy_pedal.ino). The pulse is reserved for a possible future
  /// loop-synced rendering mode. A single real-time byte survives the
  /// firmware's FastLED interrupt gap far better than multi-byte SysEx.
  static const loopTopPulse = 0xFA;

  /// The number of logical (unpacked) payload bytes in a state frame.
  static const _payloadLength = 17;

  // ---------------------------------------------------------------------------
  // loopy → pedal
  // ---------------------------------------------------------------------------

  /// Serializes [frame] to a complete SysEx message.
  static Uint8List encodeFrame(PedalStateFrame frame) {
    final payload = Uint8List(_payloadLength);
    payload[0] =
        (frame.mode == PedalMode.play ? 0x01 : 0) |
        (frame.clearFadeActive ? 0x02 : 0) |
        (frame.isGoodbye ? 0x04 : 0) |
        (frame.performanceArmed ? 0x08 : 0);
    payload[1] = frame.globalColor.index;
    payload[2] = frame.activeBank;
    payload[3] = frame.selectedTrack;
    for (var i = 0; i < PedalStateFrame.trackCount; i++) {
      payload[4 + i] = frame.trackLeds[i].index;
    }
    final us = frame.loopLengthMicros;
    payload[12] = us & 0xFF;
    payload[13] = (us >> 8) & 0xFF;
    payload[14] = (us >> 16) & 0xFF;
    payload[15] = (us >> 24) & 0xFF;
    payload[16] = (frame.masterGain.clamp(0.0, 1.0) * 255).round();

    final packed = _pack7(payload);
    final out = BytesBuilder()
      ..addByte(sysExStart)
      ..addByte(manufacturerId)
      ..addByte(protocolVersion)
      ..addByte(messageTypeState)
      ..add(packed)
      ..addByte(_checksum(packed))
      ..addByte(sysExEnd);
    return out.toBytes();
  }

  /// The Universal Non-Real-Time SysEx **Identity Request**
  /// (`F0 7E 7F 06 01 F7`). loopy broadcasts this when it binds an output port,
  /// so a pedal can recognize the host.
  ///
  /// The pedal's identity *reply* is a SysEx message, which cannot be delivered
  /// through loopy's 3-byte input capture — so the reply is **not parsed** in
  /// v1 and binding is driven by the output port opening (see
  /// `PedalRepository`).
  /// The request is still sent for forward compatibility with a future
  /// SysEx-capable inbound path.
  static Uint8List encodeIdentityRequest() =>
      Uint8List.fromList([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]);

  /// The single-byte [loopTopPulse] real-time message.
  static Uint8List encodeLoopTop() => Uint8List.fromList([loopTopPulse]);

  /// Parses a SysEx [message] back into a [PedalStateFrame].
  ///
  /// Returns `null` if the message is not a well-formed, checksum-valid state
  /// frame of a recognized version — callers keep the last good frame.
  static PedalStateFrame? decodeFrame(List<int> message) {
    if (message.length < 6) return null;
    if (message.first != sysExStart || message.last != sysExEnd) return null;
    if (message[1] != manufacturerId) return null;
    if (message[2] != protocolVersion) return null;
    if (message[3] != messageTypeState) return null;

    // body = packed payload + checksum, between the header and the F7.
    // The length >= 6 guard above guarantees body is non-empty.
    final body = message.sublist(4, message.length - 1);
    final packed = body.sublist(0, body.length - 1);
    final checksum = body.last;
    if (_checksum(packed) != checksum) return null;
    // All transmitted bytes must be 7-bit clean.
    for (final b in packed) {
      if (b & 0x80 != 0) return null;
    }

    final payload = _unpack7(packed);
    // Accept the current 17-byte payload and the legacy 16-byte one (pre master
    // gain); a legacy frame decodes with unity gain. Anything else is
    // malformed.
    if (payload.length != _payloadLength &&
        payload.length != _payloadLength - 1) {
      return null;
    }

    final flags = payload[0];
    final colorIndex = payload[1];
    final activeBank = payload[2];
    final selectedTrack = payload[3];
    if (colorIndex >= GlobalColor.values.length) return null;
    if (activeBank > 1) return null;
    if (selectedTrack >= PedalStateFrame.trackCount) return null;

    final trackLeds = <PedalTrackLed>[];
    for (var i = 0; i < PedalStateFrame.trackCount; i++) {
      final ledIndex = payload[4 + i];
      if (ledIndex >= PedalTrackLed.values.length) return null;
      trackLeds.add(PedalTrackLed.values[ledIndex]);
    }

    final loopLengthMicros =
        payload[12] |
        (payload[13] << 8) |
        (payload[14] << 16) |
        (payload[15] << 24);

    return PedalStateFrame(
      globalColor: GlobalColor.values[colorIndex],
      trackLeds: trackLeds,
      activeBank: activeBank,
      selectedTrack: selectedTrack,
      mode: (flags & 0x01 != 0) ? PedalMode.play : PedalMode.rec,
      clearFadeActive: flags & 0x02 != 0,
      isGoodbye: flags & 0x04 != 0,
      performanceArmed: flags & 0x08 != 0,
      loopLengthMicros: loopLengthMicros,
      masterGain: payload.length >= _payloadLength ? payload[16] / 255.0 : 1.0,
    );
  }

  // ---------------------------------------------------------------------------
  // pedal → loopy
  // ---------------------------------------------------------------------------

  /// Decodes a raw 3-byte MIDI [status]/[data1]/[data2] message into a
  /// [PedalEvent], or `null` for messages that are not pedal input.
  ///
  /// NoteOn maps to [ButtonPressed] (velocity 0 is treated as a release),
  /// NoteOff to [ButtonReleased], and the relative encoder CC to
  /// [EncoderDelta].
  /// The MIDI channel is ignored here; channel filtering is the repository's
  /// concern. [timestamp] is attached to button events for tap/hold timing.
  static PedalEvent? decodeMessage(
    int status,
    int data1,
    int data2, {
    Duration timestamp = Duration.zero,
  }) {
    final type = status & 0xF0;
    switch (type) {
      case 0x90: // NoteOn
        final button = PedalButtonNote.fromNote(data1);
        if (button == null) return null;
        // Running-status NoteOn with velocity 0 means release.
        return data2 == 0
            ? ButtonReleased(button, timestamp: timestamp)
            : ButtonPressed(button, timestamp: timestamp);
      case 0x80: // NoteOff
        final button = PedalButtonNote.fromNote(data1);
        if (button == null) return null;
        return ButtonReleased(button, timestamp: timestamp);
      case 0xB0: // Control Change
        if (data1 != encoderCc) return null;
        return EncoderDelta(_decodeEncoder(data2));
      default:
        return null;
    }
  }

  /// Encodes a relative encoder [delta] to its CC value (binary-offset).
  ///
  /// Inverse of the decode applied in [decodeMessage]; exposed so the firmware
  /// contract and tests share one definition. Clamps to the representable
  /// range (-64..+63).
  static int encodeEncoder(int delta) {
    final clamped = delta < -64
        ? -64
        : delta > 63
        ? 63
        : delta;
    return 64 + clamped;
  }

  static int _decodeEncoder(int value) => value - 64;

  // ---------------------------------------------------------------------------
  // 7-bit packing
  // ---------------------------------------------------------------------------

  /// Packs arbitrary 8-bit [data] into 7-bit-clean bytes (MIDI SysEx style):
  /// each group of up to 7 data bytes is preceded by one byte carrying their
  /// high bits.
  static List<int> _pack7(List<int> data) {
    final out = <int>[];
    for (var i = 0; i < data.length; i += 7) {
      final end = (i + 7 < data.length) ? i + 7 : data.length;
      var msbs = 0;
      for (var j = i; j < end; j++) {
        if (data[j] & 0x80 != 0) msbs |= 1 << (j - i);
      }
      out.add(msbs);
      for (var j = i; j < end; j++) {
        out.add(data[j] & 0x7F);
      }
    }
    return out;
  }

  /// Inverse of [_pack7].
  static List<int> _unpack7(List<int> packed) {
    final out = <int>[];
    var i = 0;
    while (i < packed.length) {
      final msbs = packed[i++];
      for (var j = 0; j < 7 && i < packed.length; j++) {
        var b = packed[i++];
        if (msbs & (1 << j) != 0) b |= 0x80;
        out.add(b);
      }
    }
    return out;
  }

  static int _checksum(List<int> packed) {
    var sum = 0;
    for (final b in packed) {
      sum ^= b;
    }
    return sum & 0x7F;
  }
}
