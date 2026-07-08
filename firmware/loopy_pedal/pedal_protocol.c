/*
 * pedal_protocol.c - implementation of the loopy <-> pedal wire protocol.
 *
 * Mirrors PedalCodec (Dart) byte-for-byte: 7-bit SysEx packing, XOR checksum,
 * the 16-byte logical payload layout, and the inbound Note/CC scheme. Pure C,
 * no allocation, no Arduino headers — the sketch #includes it and the host test
 * links it.
 */
#include "pedal_protocol.h"

#define PEDAL_PAYLOAD_LEN 16

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
  uint8_t payload[PEDAL_PAYLOAD_LEN];
  payload[0] = (uint8_t)((frame->play_mode ? 0x01 : 0) |
                         (frame->clear_fade ? 0x02 : 0) |
                         (frame->goodbye ? 0x04 : 0) |
                         (frame->performance_armed ? 0x08 : 0));
  payload[1] = frame->global_color;
  payload[2] = frame->active_bank;
  payload[3] = frame->armed_track;
  for (int i = 0; i < PEDAL_TRACK_COUNT; i++) {
    payload[4 + i] = frame->track_leds[i];
  }
  const uint32_t us = frame->loop_length_micros;
  payload[12] = (uint8_t)(us & 0xFFu);
  payload[13] = (uint8_t)((us >> 8) & 0xFFu);
  payload[14] = (uint8_t)((us >> 16) & 0xFFu);
  payload[15] = (uint8_t)((us >> 24) & 0xFFu);

  uint8_t packed[24];
  const int packed_len = pedal_pack7(payload, PEDAL_PAYLOAD_LEN, packed);

  int o = 0;
  buf[o++] = PEDAL_SYSEX_START;
  buf[o++] = PEDAL_MANUFACTURER_ID;
  buf[o++] = PEDAL_PROTOCOL_VERSION;
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
  if (msg[2] != PEDAL_PROTOCOL_VERSION) return 0;
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
  if (pedal_unpack7(packed, packed_len, payload) != PEDAL_PAYLOAD_LEN) return 0;

  const uint8_t color = payload[1];
  const uint8_t bank = payload[2];
  const uint8_t armed = payload[3];
  if (color >= PEDAL_GLOBAL_COUNT) return 0;
  if (bank > 1) return 0;
  if (armed >= PEDAL_TRACK_COUNT) return 0;
  for (int i = 0; i < PEDAL_TRACK_COUNT; i++) {
    if (payload[4 + i] >= PEDAL_LED_COUNT) return 0;
  }

  out->play_mode = (uint8_t)(payload[0] & 0x01u);
  out->clear_fade = (uint8_t)((payload[0] >> 1) & 0x01u);
  out->goodbye = (uint8_t)((payload[0] >> 2) & 0x01u);
  out->performance_armed = (uint8_t)((payload[0] >> 3) & 0x01u);
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
