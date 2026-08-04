/*
 * test_pedal_protocol.c - host-compiled contract test for the pedal firmware's
 * SysEx codec (pedal_protocol.c).
 *
 * It links the SAME translation unit the Arduino sketch #includes and asserts it
 * against the committed golden fixtures segno's Dart codec generated
 * (packages/pedal_repository/test/fixtures/<name>.syx). For each fixture it:
 *   1. decodes the bytes -> pedal_frame (the firmware's inbound path), and
 *   2. re-encodes the frame and checks it reproduces the fixture byte-for-byte,
 * proving both sides speak the identical wire format. It also checks the field
 * decode of the richest fixtures (protocol v2's looper-mode / counting-in
 * fields, D11, and protocol v3's 2-bit interaction mode + chain-state LEDs,
 * FX v3 part 5a), the full v1/v2/v3 app x firmware protocol-version matrix
 * (test_version_pairings), the B10 fx->play downgrade twins, malformed-frame
 * rejection, the identity request, and the outbound Note / encoder encoders.
 * No board required — runs in CI exactly like the engine's native MIDI suite.
 *
 * Build & run via the shared runner (from the repo root), which builds this
 * file against BOTH protocol copies and fails on any drift between them:
 *   bash firmware/test/run_tests.sh
 * Or by hand (repo root, so the default fixtures path resolves):
 *   gcc -std=c11 -I firmware/segno_pedal \
 *     firmware/test/test_pedal_protocol.c firmware/segno_pedal/pedal_protocol.c \
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
      "blank_goodbye",     "idle_rec",   "recording_track1",
      "playing_bankb",     "clear_fade", "performance_armed",
      /* protocol v2 (D11): full looper-mode + counting-in fidelity. */
      "mode_counting_in",
      /* protocol v1, explicit (D11): same logical content as idle_rec,
       * pinned onto the legacy wire -- see test_version_pairings. */
      "idle_rec_v1",
      /* protocol v3 (part 5a): fx mode + blue chain-state LEDs, plus the
       * same frame downgraded onto the v2 and v1 wires (B10) -- see
       * test_fx_downgrade_twins. */
      "fx_mode_v3", "fx_mode_v2", "fx_mode_v1",
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

/* D11: the looper-mode + counting-in fields (protocol v2). */
static void test_decode_fields_mode_counting_in(void) {
  printf("test_decode_fields_mode_counting_in\n");
  pedal_frame f;
  if (!decode_fixture("mode_counting_in", &f)) return;
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_SYNC);
  CHECK(f.counting_in == 1);
  CHECK(f.global_color == PEDAL_GLOBAL_AMBER);
  CHECK(f.play_mode == 1);
  CHECK(f.active_bank == 0);
  CHECK(f.armed_track == 2);
  CHECK(f.track_leds[0] == PEDAL_LED_GREEN);
  for (int i = 1; i < 8; i++) CHECK(f.track_leds[i] == PEDAL_LED_OFF);
  CHECK(f.loop_length_micros == 750000u);
  CHECK(f.protocol_version == PEDAL_PROTOCOL_VERSION_V2);
}

/* D11, code-review follow-up: the golden fixtures above only ever exercise
 * looper_mode SYNC (1 = 0b001) or the MULTI default (0 = 0b000) -- both fit
 * in 2 bits, so a mask bug like `& 0x03` instead of `& 0x07` on either the
 * encode or decode side is invisible to them. FREE (4 = 0b100) is the only
 * value that needs bit 6 (the third bit of the nibble) to survive, so this
 * drives pedal_encode_frame -> pedal_decode_frame for every defined value
 * -- not hand-built bytes -- and would fail if that bit were ever dropped. */
static void test_looper_mode_round_trip_every_value(void) {
  printf("test_looper_mode_round_trip_every_value\n");
  static const uint8_t kModes[] = {
      PEDAL_LOOPER_MODE_MULTI, PEDAL_LOOPER_MODE_SYNC, PEDAL_LOOPER_MODE_SONG,
      PEDAL_LOOPER_MODE_BAND,  PEDAL_LOOPER_MODE_FREE,
  };
  for (size_t i = 0; i < sizeof(kModes) / sizeof(kModes[0]); i++) {
    pedal_frame frame;
    memset(&frame, 0, sizeof(frame));
    frame.global_color = PEDAL_GLOBAL_GREEN;
    frame.looper_mode = kModes[i];
    frame.counting_in = 1;
    frame.master_gain = 255;
    /* protocol_version left 0 -> pedal_encode_frame targets the newest
     * (v3, PEDAL_PROTOCOL_VERSION), which carries looper_mode just as v2
     * did. NOTE the Dart codec's own unset default deliberately stays v2
     * (the app-side R6 floor) -- see PEDAL_PROTOCOL_VERSION's doc. */

    uint8_t buf[PEDAL_FRAME_MAX_BYTES];
    const int len = pedal_encode_frame(&frame, buf);

    pedal_frame decoded;
    CHECK(pedal_decode_frame(buf, len, &decoded) == 1);
    CHECK(decoded.looper_mode == kModes[i]);
    CHECK(decoded.counting_in == 1);
  }
}

/* Part 5a: the protocol v3 fields -- the 2-bit interaction mode (FX) and
 * the blue chain-state track LED -- on the richest v3 fixture. */
static void test_decode_fields_fx_mode_v3(void) {
  printf("test_decode_fields_fx_mode_v3\n");
  pedal_frame f;
  if (!decode_fixture("fx_mode_v3", &f)) return;
  CHECK(f.play_mode == PEDAL_MODE_FX);
  CHECK(f.global_color == PEDAL_GLOBAL_GREEN);
  CHECK(f.active_bank == 1);
  CHECK(f.armed_track == 5);
  CHECK(f.track_leds[0] == PEDAL_LED_BLUE);
  CHECK(f.track_leds[1] == PEDAL_LED_OFF);
  CHECK(f.track_leds[2] == PEDAL_LED_BLUE);
  CHECK(f.track_leds[3] == PEDAL_LED_BLUE);
  CHECK(f.track_leds[6] == PEDAL_LED_BLUE);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_BAND);
  CHECK(f.counting_in == 0);
  CHECK(f.loop_length_micros == 2000000u);
  CHECK(f.master_gain == 204);
  CHECK(f.protocol_version == PEDAL_PROTOCOL_VERSION_V3);
}

/* B10: the committed downgrade fixtures are byte-for-byte what the encoder
 * itself produces from the unmodified v3 frame -- decode fx_mode_v3, then
 * re-encode it (mode still FX, LEDs still blue in the struct) at v2/v1,
 * and the bytes must equal the committed fx_mode_v2 / fx_mode_v1 fixtures.
 * This exercises the production downgrade path directly: below v3 the
 * encoder writes the mode bit as PLAY (mute) and degrades blue chain LEDs
 * to green (pre-5a firmware has PEDAL_LED_COUNT 3 and would reject the
 * whole frame on index 3). Every other byte is unchanged. */
static void test_fx_downgrade_twins(void) {
  printf("test_fx_downgrade_twins\n");
  pedal_frame fx;
  if (!decode_fixture("fx_mode_v3", &fx)) return;

  static const struct {
    const char* fixture;
    uint8_t version;
  } kTwins[] = {
      {"fx_mode_v2", PEDAL_PROTOCOL_VERSION_V2},
      {"fx_mode_v1", PEDAL_PROTOCOL_VERSION_V1},
  };
  for (size_t i = 0; i < sizeof(kTwins) / sizeof(kTwins[0]); i++) {
    uint8_t expected[64];
    const int explen =
        read_fixture(kTwins[i].fixture, expected, sizeof(expected));
    if (explen < 0) continue;

    pedal_frame twin = fx; /* mode FX, blue LEDs -- the encoder degrades */
    twin.protocol_version = kTwins[i].version;
    uint8_t reencoded[PEDAL_FRAME_MAX_BYTES];
    const int rlen = pedal_encode_frame(&twin, reencoded);
    CHECK(rlen == explen);
    CHECK(memcmp(reencoded, expected, (size_t)explen) == 0);

    /* And the downgraded wire decodes to PLAY with chain state as green --
     * exactly what pre-5a firmware (which has no blue) can render. */
    pedal_frame decoded;
    CHECK(pedal_decode_frame(expected, explen, &decoded) == 1);
    CHECK(decoded.play_mode == PEDAL_MODE_PLAY);
    CHECK(decoded.track_leds[0] == PEDAL_LED_GREEN);
    CHECK(decoded.track_leds[1] == PEDAL_LED_OFF);
  }
}

/* Part 5a: every defined interaction mode survives an encode -> decode
 * round trip at v3 (fx needs the high bit in the bank byte), and the
 * reserved fourth wire value (0b11) is rejected before anything is
 * written. */
static void test_mode_round_trip_and_reserved_value(void) {
  printf("test_mode_round_trip_and_reserved_value\n");
  static const uint8_t kModes[] = {PEDAL_MODE_REC, PEDAL_MODE_PLAY,
                                   PEDAL_MODE_FX};
  for (size_t i = 0; i < sizeof(kModes) / sizeof(kModes[0]); i++) {
    for (uint8_t bank = 0; bank <= 1; bank++) {
      pedal_frame frame;
      memset(&frame, 0, sizeof(frame));
      frame.global_color = PEDAL_GLOBAL_GREEN;
      frame.play_mode = kModes[i];
      frame.active_bank = bank;
      frame.master_gain = 255;
      frame.protocol_version = PEDAL_PROTOCOL_VERSION_V3;

      uint8_t buf[PEDAL_FRAME_MAX_BYTES];
      const int len = pedal_encode_frame(&frame, buf);
      pedal_frame decoded;
      CHECK(pedal_decode_frame(buf, len, &decoded) == 1);
      CHECK(decoded.play_mode == kModes[i]);
      CHECK(decoded.active_bank == bank);
    }
  }

  /* The reserved value: encode writes both mode bits, decode must reject. */
  pedal_frame frame;
  memset(&frame, 0, sizeof(frame));
  frame.global_color = PEDAL_GLOBAL_GREEN;
  frame.play_mode = 3; /* 0b11, one past PEDAL_MODE_FX */
  frame.master_gain = 255;
  frame.protocol_version = PEDAL_PROTOCOL_VERSION_V3;
  uint8_t buf[PEDAL_FRAME_MAX_BYTES];
  const int len = pedal_encode_frame(&frame, buf);
  pedal_frame decoded;
  CHECK(pedal_decode_frame(buf, len, &decoded) == 0);
}

/* Mirrors what a device still running older firmware does: each firmware
 * generation's decoder rejects any version byte newer than the newest it
 * was built for, before it even looks at the payload (v1 hardcoded
 * `version == 0x01`; pre-5a v2 accepted 0x01/0x02). The payload layout is
 * otherwise identical across versions (each bump only claimed reserved
 * bits), so gating on the version byte reproduces old-firmware acceptance
 * exactly, without hand-duplicating the rest of pedal_decode_frame; a v4
 * bump extends this by argument, not by another copy. Caveat: real pre-5a
 * firmware also had PEDAL_LED_COUNT 3 and would reject a frame carrying
 * the blue chain LED on the LED range -- which is why the encoder degrades
 * blue to green below v3 (see test_fx_downgrade_twins). Test-only: this is
 * not a second production decoder. */
static int legacy_decode_frame_upto(const uint8_t* msg, int len,
                                    pedal_frame* out, uint8_t max_version) {
  if (len < 3 || msg[2] < PEDAL_PROTOCOL_VERSION_V1 ||
      msg[2] > max_version) {
    return 0;
  }
  return pedal_decode_frame(msg, len, out);
}

/* The full v1/v2/v3 app x firmware protocol-version matrix (SC-8), proven
 * on three committed fixtures -- a v1-shaped frame (idle_rec_v1), a
 * v2-shaped frame (mode_counting_in), and a v3-shaped frame (fx_mode_v3) --
 * each decoded through the legacy v1-only gate, the legacy v2 gate, and the
 * current (v3-tolerant) decoder. Three fixtures x three decode gates covers
 * all nine pairings without needing nine fixture files. */
static void test_version_pairings(void) {
  printf("test_version_pairings\n");
  uint8_t v1_bytes[64];
  uint8_t v2_bytes[64];
  uint8_t v3_bytes[64];
  const int v1_len = read_fixture("idle_rec_v1", v1_bytes, sizeof(v1_bytes));
  const int v2_len =
      read_fixture("mode_counting_in", v2_bytes, sizeof(v2_bytes));
  const int v3_len = read_fixture("fx_mode_v3", v3_bytes, sizeof(v3_bytes));
  if (v1_len < 0 || v2_len < 0 || v3_len < 0) return;
  pedal_frame f;

  /* app v1 -> firmware v1 (the pre-B5a baseline pairing): decodes, no v2
   * fields -- must stay bit-identical to pre-B5a behavior. */
  CHECK(legacy_decode_frame_upto(v1_bytes, v1_len, &f, PEDAL_PROTOCOL_VERSION_V1) == 1);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_MULTI);
  CHECK(f.counting_in == 0);

  /* app v1 -> firmware v2 / v3: still decodes, degrades the same way --
   * the wire never carried anything else at v1, so there is nothing more
   * to lose. A v1 frame can never decode to PEDAL_MODE_FX. */
  CHECK(legacy_decode_frame_upto(v1_bytes, v1_len, &f, PEDAL_PROTOCOL_VERSION_V2) == 1);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_MULTI);
  CHECK(pedal_decode_frame(v1_bytes, v1_len, &f) == 1);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_MULTI);
  CHECK(f.counting_in == 0);
  CHECK(f.play_mode != PEDAL_MODE_FX);

  /* app v2 -> firmware v1: rejected outright by the version gate -- this is
   * *why* the app must detect old firmware and downgrade what it sends,
   * rather than relying on a soft per-field degrade at the receiver. */
  CHECK(legacy_decode_frame_upto(v2_bytes, v2_len, &f, PEDAL_PROTOCOL_VERSION_V1) == 0);

  /* app v2 -> firmware v2 / v3: full v2 fidelity; never fx. */
  CHECK(legacy_decode_frame_upto(v2_bytes, v2_len, &f, PEDAL_PROTOCOL_VERSION_V2) == 1);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_SYNC);
  CHECK(f.counting_in == 1);
  CHECK(pedal_decode_frame(v2_bytes, v2_len, &f) == 1);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_SYNC);
  CHECK(f.counting_in == 1);
  CHECK(f.play_mode != PEDAL_MODE_FX);

  /* app v3 -> firmware v1 / v2: rejected outright by the version gate --
   * why the app never encodes above the negotiated version (R6): unknown
   * firmware gets v2, and FX mode reaches an older pedal only as the
   * downgraded (mode = play) v2/v1 frame (see test_fx_downgrade_twins). */
  CHECK(legacy_decode_frame_upto(v3_bytes, v3_len, &f, PEDAL_PROTOCOL_VERSION_V1) == 0);
  CHECK(legacy_decode_frame_upto(v3_bytes, v3_len, &f, PEDAL_PROTOCOL_VERSION_V2) == 0);

  /* app v3 -> firmware v3: full fidelity, fx included. */
  CHECK(pedal_decode_frame(v3_bytes, v3_len, &f) == 1);
  CHECK(f.play_mode == PEDAL_MODE_FX);
  CHECK(f.looper_mode == PEDAL_LOOPER_MODE_BAND);
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
  bad[2] = 0x04; /* unknown protocol version (0x01..0x03 are valid) */
  CHECK(pedal_decode_frame(bad, len, &f) == 0);

  memcpy(bad, bytes, (size_t)len);
  bad[2] = 0x00; /* below the oldest recognized version */
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
  test_decode_fields_mode_counting_in();
  test_looper_mode_round_trip_every_value();
  test_decode_fields_fx_mode_v3();
  test_fx_downgrade_twins();
  test_mode_round_trip_and_reserved_value();
  test_version_pairings();
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
