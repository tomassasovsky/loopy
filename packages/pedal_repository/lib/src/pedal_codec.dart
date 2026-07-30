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
/// | 0     | flags: bit0 mode (low bit), bit1 clearFadeActive,        |
/// |       | bit2 goodbye, bit3 performanceArmed, bits4-6             |
/// |       | [PedalLooperMode] index (v2+), bit7 countingIn (v2+)     |
/// | 1     | [GlobalColor] index                                      |
/// | 2     | bit0 active bank (0 = A, 1 = B), bit1 mode high bit      |
/// |       | (v3 only; bits 1-7 reserved zero at v1/v2)               |
/// | 3     | armed track (0..7)                                       |
/// | 4..11 | [PedalTrackLed] index for tracks 0..7                    |
/// | 12..15| loop length, microseconds, unsigned 32-bit little-endian |
/// | 16    | master gain, unsigned 0..255 (`round(masterGain * 255)`) |
///
/// The 2-bit mode field encodes [PedalMode]: `0` = rec, `1` = play, `2` = fx
/// (v3 only), low bit in flags bit 0 and high bit in byte 2 bit 1. The
/// fourth value (`3`) is reserved — [decodeFrame] rejects it like any other
/// out-of-range enum index. On a v1/v2 wire only the low bit exists (`0` =
/// rec, `1` = play). The checksum is the XOR of every packed payload byte,
/// masked to 7 bits.
///
/// ### Protocol versions and the degrade policies
///
/// [protocolVersionV1] is the pre-existing wire (flags bits 4-7 always zero,
/// no looper-mode/counting-in). [protocolVersionV2] (D11) adds those two
/// fields **in the same 17-byte payload** — the flags byte had exactly
/// enough spare headroom (4 of 8 bits used), so v2 needed no payload growth,
/// only a header version bump and two more flag bits. [protocolVersionV3]
/// (FX v3 part 5a) widens the mode field to 2 bits so [PedalMode.fx] fits,
/// claiming bit 1 of the active-bank byte — again no payload growth.
///
/// [encodeFrame] emits [protocolVersion] (v2 — **not** the newest, see its
/// doc comment) by default. Pass `targetVersion:` explicitly to match what
/// the bound firmware is known to speak: at v1 the looper-mode/counting-in
/// fields are silently omitted ("tempo state invisible" per D11, not an
/// error); at v1/v2 a [PedalMode.fx] frame writes its mode bit as play
/// (mute) while **every other byte is encoded exactly as the v3 path
/// would** — the B10 downgrade projection, so chain-state [PedalTrackLed]
/// bytes still reach an older pedal. [decodeFrame] accepts v1/v2/v3: a
/// v1 frame always decodes with [PedalStateFrame.looperMode] `multi` and
/// [PedalStateFrame.countingIn] `false`, and a v1/v2 frame can never decode
/// to [PedalMode.fx] (the wire had no bit for it).
/// [firmwareNeedsUpdate] is the pure signal a later PR's UI surfaces as an
/// "update pedal firmware" notice — this package has no live
/// version-discovery channel yet (see its doc comment).
abstract final class PedalCodec {
  /// MIDI SysEx start byte.
  static const sysExStart = 0xF0;

  /// MIDI SysEx end byte.
  static const sysExEnd = 0xF7;

  /// Non-commercial MIDI manufacturer id used for the pedal protocol.
  static const manufacturerId = 0x7D;

  /// Wire protocol version 1 (pre-B5a): the flags byte carries only the
  /// [PedalMode] bit, `clearFadeActive`, `goodbye`, and `performanceArmed` —
  /// bits 4-7 are unused/reserved and always zero. A frame at this version
  /// cannot carry [PedalStateFrame.looperMode] or
  /// [PedalStateFrame.countingIn] (D11): [decodeFrame] degrades both to
  /// their defaults ([PedalLooperMode.multi], not counting in) rather than
  /// failing to decode.
  static const protocolVersionV1 = 0x01;

  /// Wire protocol version 2 (D11): adds the 3-bit [PedalLooperMode] field
  /// and the counting-in flag to the *same* flags byte (bits 4-6 and bit 7)
  /// — no payload growth was needed. [encodeFrame] emits this by default;
  /// [decodeFrame] accepts it alongside [protocolVersionV1].
  static const protocolVersionV2 = 0x02;

  /// Wire protocol version 3 (FX v3 part 5a): widens the mode field to 2
  /// bits — low bit still flags bit 0, high bit in bit 1 of the active-bank
  /// byte (byte 2) — so [PedalMode.fx] fits. Same 17-byte payload; the mode
  /// field is the **only** wire difference from v2 (R8: no other growth).
  static const protocolVersionV3 = 0x03;

  /// The newest protocol version this codec speaks: the ceiling
  /// [decodeFrame] accepts up to, and the value a negotiated target version
  /// is clamped to (see `PedalRepository.targetProtocolVersion`).
  static const int protocolVersionMax = protocolVersionV3;

  /// The version [encodeFrame] targets when its `targetVersion` parameter is
  /// omitted.
  ///
  /// Deliberately pinned at [protocolVersionV2], **not** [protocolVersionMax]:
  /// there is no version handshake yet (R6), so an un-reflashed pedal must
  /// never receive a v3 frame it would reject outright. Callers that have
  /// *learned* the bound firmware speaks v3 — the manual firmware-version
  /// setting today, #331's identity-reply discovery later — pass
  /// `targetVersion:` explicitly. Do not bump this to v3 in a refactor; the
  /// unknown ⇒ v2 rule is load-bearing and pinned by a test.
  static const int protocolVersion = protocolVersionV2;

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

  /// Serializes [frame] to a complete SysEx message, targeting
  /// [targetVersion] (defaults to [protocolVersion] — v2, the safe floor for
  /// firmware whose version is unknown; see that constant's doc comment).
  ///
  /// Pass `targetVersion:` explicitly to match what the bound firmware is
  /// known to speak. At [protocolVersionV1] (D11) the frame's
  /// [PedalStateFrame.looperMode] and [PedalStateFrame.countingIn] are
  /// silently left off the wire (encoded as if `multi` / not counting in) —
  /// v1 has no bits budgeted for them, not an error. At v1/v2 a frame whose
  /// mode is [PedalMode.fx] writes the mode bit as [PedalMode.play] (mute)
  /// while every other byte — including chain-state [PedalTrackLed] bytes —
  /// is encoded identically to the v3 path (the B10 downgrade projection).
  static Uint8List encodeFrame(
    PedalStateFrame frame, {
    int targetVersion = protocolVersion,
  }) {
    assert(
      targetVersion >= protocolVersionV1 && targetVersion <= protocolVersionMax,
      'targetVersion must be protocolVersionV1..protocolVersionV3, '
      'got $targetVersion',
    );
    // The 2-bit mode field (v3): low bit in flags bit 0, high bit in byte 2
    // bit 1. Below v3 only the low bit exists, and fx degrades to play so an
    // older pedal renders FX mode as mute rather than rec (B10).
    final int modeLowBit;
    final int modeHighBit;
    if (targetVersion >= protocolVersionV3) {
      modeLowBit = frame.mode.index & 0x01;
      modeHighBit = (frame.mode.index >> 1) & 0x01;
    } else {
      modeLowBit = frame.mode == PedalMode.rec ? 0 : 1;
      modeHighBit = 0;
    }
    final payload = Uint8List(_payloadLength);
    payload[0] =
        modeLowBit |
        (frame.clearFadeActive ? 0x02 : 0) |
        (frame.isGoodbye ? 0x04 : 0) |
        (frame.performanceArmed ? 0x08 : 0);
    if (targetVersion >= protocolVersionV2) {
      payload[0] |=
          ((frame.looperMode.index & 0x07) << 4) |
          (frame.countingIn ? 0x80 : 0);
    }
    payload[1] = frame.globalColor.index;
    payload[2] = frame.activeBank | (modeHighBit << 1);
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
      ..addByte(targetVersion)
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
  /// Accepts [protocolVersionV1] through [protocolVersionV3]: a v1 frame
  /// decodes with [PedalStateFrame.looperMode] `multi` and
  /// [PedalStateFrame.countingIn] `false` (the wire never carried anything
  /// else for those fields at v1), and a v1/v2 frame can never decode to
  /// [PedalMode.fx] (only v3 carries the mode field's high bit). A v3 frame
  /// whose mode field holds the reserved fourth value (`3`) is rejected,
  /// like any other out-of-range enum index.
  static PedalStateFrame? decodeFrame(List<int> message) {
    if (message.length < 6) return null;
    if (message.first != sysExStart || message.last != sysExEnd) return null;
    if (message[1] != manufacturerId) return null;
    final version = message[2];
    if (version < protocolVersionV1 || version > protocolVersionMax) {
      return null;
    }
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
    final bankByte = payload[2];
    final selectedTrack = payload[3];
    if (colorIndex >= GlobalColor.values.length) return null;
    // Byte 2: bit 0 is the active bank; at v3, bit 1 is the mode field's
    // high bit. Bits above the ones a version defines are reserved zero —
    // the v1/v2 check is the pre-v3 `activeBank > 1` rejection, unchanged.
    if (version >= protocolVersionV3) {
      if (bankByte > 3) return null;
    } else {
      if (bankByte > 1) return null;
    }
    final activeBank = bankByte & 0x01;
    if (selectedTrack >= PedalStateFrame.trackCount) return null;

    // The 2-bit mode: low bit in flags bit 0, high bit in byte 2 bit 1 (v3
    // only — a v1/v2 frame can never decode to fx). The reserved fourth
    // value is rejected like any other out-of-range enum index.
    final modeIndex =
        (flags & 0x01) |
        (version >= protocolVersionV3 ? ((bankByte >> 1) & 0x01) << 1 : 0);
    if (modeIndex >= PedalMode.values.length) return null;

    // v1 frames never carried these fields — bits 4-7 are reserved zero on
    // that wire, so a v1 decode always reports the defaults (D11). A v2
    // frame's looper-mode nibble must be one of the five defined values;
    // 5-7 are reserved/unused wire values, rejected like any other
    // out-of-range enum index in this decoder.
    var looperMode = PedalLooperMode.multi;
    var countingIn = false;
    if (version >= protocolVersionV2) {
      final looperModeIndex = (flags >> 4) & 0x07;
      if (looperModeIndex >= PedalLooperMode.values.length) return null;
      looperMode = PedalLooperMode.values[looperModeIndex];
      countingIn = flags & 0x80 != 0;
    }

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
      mode: PedalMode.values[modeIndex],
      clearFadeActive: flags & 0x02 != 0,
      isGoodbye: flags & 0x04 != 0,
      performanceArmed: flags & 0x08 != 0,
      loopLengthMicros: loopLengthMicros,
      masterGain: payload.length >= _payloadLength ? payload[16] / 255.0 : 1.0,
      looperMode: looperMode,
      countingIn: countingIn,
    );
  }

  /// Whether firmware reporting [firmwareProtocolVersion] cannot represent
  /// everything the newest protocol ([protocolVersionMax]) carries — the
  /// pure signal part 5b's UI surfaces as an "update pedal firmware" banner.
  ///
  /// Stateless: this package has no live firmware-version-discovery channel
  /// today. `PedalRepository.bind` broadcasts [encodeIdentityRequest], but
  /// the reply is a SysEx message loopy's current 3-byte-only input capture
  /// cannot deliver (see `PedalBindStatus`'s doc comment), so nothing here
  /// reads hardware. Callers pass whatever they learn — the manual
  /// firmware-version setting today, #331's identity-reply discovery later —
  /// and hand the matching version to
  /// `PedalRepository.firmwareProtocolVersion`.
  static bool firmwareNeedsUpdate(int firmwareProtocolVersion) =>
      firmwareProtocolVersion < protocolVersionMax;

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
