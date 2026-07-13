/*
 * loopy_pedal.ino - firmware for the loopy bidirectional MIDI looper pedal.
 *
 * A PURE THIN CLIENT. It holds NO looper state: it renders LEDs only from the
 * last good state frame loopy pushes, and sends raw footswitch / encoder events.
 * loopy runs the behavior machine and is the single source of truth. This
 * eliminates the old firmware's State[] that drifted from the app.
 *
 * Transport: serial MIDI at 31250 baud through the ATmega16U2 reflashed with
 * dualMocoLUFA (see README). The 8-bit AVR cannot use the MIDIUSB library.
 *
 * The wire protocol lives in pedal_protocol.c/.h (the same unit loopy's host
 * test checks against the golden fixtures), so this sketch never hand-rolls the
 * SysEx framing.
 *
 * FastLED note: FastLED.show() disables interrupts (~30 us/LED), long enough to
 * drop an inbound serial MIDI byte at 31250 baud. So we poll MIDI immediately
 * before AND after every show(), and frames are checksum-guarded + refreshed by
 * loopy ~1 Hz so a dropped frame self-heals. The loop-top spin is a single
 * real-time byte (0xFA), which survives the interrupt gap far better than a
 * multi-byte SysEx.
 */
#include <FastLED.h>

#include "pedal_protocol.h"

// ---- hardware layout — matches the physical "aquiles LoopStation" wiring -----

// The WS2812B strip is 19 LEDs on pin D2: a 12-LED loop-position ring (indices
// 0..11) followed by 7 indicator LEDs (mode, the 4 active-bank tracks, clear,
// and the bank LED). This mirrors the original firmware's LED map.
static const uint8_t kLedPin = 2;
static const uint8_t kNumLeds = 19;
static const uint8_t kRingStart = 0;  // loop-position ring = LEDs 0..11
static const uint8_t kRingCount = 12;
static const uint8_t kModeLed = 12;   // global transport-activity color
static const uint8_t kTrackLed0 = 13; // active-bank tracks 1..4 = LEDs 13..16
static const uint8_t kClearLed = 17;  // lit during a clear fade
static const uint8_t kBankLed = 18;   // lit when bank B is active
static CRGB g_leds[kNumLeds];  // logical frame the renderer writes (nominal color)
static CRGB g_out[kNumLeds];   // gamma-corrected copy FastLED actually clocks out

// The 10 footswitches, indexed by PEDAL_BTN_* (recPlay, stop, undo, mode,
// track1..4, clear, bank); active-low with INPUT_PULLUP. Matches the original
// wiring D3..D12 (the original "Next" switch on A2 is dropped in this layout).
static const uint8_t kButtonPins[PEDAL_BTN_COUNT] = {
    3,  // recPlay
    4,  // stop
    5,  // undo
    6,  // mode
    7,  // track1
    8,  // track2
    9,  // track3
    10, // track4
    11, // clear
    12, // bank
};
// Rotary encoder: clock A0, data A1 (the push switch on A2 is unused in v1).
static const uint8_t kEncoderClk = A0;
static const uint8_t kEncoderDat = A1;

static const unsigned long kDebounceMs = 25; // foot-switch contact debounce
static const uint8_t kMidiChannel = 0; // channel 1 (0-based on the wire)

// ---- inbound state ----------------------------------------------------------

static pedal_frame g_frame;       // last good frame loopy pushed
static bool g_haveFrame = false;  // false until the first valid frame
static uint8_t g_sysex[40];
static uint8_t g_sysexLen = 0;
static bool g_inSysex = false;

// Loop-position interpolation: time of the last loop-top pulse + loop length.
static unsigned long g_lastLoopTopMs = 0;

// ---- button / encoder debounce state ----------------------------------------

static bool g_btnStable[PEDAL_BTN_COUNT];  // last debounced (reported) state
static bool g_btnLastRaw[PEDAL_BTN_COUNT]; // previous raw sample
static unsigned long g_btnRawSinceMs[PEDAL_BTN_COUNT]; // when raw last changed
static uint8_t g_encClkPrev = 0;

// ---- MIDI out ---------------------------------------------------------------

static void sendBytes(const uint8_t* data, int len) {
  Serial.write(data, len);
}

// The pedal's identity reply: a fixed family signature loopy recognizes. Sent in
// response to the Universal Identity Request. (loopy does not parse it in v1 —
// its 3-byte input capture cannot receive SysEx — but the firmware answers per
// the spec for a future inbound path.)
static void sendIdentityReply() {
  static const uint8_t kReply[] = {
      0xF0, 0x7E, 0x7F, 0x06, 0x02, PEDAL_MANUFACTURER_ID,
      0x4C, 0x50, // family "LP"
      0x01, 0x00, // member
      0x01, 0x00, 0x00, 0x00, // revision
      0xF7};
  sendBytes(kReply, sizeof(kReply));
}

// ---- inbound MIDI -----------------------------------------------------------

static void handleSysex(const uint8_t* msg, int len) {
  if (pedal_is_identity_request(msg, len)) {
    sendIdentityReply();
    return;
  }
  pedal_frame decoded;
  if (pedal_decode_frame(msg, len, &decoded)) {
    g_frame = decoded;
    g_haveFrame = true;
  }
  // A malformed frame is silently dropped; the last good frame is retained.
}

static void onLoopTop() {
  g_lastLoopTopMs = millis();
}

// Drains all available serial bytes, assembling SysEx and handling interleaved
// real-time messages (the loop-top pulse) without corrupting the SysEx buffer.
static void pollMidiIn() {
  while (Serial.available() > 0) {
    const uint8_t b = (uint8_t)Serial.read();
    if (b == PEDAL_LOOP_TOP) {
      onLoopTop();
      continue; // real-time: may interleave inside a SysEx
    }
    if (b >= 0xF8) {
      continue; // other real-time: ignore, do not disturb a SysEx in progress
    }
    if (b == PEDAL_SYSEX_START) {
      g_sysexLen = 0;
      g_inSysex = true;
      g_sysex[g_sysexLen++] = b;
      continue;
    }
    if (!g_inSysex) {
      continue; // loopy sends only SysEx + real-time; ignore stray bytes
    }
    if (g_sysexLen >= sizeof(g_sysex)) {
      g_inSysex = false; // overflow: drop this (partial) frame
      continue;
    }
    g_sysex[g_sysexLen++] = b;
    if (b == PEDAL_SYSEX_END) {
      g_inSysex = false;
      handleSysex(g_sysex, g_sysexLen);
    }
  }
}

// ---- rendering --------------------------------------------------------------

static CRGB ledColor(uint8_t led) {
  switch (led) {
    case PEDAL_LED_GREEN:
      return CRGB::Green;
    case PEDAL_LED_RED:
      return CRGB::Red;
    default:
      return CRGB::Black;
  }
}

static CRGB globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN:
      return CRGB::Green;
    case PEDAL_GLOBAL_RED:
      return CRGB::Red;
    case PEDAL_GLOBAL_AMBER:
      return CRGB(255, 150, 0);
    case PEDAL_GLOBAL_BLUE:
      return CRGB::Blue;
    default:
      return CRGB::Black;
  }
}

static CRGB scaled(CRGB c, uint8_t level) {
  c.nscale8_video(level);
  return c;
}

// A smooth brightness hump rotates around the ring: brightness =
// 1 - (d/kRingWidth)^kRingShape, clamped to 0, where d is the circular distance
// (in LEDs) from an advancing center. Independent of loop length. A Stop that
// leaves a loop loaded FREEZES the ring in place (the phase stops advancing) so
// the last playhead position stays lit; clearing the loop instead keeps the
// hump advancing in the now-off color, so the ring animates to dark rather than
// freezing a lit pixel. It never shows a blue idle dot. Tune: kRingMsPerRev
// (lower = faster), kRingWidth (LEDs lit each side), kRingShape (2 = parabola).
static const unsigned long kRingMsPerRev = 700;
static const float kRingWidth = 5.5f;
static const float kRingShape = 1.5f;
static float g_ringPhase = 0.0f;       // current center, 0..kRingCount
static unsigned long g_ringLastMs = 0; // for dt-based phase advance

static void renderRing() {
  // Colored by the activity color loopy sends in global_color: red recording /
  // amber overdubbing / green playing.
  const CRGB activity = g_haveFrame ? globalColor(g_frame.global_color)
                                    : CRGB::Black;
  const bool goodbye = g_haveFrame && g_frame.goodbye;
  const bool active = g_haveFrame && !goodbye &&
                      (activity.r || activity.g || activity.b) &&
                      g_frame.global_color != PEDAL_GLOBAL_BLUE;
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;
  if (goodbye) { // shutdown frame: darken the ring
    for (uint8_t i = 0; i < kRingCount; i++) g_leds[kRingStart + i] = CRGB::Black;
    return;
  }
  // A Stop with a loop still loaded freezes the ring where it was. Once the
  // loop is cleared (nothing left to play) fall through so the hump keeps
  // advancing in the off color and the ring animates to dark.
  if (!active && g_frame.loop_length_micros > 0) return;
  // Advance the center only while active, so a Stop leaves it where it was.
  g_ringPhase += (float)dt / (float)kRingMsPerRev * (float)kRingCount;
  while (g_ringPhase >= (float)kRingCount) g_ringPhase -= (float)kRingCount;
  for (uint8_t i = 0; i < kRingCount; i++) {
    float d = fabsf((float)i - g_ringPhase);
    if (d > kRingCount / 2.0f) d = kRingCount - d; // wrap the short way round
    const float dn = d / kRingWidth;
    uint8_t level = 0;
    if (dn < 1.0f) {
      float b = 1.0f - powf(dn, kRingShape);
      if (b < 0.0f) b = 0.0f;
      level = (uint8_t)(b * 255.0f + 0.5f);
    }
    g_leds[kRingStart + i] = scaled(activity, level);
  }
}

// Performance-recording armed (D-PEDAL): the mode LED (12) BLINKS red instead
// of showing its usual transport-activity color, distinct eyes-free from
// looper-recording's own SOLID red (PEDAL_GLOBAL_RED). Half-period matches
// the on-screen simulator's `_BlinkingLed` (400 ms) for parity.
static const unsigned long kBlinkHalfPeriodMs = 400;

// ---- perceptual gamma correction --------------------------------------------

// A WS2812's duty cycle is linear but the eye's brightness response is not, so a
// linear ramp looks top-heavy: the dim steps of the ring's rotating brightness
// hump crowd together while the bright end barely changes. We map every channel
// through a gamma 2.8 curve at OUTPUT time (g_leds -> g_out) so the ramp reads
// evenly. Doing it into a SEPARATE display buffer — not in place — matters: the
// frozen-playhead ring holds its last logical frame without redrawing, so an
// in-place correction would darken it a little more every show() until it decays
// to black. Copying from the untouched logical frame each time is idempotent.
//
// The table is mirrored in hardware/firmware/loopy_pedal_32u4 — keep them in sync.
static const uint8_t kGamma8[256] PROGMEM = {
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,
    1,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,
    2,   3,   3,   3,   3,   3,   3,   3,   4,   4,   4,   4,   4,   5,   5,   5,
    5,   6,   6,   6,   6,   7,   7,   7,   7,   8,   8,   8,   9,   9,   9,  10,
   10,  10,  11,  11,  11,  12,  12,  13,  13,  13,  14,  14,  15,  15,  16,  16,
   17,  17,  18,  18,  19,  19,  20,  20,  21,  21,  22,  22,  23,  24,  24,  25,
   25,  26,  27,  27,  28,  29,  29,  30,  31,  32,  32,  33,  34,  35,  35,  36,
   37,  38,  39,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  50,
   51,  52,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,  66,  67,  68,
   69,  70,  72,  73,  74,  75,  77,  78,  79,  81,  82,  83,  85,  86,  87,  89,
   90,  92,  93,  95,  96,  98,  99, 101, 102, 104, 105, 107, 109, 110, 112, 114,
  115, 117, 119, 120, 122, 124, 126, 127, 129, 131, 133, 135, 137, 138, 140, 142,
  144, 146, 148, 150, 152, 154, 156, 158, 160, 162, 164, 167, 169, 171, 173, 175,
  177, 180, 182, 184, 186, 189, 191, 193, 196, 198, 200, 203, 205, 208, 210, 213,
  215, 218, 220, 223, 225, 228, 231, 233, 236, 239, 241, 244, 247, 249, 252, 255,
};
static inline uint8_t gamma8(uint8_t x) { return pgm_read_byte(&kGamma8[x]); }

// Gamma-correct the logical frame into the display buffer, then latch it. Drop-in
// replacement for FastLED.show() — global brightness is still applied by show().
static void showGamma() {
  for (uint8_t i = 0; i < kNumLeds; i++) {
    g_out[i].r = gamma8(g_leds[i].r);
    g_out[i].g = gamma8(g_leds[i].g);
    g_out[i].b = gamma8(g_leds[i].b);
  }
  FastLED.show();
}

static void render() {
  renderRing(); // the loop-position ring, LEDs 0..11
  if (g_haveFrame) {
    // Active bank's 4 tracks on the physical Tr1..Tr4 LEDs — solid color from
    // each track's LED state. The selected/armed track is NOT highlighted here
    // (no breathing, no blue dot); selection is shown on loopy's screen.
    const uint8_t base = g_frame.active_bank * 4; // bank A: 0..3, bank B: 4..7
    for (uint8_t i = 0; i < 4; i++) {
      g_leds[kTrackLed0 + i] = ledColor(g_frame.track_leds[base + i]);
    }
    if (g_frame.performance_armed) {
      const bool blinkOn = (millis() / kBlinkHalfPeriodMs) % 2 == 0;
      g_leds[kModeLed] = blinkOn ? CRGB::Red : CRGB::Black;
    } else {
      // LED 12 shows transport activity from loopy's global_color: green
      // playing, red recording, amber overdubbing, blue during a clear fade —
      // and green when idle (off = not recording). The pedal's Rec/Play mode
      // is no longer shown here.
      g_leds[kModeLed] = (g_frame.global_color == PEDAL_GLOBAL_OFF)
                             ? CRGB::Green
                             : globalColor(g_frame.global_color);
    }
    g_leds[kClearLed] = g_frame.clear_fade ? CRGB::Red : CRGB::Black;
    g_leds[kBankLed] = (g_frame.active_bank == 1) ? CRGB(0, 0, 80) : CRGB::Black;
  } else {
    g_leds[kModeLed] = CRGB::Black;
    g_leds[kClearLed] = CRGB::Black;
    g_leds[kBankLed] = CRGB::Black;
    for (uint8_t i = 0; i < 4; i++) g_leds[kTrackLed0 + i] = CRGB::Black;
  }

  // Poll MIDI immediately before and after the interrupt-blocking show().
  pollMidiIn();
  showGamma();
  pollMidiIn();
}

// ---- inputs -----------------------------------------------------------------

static void pollButtons() {
  const unsigned long now = millis();
  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    const bool raw = (digitalRead(kButtonPins[i]) == LOW); // active-low
    // Restart the stability timer whenever the raw reading flips. Contact
    // chatter keeps resetting it, so a change is only reported once the line has
    // been steady for kDebounceMs — a proper stable-for-N-ms debounce on both
    // the press and the release edges (no single-stomp double-triggers).
    if (raw != g_btnLastRaw[i]) {
      g_btnLastRaw[i] = raw;
      g_btnRawSinceMs[i] = now;
      continue;
    }
    if (raw != g_btnStable[i] && (now - g_btnRawSinceMs[i]) >= kDebounceMs) {
      g_btnStable[i] = raw;
      uint8_t msg[3];
      const int len = pedal_encode_button(i, raw ? 1 : 0, kMidiChannel, msg);
      sendBytes(msg, len);
    }
  }
}

// Encoder decode, matching the original firmware: on each clock edge, the data
// line's level vs. the clock gives the direction. Emits one relative ±1 CC per
// edge.
static void pollEncoder() {
  const uint8_t clk = (digitalRead(kEncoderClk) == HIGH) ? 1 : 0;
  if (clk == g_encClkPrev) return;
  g_encClkPrev = clk;
  const uint8_t dat = (digitalRead(kEncoderDat) == HIGH) ? 1 : 0;
  const int delta = (dat != clk) ? 1 : -1;
  uint8_t msg[3];
  const int len = pedal_encode_encoder(delta, kMidiChannel, msg);
  sendBytes(msg, len);
}

// ---- lifecycle --------------------------------------------------------------

void setup() {
  Serial.begin(31250); // serial MIDI (dualMocoLUFA on the 16U2)
  FastLED.addLeds<WS2812B, kLedPin, GRB>(g_out, kNumLeds);
  FastLED.setBrightness(64);

  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(kButtonPins[i], INPUT_PULLUP);
    g_btnStable[i] = false;  // released at boot
    g_btnLastRaw[i] = false;
    g_btnRawSinceMs[i] = 0;
  }
  pinMode(kEncoderClk, INPUT_PULLUP);
  pinMode(kEncoderDat, INPUT_PULLUP);
  g_encClkPrev = (digitalRead(kEncoderClk) == HIGH) ? 1 : 0;

  // Brief startup sweep so the user sees the pedal is alive before loopy binds.
  for (uint8_t i = 0; i < kNumLeds; i++) {
    g_leds[i] = CRGB(0, 24, 0);
    showGamma();
    delay(15);
    g_leds[i] = CRGB::Black;
  }
  showGamma();
}

void loop() {
  pollMidiIn();
  pollButtons();
  pollEncoder();
  render(); // polls MIDI around show()
}
