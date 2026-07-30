/*
 * pedal_protocol.c - implementation of the loopy <-> pedal wire protocol.
 *
 * Mirrors PedalCodec (Dart) byte-for-byte: 7-bit SysEx packing, XOR checksum,
 * the 17-byte logical payload layout (protocol v1/v2/v3 -- same byte count:
 * v2 claims spare flags-byte bits, v3 claims bit 1 of the active-bank byte
 * for the 2-bit interaction-mode field), and the inbound Note/CC scheme.
 * Pure C, no allocation, no Arduino headers — the sketch #includes it and
 * the host test links it. Mirrored byte-for-byte in
 * hardware/firmware/loopy_pedal_32u4/ (firmware/test/run_tests.sh is the
 * drift gate).
 */
#include "pedal_protocol.h"

#define PEDAL_PAYLOAD_LEN 17
#define PEDAL_PAYLOAD_LEN_LEGACY 16 /* pre master-gain frames (decode as unity) */

/* Packs `len` 8-bit bytes into 7-bit-clean bytes: each group of up to 7 data
 * bytes is preceded by one byte carrying their high bits (MIDI SysEx style). */
static int pedal_pack7(const uint8_t* data, int len, uint8_t* out) {
  int o = 0;
  for (int i = 0; i < len; i += 7) {
    const int end = (i + 7 < len) ? i + 7 : len;
    uint8_t msbs = 0;
    for (int j = i; j < end; j++) {
      if (data[j] & 0x80u) msbs |= (uint8_t)(1u << (j - i));
    }
    out[o++] = msbs;
    for (int j = i; j < end; j++) {
      out[o++] = (uint8_t)(data[j] & 0x7Fu);
    }
  }
  return o;
}

/* Inverse of pedal_pack7. Returns the number of unpacked bytes written. */
static int pedal_unpack7(const uint8_t* packed, int len, uint8_t* out) {
  int o = 0;
  int i = 0;
  while (i < len) {
    const uint8_t msbs = packed[i++];
    for (int j = 0; j < 7 && i < len; j++) {
      uint8_t b = packed[i++];
      if (msbs & (uint8_t)(1u << j)) b |= 0x80u;
      out[o++] = b;
    }
  }
  return o;
}

static uint8_t pedal_checksum(const uint8_t* packed, int len) {
  uint8_t sum = 0;
  for (int i = 0; i < len; i++) sum ^= packed[i];
  return (uint8_t)(sum & 0x7Fu);
}

int pedal_encode_frame(const pedal_frame* frame, uint8_t* buf) {
  const uint8_t version =
      (frame->protocol_version >= PEDAL_PROTOCOL_VERSION_V1 &&
       frame->protocol_version <= PEDAL_PROTOCOL_VERSION_V3)
          ? frame->protocol_version
          : PEDAL_PROTOCOL_VERSION;

  /* The 2-bit mode field (v3): low bit in flags bit 0, high bit in byte 2
   * bit 1. Below v3 only the low bit exists, and FX degrades to PLAY so an
   * older pedal renders FX mode as mute rather than rec (B10) -- every
   * other byte is encoded identically to the v3 path. */
  uint8_t mode_low;
  uint8_t mode_high;
  if (version >= PEDAL_PROTOCOL_VERSION_V3) {
    mode_low = (uint8_t)(frame->play_mode & 0x01u);
    mode_high = (uint8_t)((frame->play_mode >> 1) & 0x01u);
  } else {
    mode_low = (uint8_t)(frame->play_mode != PEDAL_MODE_REC ? 1 : 0);
    mode_high = 0;
  }

  uint8_t payload[PEDAL_PAYLOAD_LEN];
  payload[0] = (uint8_t)(mode_low |
                         (frame->clear_fade ? 0x02 : 0) |
                         (frame->goodbye ? 0x04 : 0) |
                         (frame->performance_armed ? 0x08 : 0));
  if (version >= PEDAL_PROTOCOL_VERSION_V2) {
    payload[0] = (uint8_t)(payload[0] |
                            ((frame->looper_mode & 0x07u) << 4) |
                            (frame->counting_in ? 0x80u : 0));
  }
  payload[1] = frame->global_color;
  payload[2] = (uint8_t)(frame->active_bank | (mode_high << 1));
  payload[3] = frame->armed_track;
  for (int i = 0; i < PEDAL_TRACK_COUNT; i++) {
    /* Chain-state BLUE is a v3 color: pre-v3 firmware validates LED indices
     * against a 3-value table and rejects the WHOLE frame on an unknown
     * index, so below v3 blue degrades to green (chain-enabled still reads
     * as a lit LED) rather than darkening the pedal (B10). */
    const uint8_t led = frame->track_leds[i];
    payload[4 + i] = (uint8_t)((led == PEDAL_LED_BLUE &&
                                version < PEDAL_PROTOCOL_VERSION_V3)
                                   ? PEDAL_LED_GREEN
                                   : led);
  }
  const uint32_t us = frame->loop_length_micros;
  payload[12] = (uint8_t)(us & 0xFFu);
  payload[13] = (uint8_t)((us >> 8) & 0xFFu);
  payload[14] = (uint8_t)((us >> 16) & 0xFFu);
  payload[15] = (uint8_t)((us >> 24) & 0xFFu);
  payload[16] = frame->master_gain;

  uint8_t packed[24];
  const int packed_len = pedal_pack7(payload, PEDAL_PAYLOAD_LEN, packed);

  int o = 0;
  buf[o++] = PEDAL_SYSEX_START;
  buf[o++] = PEDAL_MANUFACTURER_ID;
  buf[o++] = version;
  buf[o++] = PEDAL_MSG_TYPE_STATE;
  for (int i = 0; i < packed_len; i++) buf[o++] = packed[i];
  buf[o++] = pedal_checksum(packed, packed_len);
  buf[o++] = PEDAL_SYSEX_END;
  return o;
}

int pedal_decode_frame(const uint8_t* msg, int len, pedal_frame* out) {
  if (len < 6) return 0;
  if (msg[0] != PEDAL_SYSEX_START || msg[len - 1] != PEDAL_SYSEX_END) return 0;
  if (msg[1] != PEDAL_MANUFACTURER_ID) return 0;
  const uint8_t version = msg[2];
  if (version < PEDAL_PROTOCOL_VERSION_V1 ||
      version > PEDAL_PROTOCOL_VERSION_V3) {
    return 0;
  }
  if (msg[3] != PEDAL_MSG_TYPE_STATE) return 0;

  /* body = packed payload + checksum, between the header and the F7. */
  const int packed_len = (len - 1) - 4 - 1; /* drop F0/id/ver/type and cksum/F7 */
  if (packed_len < 1) return 0;
  const uint8_t* packed = &msg[4];
  const uint8_t checksum = msg[4 + packed_len];
  if (pedal_checksum(packed, packed_len) != checksum) return 0;
  for (int i = 0; i < packed_len; i++) {
    if (packed[i] & 0x80u) return 0; /* all payload bytes must be 7-bit clean */
  }

  uint8_t payload[PEDAL_PAYLOAD_LEN];
  /* Accept the current 17-byte payload and the legacy 16-byte one (pre master
   * gain); a legacy frame decodes with unity gain. Anything else is malformed. */
  const int plen = pedal_unpack7(packed, packed_len, payload);
  if (plen != PEDAL_PAYLOAD_LEN && plen != PEDAL_PAYLOAD_LEN_LEGACY) return 0;

  const uint8_t color = payload[1];
  const uint8_t bank_byte = payload[2];
  const uint8_t armed = payload[3];
  if (color >= PEDAL_GLOBAL_COUNT) return 0;
  /* Byte 2: bit 0 is the active bank; at v3, bit 1 is the mode field's high
   * bit. Bits above the ones a version defines are reserved zero -- the
   * v1/v2 check is the pre-v3 `bank > 1` rejection, unchanged. */
  if (version >= PEDAL_PROTOCOL_VERSION_V3) {
    if (bank_byte > 3) return 0;
  } else {
    if (bank_byte > 1) return 0;
  }
  const uint8_t bank = (uint8_t)(bank_byte & 0x01u);
  if (armed >= PEDAL_TRACK_COUNT) return 0;
  for (int i = 0; i < PEDAL_TRACK_COUNT; i++) {
    if (payload[4 + i] >= PEDAL_LED_COUNT) return 0;
  }
  /* v1 never carried this field -- bits 4-6 are reserved zero on that wire,
   * so there is nothing to validate there (a v1 decode always reports the
   * default below). A v2 frame's looper-mode nibble must be one of the five
   * defined values; 5-7 are reserved/unused wire values. This check runs
   * here, alongside every other field's validation above and before any
   * `out->` write, so a rejected frame leaves *out completely untouched --
   * matching this function's validate-then-write pattern (the same reason
   * color/bank/armed/track-LEDs are checked before any write, not after). */
  const uint8_t looper_mode = (uint8_t)((payload[0] >> 4) & 0x07u);
  if (version >= PEDAL_PROTOCOL_VERSION_V2 &&
      looper_mode >= PEDAL_LOOPER_MODE_COUNT) {
    return 0;
  }
  /* The 2-bit interaction mode: low bit in flags bit 0, high bit in byte 2
   * bit 1. The high bit needs no version gate: the range check above
   * already rejects any v1/v2 frame with byte-2 bits beyond the bank bit,
   * so it is provably zero on those wires -- a v1/v2 frame can never decode
   * to PEDAL_MODE_FX. The reserved fourth value (3) is rejected like any
   * other out-of-range enum index, here alongside every other pre-write
   * validation. */
  const uint8_t mode = (uint8_t)((payload[0] & 0x01u) |
                                 (((bank_byte >> 1) & 0x01u) << 1));
  if (mode >= PEDAL_MODE_COUNT) return 0;

  out->play_mode = mode;
  out->clear_fade = (uint8_t)((payload[0] >> 1) & 0x01u);
  out->goodbye = (uint8_t)((payload[0] >> 2) & 0x01u);
  out->performance_armed = (uint8_t)((payload[0] >> 3) & 0x01u);
  if (version >= PEDAL_PROTOCOL_VERSION_V2) {
    out->looper_mode = looper_mode;
    out->counting_in = (uint8_t)((payload[0] >> 7) & 0x01u);
  } else {
    out->looper_mode = PEDAL_LOOPER_MODE_MULTI;
    out->counting_in = 0;
  }
  out->global_color = color;
  out->active_bank = bank;
  out->armed_track = armed;
  for (int i = 0; i < PEDAL_TRACK_COUNT; i++) {
    out->track_leds[i] = payload[4 + i];
  }
  out->loop_length_micros = (uint32_t)payload[12] |
                            ((uint32_t)payload[13] << 8) |
                            ((uint32_t)payload[14] << 16) |
                            ((uint32_t)payload[15] << 24);
  out->master_gain = (plen >= PEDAL_PAYLOAD_LEN) ? payload[16] : 255u;
  out->protocol_version = version;
  return 1;
}

int pedal_is_identity_request(const uint8_t* msg, int len) {
  static const uint8_t kRequest[6] = {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7};
  if (len != 6) return 0;
  for (int i = 0; i < 6; i++) {
    if (msg[i] != kRequest[i]) return 0;
  }
  return 1;
}

int pedal_encode_button(uint8_t note, int pressed, uint8_t channel,
                        uint8_t* buf) {
  buf[0] = (uint8_t)((pressed ? 0x90u : 0x80u) | (channel & 0x0Fu));
  buf[1] = (uint8_t)(note & 0x7Fu);
  buf[2] = (uint8_t)(pressed ? 127 : 0);
  return 3;
}

int pedal_encode_encoder(int delta, uint8_t channel, uint8_t* buf) {
  int clamped = delta;
  if (clamped < -64) clamped = -64;
  if (clamped > 63) clamped = 63;
  buf[0] = (uint8_t)(0xB0u | (channel & 0x0Fu));
  buf[1] = PEDAL_ENCODER_CC;
  buf[2] = (uint8_t)(64 + clamped);
  return 3;
}
