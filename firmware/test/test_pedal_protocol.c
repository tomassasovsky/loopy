/*
 * test_pedal_protocol.c - host-compiled contract test for the pedal firmware's
 * SysEx codec (pedal_protocol.c).
 *
 * It links the SAME translation unit the Arduino sketch #includes and asserts it
 * against the committed golden fixtures loopy's Dart codec generated
 * (packages/pedal_repository/test/fixtures/<name>.syx). For each fixture it:
 *   1. decodes the bytes -> pedal_frame (the firmware's inbound path), and
 *   2. re-encodes the frame and checks it reproduces the fixture byte-for-byte,
 * proving both sides speak the identical wire format. It also checks the field
 * decode of the two richest fixtures, malformed-frame rejection, the identity
 * request, and the outbound Note / encoder encoders. No board required — runs in
 * CI exactly like the engine's native MIDI suite.
 *
 * Build & run (from the repo root, so the default fixtures path resolves):
 *   gcc -std=c11 -I firmware/loopy_pedal \
 *     firmware/test/test_pedal_protocol.c firmware/loopy_pedal/pedal_protocol.c \
 *     -o pedal_protocol_tests && ./pedal_protocol_tests
 * Or pass the fixtures dir explicitly:
 *   ./pedal_protocol_tests packages/pedal_repository/test/fixtures
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "pedal_protocol.h"

static int g_failures = 0;

#define CHECK(cond)                                      \
  do {                                                   \
    if (!(cond)) {                                       \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                      \
    }                                                    \
  } while (0)

static const char* g_fixtures_dir = "packages/pedal_repository/test/fixtures";

/* Reads a whole fixture file into `buf`; returns its length, or -1 on error. */
static int read_fixture(const char* name, uint8_t* buf, int cap) {
  char path[512];
  snprintf(path, sizeof(path), "%s/%s.syx", g_fixtures_dir, name);
  FILE* f = fopen(path, "rb");
  if (f == NULL) {
    printf("  FAIL: cannot open fixture %s\n", path);
    return -1;
  }
  const size_t n = fread(buf, 1, (size_t)cap, f);
  fclose(f);
  return (int)n;
}

/* Decodes a fixture, re-encodes it, and asserts the round-trip is byte-exact. */
static int decode_fixture(const char* name, pedal_frame* out) {
  uint8_t bytes[64];
  const int len = read_fixture(name, bytes, sizeof(bytes));
  if (len < 0) return 0;

  if (!pedal_decode_frame(bytes, len, out)) {
    printf("  FAIL: %s did not decode\n", name);
    g_failures++;
    return 0;
  }
  uint8_t reencoded[PEDAL_FRAME_MAX_BYTES];
  const int rlen = pedal_encode_frame(out, reencoded);
  if (rlen != len || memcmp(reencoded, bytes, (size_t)len) != 0) {
    printf("  FAIL: %s did not round-trip to identical bytes\n", name);
    g_failures++;
    return 0;
  }
  return 1;
}

static void test_golden_round_trip(void) {
  printf("test_golden_round_trip\n");
  static const char* kNames[] = {
      "blank_goodbye",    "idle_rec",  "recording_track1",
      "playing_bankb",    "clear_fade", "performance_armed",
  };
  pedal_frame frame;
  for (size_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++) {
    decode_fixture(kNames[i], &frame);
  }
}

static void test_decode_fields_recording_track1(void) {
  printf("test_decode_fields_recording_track1\n");
  pedal_frame f;
  if (!decode_fixture("recording_track1", &f)) return;
  CHECK(f.global_color == PEDAL_GLOBAL_RED);
  CHECK(f.track_leds[0] == PEDAL_LED_RED);
  CHECK(f.track_leds[1] == PEDAL_LED_OFF);
  CHECK(f.active_bank == 0);
  CHECK(f.armed_track == 0);
  CHECK(f.play_mode == 0);
  CHECK(f.clear_fade == 0);
  CHECK(f.goodbye == 0);
  CHECK(f.loop_length_micros == 0);
}

static void test_decode_fields_playing_bankb(void) {
  printf("test_decode_fields_playing_bankb\n");
  pedal_frame f;
  if (!decode_fixture("playing_bankb", &f)) return;
  CHECK(f.global_color == PEDAL_GLOBAL_AMBER);
  CHECK(f.play_mode == 1);
  CHECK(f.active_bank == 1);
  CHECK(f.armed_track == 4);
  for (int i = 0; i < 4; i++) CHECK(f.track_leds[i] == PEDAL_LED_GREEN);
  for (int i = 4; i < 8; i++) CHECK(f.track_leds[i] == PEDAL_LED_OFF);
  CHECK(f.loop_length_micros == 1500000u);
  CHECK(f.master_gain == 153); /* 153/255 ~= 0.6, the frame's masterGain */
}

static void test_decode_fields_clear_fade(void) {
  printf("test_decode_fields_clear_fade\n");
  pedal_frame f;
  if (!decode_fixture("clear_fade", &f)) return;
  CHECK(f.global_color == PEDAL_GLOBAL_BLUE);
  CHECK(f.clear_fade == 1);
  CHECK(f.armed_track == 3);
  CHECK(f.track_leds[0] == PEDAL_LED_GREEN);
  CHECK(f.track_leds[1] == PEDAL_LED_RED);
  CHECK(f.track_leds[2] == PEDAL_LED_OFF);
  CHECK(f.track_leds[3] == PEDAL_LED_GREEN);
  /* The near-max 32-bit little-endian loop length must survive 7-bit packing. */
  CHECK(f.loop_length_micros == 0xFEDCBA98u);
}

static void test_goodbye_flag(void) {
  printf("test_goodbye_flag\n");
  pedal_frame f;
  if (!decode_fixture("blank_goodbye", &f)) return;
  CHECK(f.goodbye == 1);
  CHECK(f.global_color == PEDAL_GLOBAL_OFF);
  for (int i = 0; i < 8; i++) CHECK(f.track_leds[i] == PEDAL_LED_OFF);
}

/* D-PEDAL: the performance-armed flag (flags bit3) round-trips independent
 * of the other flag bits, and a pre-D-PEDAL frame (bit3 never set) still
 * decodes cleanly with performance_armed == 0 (old-firmware back-compat —
 * every existing fixture predates this flag). */
static void test_performance_armed_flag(void) {
  printf("test_performance_armed_flag\n");
  pedal_frame f;
  if (!decode_fixture("performance_armed", &f)) return;
  CHECK(f.performance_armed == 1);
  CHECK(f.global_color == PEDAL_GLOBAL_GREEN);
  CHECK(f.track_leds[0] == PEDAL_LED_RED);

  static const char* kOldStyle[] = {
      "blank_goodbye", "idle_rec", "recording_track1", "playing_bankb",
      "clear_fade",
  };
  for (size_t i = 0; i < sizeof(kOldStyle) / sizeof(kOldStyle[0]); i++) {
    pedal_frame old;
    if (decode_fixture(kOldStyle[i], &old)) {
      CHECK(old.performance_armed == 0);
    }
  }
}

static void test_malformed_frames_are_rejected(void) {
  printf("test_malformed_frames_are_rejected\n");
  uint8_t bytes[64];
  const int len = read_fixture("idle_rec", bytes, sizeof(bytes));
  if (len < 0) return;
  pedal_frame f;

  /* A good frame decodes; mutating any guard byte must make it fail. */
  CHECK(pedal_decode_frame(bytes, len, &f) == 1);

  uint8_t bad[64];
  memcpy(bad, bytes, (size_t)len);
  bad[len - 2] ^= 0x01; /* corrupt the checksum */
  CHECK(pedal_decode_frame(bad, len, &f) == 0);

  memcpy(bad, bytes, (size_t)len);
  bad[2] = 0x02; /* unknown protocol version */
  CHECK(pedal_decode_frame(bad, len, &f) == 0);

  memcpy(bad, bytes, (size_t)len);
  bad[1] = 0x7E; /* wrong manufacturer id */
  CHECK(pedal_decode_frame(bad, len, &f) == 0);

  /* A truncated (partial) frame is discarded, not read past. */
  CHECK(pedal_decode_frame(bytes, len - 3, &f) == 0);
  CHECK(pedal_decode_frame(bytes, 5, &f) == 0);
  /* Not a SysEx at all. */
  const uint8_t note[3] = {0x90, 0x00, 0x7F};
  CHECK(pedal_decode_frame(note, 3, &f) == 0);

  /* Out-of-range payload fields (checksum-valid, correctly-framed, but a
   * field value the decoder must still reject). Mutate a copy of the
   * known-good decoded frame, re-encode it (pedal_encode_frame does not
   * itself validate ranges), and confirm decode now rejects it. */
  uint8_t reencoded[PEDAL_FRAME_MAX_BYTES];
  pedal_frame mutated;

  mutated = f;
  mutated.global_color = PEDAL_GLOBAL_COUNT; /* one past the last valid color */
  int rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.active_bank = 2; /* only 0 (A) and 1 (B) are valid */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.armed_track = PEDAL_TRACK_COUNT; /* one past the last valid track */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);

  mutated = f;
  mutated.track_leds[0] = PEDAL_LED_COUNT; /* one past the last valid LED */
  rlen = pedal_encode_frame(&mutated, reencoded);
  CHECK(pedal_decode_frame(reencoded, rlen, &f) == 0);
}

static void test_identity_request(void) {
  printf("test_identity_request\n");
  const uint8_t req[6] = {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7};
  CHECK(pedal_is_identity_request(req, 6) == 1);
  const uint8_t other[6] = {0xF0, 0x7D, 0x01, 0x01, 0x00, 0xF7};
  CHECK(pedal_is_identity_request(other, 6) == 0);
  CHECK(pedal_is_identity_request(req, 5) == 0);
}

static void test_button_and_encoder_encode(void) {
  printf("test_button_and_encoder_encode\n");
  uint8_t buf[3];

  CHECK(pedal_encode_button(PEDAL_BTN_REC_PLAY, 1, 0, buf) == 3);
  CHECK(buf[0] == 0x90 && buf[1] == 0 && buf[2] == 127); /* NoteOn */
  pedal_encode_button(PEDAL_BTN_CLEAR, 0, 0, buf);
  CHECK(buf[0] == 0x80 && buf[1] == 8 && buf[2] == 0); /* NoteOff */

  pedal_encode_encoder(6, 0, buf);
  CHECK(buf[0] == 0xB0 && buf[1] == PEDAL_ENCODER_CC && buf[2] == 70);
  pedal_encode_encoder(-6, 0, buf);
  CHECK(buf[2] == 58);
  pedal_encode_encoder(1000, 0, buf); /* clamps to +63 */
  CHECK(buf[2] == 127);
  pedal_encode_encoder(-1000, 0, buf); /* clamps to -64 */
  CHECK(buf[2] == 0);
}

int main(int argc, char** argv) {
  if (argc > 1) g_fixtures_dir = argv[1];

  test_golden_round_trip();
  test_decode_fields_recording_track1();
  test_decode_fields_playing_bankb();
  test_decode_fields_clear_fade();
  test_goodbye_flag();
  test_performance_armed_flag();
  test_malformed_frames_are_rejected();
  test_identity_request();
  test_button_and_encoder_encode();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
