/*
 * pedal_protocol.h - the loopy <-> pedal wire protocol, as a plain-C unit.
 *
 * This is the firmware side of the exact same contract loopy's Dart `PedalCodec`
 * implements (packages/pedal_repository). It is deliberately free of any Arduino
 * / FastLED dependency so it can be:
 *   - #included by the loopy_pedal.ino sketch, and
 *   - compiled on a host and unit-tested against the committed golden SysEx
 *     fixtures (firmware/test/test_pedal_protocol.c), the same .syx files loopy
 *     tests against — proving both sides agree byte-for-byte.
 *
 * Frame on the wire (loopy -> pedal), 26 bytes:
 *   F0 7D <ver> <type=01> <20 packed payload bytes> <checksum> F7
 * The 17-byte logical payload (the current fields, master gain included),
 * the 7-bit packing, and the XOR checksum match PedalCodec exactly (see that
 * file for the field table). <ver> is PEDAL_PROTOCOL_VERSION_V1 (0x01) or
 * PEDAL_PROTOCOL_VERSION_V2 (0x02, D11) — the payload's byte *count* is
 * identical at both versions, v2 only claims 4 previously-unused bits in the
 * existing flags byte (looper_mode + counting_in); see pedal_decode_frame.
 */
#ifndef LOOPY_PEDAL_PROTOCOL_H
#define LOOPY_PEDAL_PROTOCOL_H

#include <stdint.h>

#define PEDAL_TRACK_COUNT 8
#define PEDAL_MANUFACTURER_ID 0x7D
/* Wire protocol version 1 (pre-B5a): flags byte bits 4-7 are unused/reserved
 * and always zero -- no looper_mode / counting_in on this wire. */
#define PEDAL_PROTOCOL_VERSION_V1 0x01
/* Wire protocol version 2 (current, D11): flags byte bits 4-6 carry the
 * looper-mode code (PEDAL_LOOPER_MODE_*), bit 7 carries counting_in. Same
 * 17-byte payload as v1 -- the flags byte had the headroom. */
#define PEDAL_PROTOCOL_VERSION_V2 0x02
/* The version pedal_encode_frame emits when a pedal_frame carries no
 * remembered version (protocol_version == 0) -- i.e. the newest this unit
 * speaks. Decoded frames instead re-emit at whatever version they arrived
 * at (see pedal_frame.protocol_version) so the host contract test's
 * decode-then-reencode round trip is version-preserving. */
#define PEDAL_PROTOCOL_VERSION PEDAL_PROTOCOL_VERSION_V2
#define PEDAL_MSG_TYPE_STATE 0x01
#define PEDAL_SYSEX_START 0xF0
#define PEDAL_SYSEX_END 0xF7

/* System real-time "Start" byte, reused as the loop-top pulse. */
#define PEDAL_LOOP_TOP 0xFA
/* The relative CC the encoder reports / the pedal sends (binary-offset). */
#define PEDAL_ENCODER_CC 0x10

/* The largest state frame, for output buffers (26 in practice). */
#define PEDAL_FRAME_MAX_BYTES 32

/* Per-track LED, matching PedalTrackLed. */
enum {
  PEDAL_LED_OFF = 0,
  PEDAL_LED_GREEN = 1,
  PEDAL_LED_RED = 2,
  PEDAL_LED_COUNT = 3
};

/* Global / mode color, matching GlobalColor. */
enum {
  PEDAL_GLOBAL_OFF = 0,
  PEDAL_GLOBAL_GREEN = 1,
  PEDAL_GLOBAL_RED = 2,
  PEDAL_GLOBAL_AMBER = 3,
  PEDAL_GLOBAL_BLUE = 4,
  PEDAL_GLOBAL_COUNT = 5
};

/* Looper-mode wire code (protocol v2, D11), matching PedalLooperMode
 * value-for-value -- do not reorder. This is a DIFFERENT axis from
 * pedal_frame.play_mode (the pedal's own Rec/Play interaction mode, wire
 * bit 0, unaffected by v2): this is the engine's looper transport mode
 * (Multi/Sync/Song/Band/Free). Values 5-7 are reserved/unused; a v2 decode
 * rejects them. */
enum {
  PEDAL_LOOPER_MODE_MULTI = 0,
  PEDAL_LOOPER_MODE_SYNC = 1,
  PEDAL_LOOPER_MODE_SONG = 2,
  PEDAL_LOOPER_MODE_BAND = 3,
  PEDAL_LOOPER_MODE_FREE = 4,
  PEDAL_LOOPER_MODE_COUNT = 5
};

/* The fixed Note number each footswitch transmits, matching PedalButton. */
enum {
  PEDAL_BTN_REC_PLAY = 0,
  PEDAL_BTN_STOP = 1,
  PEDAL_BTN_UNDO = 2,
  PEDAL_BTN_MODE = 3,
  PEDAL_BTN_TRACK1 = 4,
  PEDAL_BTN_TRACK2 = 5,
  PEDAL_BTN_TRACK3 = 6,
  PEDAL_BTN_TRACK4 = 7,
  PEDAL_BTN_CLEAR = 8,
  PEDAL_BTN_BANK = 9,
  PEDAL_BTN_COUNT = 10
};

/* The decoded looper state the pedal renders. */
typedef struct pedal_frame {
  uint8_t play_mode;  /* 0 = Rec mode, 1 = Play mode */
  uint8_t clear_fade; /* clear-all fade in progress */
  uint8_t goodbye;    /* shutdown frame: darken everything */
  uint8_t performance_armed; /* D-PEDAL: blink the mode LED red when set */
  uint8_t global_color;
  uint8_t active_bank; /* 0 = A, 1 = B */
  uint8_t armed_track; /* 0..7 */
  uint8_t track_leds[PEDAL_TRACK_COUNT];
  uint32_t loop_length_micros;
  uint8_t master_gain; /* engine master output gain, 0..255 (255 = unity) */
  /* protocol v2 (D11); PEDAL_LOOPER_MODE_MULTI / 0 on a v1-decoded frame --
   * the wire never carried anything else at v1. */
  uint8_t looper_mode;
  uint8_t counting_in;
  /* The version this frame was decoded at (PEDAL_PROTOCOL_VERSION_V1/V2), or
   * 0 for a frame that was never decoded (freshly constructed by a caller).
   * pedal_encode_frame re-emits at this version when non-zero, so the host
   * contract test's decode -> re-encode round trip reproduces the exact
   * bytes it started from regardless of which version they were. Firmware
   * itself never calls pedal_encode_frame at runtime (see its doc comment)
   * -- this field only matters to the host test. */
  uint8_t protocol_version;
} pedal_frame;

#ifdef __cplusplus
extern "C" {
#endif

/* Decodes a complete SysEx message (F0..F7) into *out. Accepts both
 * PEDAL_PROTOCOL_VERSION_V1 and _V2 (D11) -- a v1 frame decodes with
 * looper_mode/counting_in at their defaults, since v1 never carried them.
 * Returns 1 on success, 0 for any malformed / unrecognized-version /
 * bad-checksum / out-of-range frame -- every field (including looper_mode)
 * is validated before anything is written, so on a 0 return *out is left
 * completely untouched (the caller keeps its last good frame). Never reads
 * past `len`. */
int pedal_decode_frame(const uint8_t* msg, int len, pedal_frame* out);

/* Encodes *frame into `buf` (must hold PEDAL_FRAME_MAX_BYTES), at
 * frame->protocol_version if set (a decoded frame remembers its version),
 * else PEDAL_PROTOCOL_VERSION (the newest). Returns the number of bytes
 * written. Produces the exact bytes PedalCodec.encodeFrame does — the
 * firmware uses this only in its host contract test, not at runtime. */
int pedal_encode_frame(const pedal_frame* frame, uint8_t* buf);

/* Whether `msg` is the Universal Identity Request (F0 7E 7F 06 01 F7). */
int pedal_is_identity_request(const uint8_t* msg, int len);

/* Writes a 3-byte Note message for button `note` (a PEDAL_BTN_* value) into
 * `buf`: NoteOn velocity 127 when `pressed`, else NoteOff. Returns 3. */
int pedal_encode_button(uint8_t note, int pressed, uint8_t channel,
                        uint8_t* buf);

/* Writes the 3-byte relative-encoder CC for `delta` detents (binary-offset,
 * clamped to -64..+63) into `buf`. Returns 3. */
int pedal_encode_encoder(int delta, uint8_t channel, uint8_t* buf);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_PEDAL_PROTOCOL_H */
