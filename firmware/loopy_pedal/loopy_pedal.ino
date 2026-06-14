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

// ---- hardware layout (adjust to the physical build; see README pin map) -----

// FastLED ring + indicators. The first PEDAL_TRACK_COUNT LEDs are the per-track
// indicators (all 8 tracks; the active bank is the rendered set), the next is
// the global/mode LED, and the remainder form the loop-position ring.
static const uint8_t kLedPin = 6;
static const uint8_t kNumLeds = 19;
static const uint8_t kGlobalLed = PEDAL_TRACK_COUNT; // index 8
static const uint8_t kRingStart = PEDAL_TRACK_COUNT + 1; // index 9
static const uint8_t kRingCount = kNumLeds - kRingStart; // 10
static CRGB g_leds[kNumLeds];

// The 10 footswitches, indexed by PEDAL_BTN_*; active-low with INPUT_PULLUP.
static const uint8_t kButtonPins[PEDAL_BTN_COUNT] = {
    2, 3, 4, 5, 7, 8, 9, 10, 11, 12};
static const uint8_t kEncoderPinA = A0;
static const uint8_t kEncoderPinB = A1;

static const unsigned long kDebounceMs = 10;
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

static bool g_btnState[PEDAL_BTN_COUNT];
static unsigned long g_btnChangedMs[PEDAL_BTN_COUNT];
static uint8_t g_encPrev = 0;

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
      return CRGB(255, 120, 0);
    case PEDAL_GLOBAL_BLUE:
      return CRGB::Blue;
    default:
      return CRGB::Black;
  }
}

static void renderRing() {
  // One revolution per loop: interpolate the head position from the time since
  // the last loop-top pulse and the loop length. Idle (no loop) shows a dim
  // breathing dot at the top.
  if (!g_haveFrame || g_frame.loop_length_micros == 0) {
    for (uint8_t i = 0; i < kRingCount; i++) g_leds[kRingStart + i] = CRGB::Black;
    const uint8_t pulse = (uint8_t)((millis() / 4) & 0x3F);
    g_leds[kRingStart] = CRGB(0, 0, pulse);
    return;
  }
  const unsigned long loopMs = g_frame.loop_length_micros / 1000UL;
  const unsigned long elapsed = millis() - g_lastLoopTopMs;
  const unsigned long pos = (loopMs > 0) ? (elapsed % loopMs) : 0;
  const uint8_t head = (uint8_t)((pos * kRingCount) / (loopMs ? loopMs : 1));
  for (uint8_t i = 0; i < kRingCount; i++) {
    g_leds[kRingStart + i] = (i == head) ? CRGB::White : CRGB(0, 0, 16);
  }
}

static void render() {
  if (g_haveFrame) {
    for (uint8_t i = 0; i < PEDAL_TRACK_COUNT; i++) {
      g_leds[i] = ledColor(g_frame.track_leds[i]);
    }
    g_leds[kGlobalLed] = globalColor(g_frame.global_color);
  } else {
    for (uint8_t i = 0; i <= kGlobalLed; i++) g_leds[i] = CRGB::Black;
  }
  renderRing();

  // Poll MIDI immediately before and after the interrupt-blocking show().
  pollMidiIn();
  FastLED.show();
  pollMidiIn();
}

// ---- inputs -----------------------------------------------------------------

static void pollButtons() {
  const unsigned long now = millis();
  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    const bool pressed = (digitalRead(kButtonPins[i]) == LOW); // active-low
    if (pressed == g_btnState[i]) continue;
    if (now - g_btnChangedMs[i] < kDebounceMs) continue; // contact debounce
    g_btnState[i] = pressed;
    g_btnChangedMs[i] = now;
    uint8_t msg[3];
    const int len = pedal_encode_button(i, pressed ? 1 : 0, kMidiChannel, msg);
    sendBytes(msg, len);
  }
}

// Minimal quadrature decode: emit +/-1 detent per state transition.
static void pollEncoder() {
  const uint8_t a = (digitalRead(kEncoderPinA) == HIGH) ? 1 : 0;
  const uint8_t b = (digitalRead(kEncoderPinB) == HIGH) ? 1 : 0;
  const uint8_t state = (uint8_t)((a << 1) | b);
  if (state == g_encPrev) return;
  // Gray-code direction: compare the new state to the previous.
  static const int8_t kStep[4][4] = {
      {0, -1, 1, 0}, {1, 0, 0, -1}, {-1, 0, 0, 1}, {0, 1, -1, 0}};
  const int8_t delta = kStep[g_encPrev][state];
  g_encPrev = state;
  if (delta == 0) return;
  uint8_t msg[3];
  const int len = pedal_encode_encoder(delta, kMidiChannel, msg);
  sendBytes(msg, len);
}

// ---- lifecycle --------------------------------------------------------------

void setup() {
  Serial.begin(31250); // serial MIDI (dualMocoLUFA on the 16U2)
  FastLED.addLeds<WS2812B, kLedPin, GRB>(g_leds, kNumLeds);
  FastLED.setBrightness(64);

  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(kButtonPins[i], INPUT_PULLUP);
    g_btnState[i] = false;
    g_btnChangedMs[i] = 0;
  }
  pinMode(kEncoderPinA, INPUT_PULLUP);
  pinMode(kEncoderPinB, INPUT_PULLUP);

  // Brief startup sweep so the user sees the pedal is alive before loopy binds.
  for (uint8_t i = 0; i < kNumLeds; i++) {
    g_leds[i] = CRGB(0, 24, 0);
    FastLED.show();
    delay(15);
    g_leds[i] = CRGB::Black;
  }
  FastLED.show();
}

void loop() {
  pollMidiIn();
  pollButtons();
  pollEncoder();
  render(); // polls MIDI around show()
}
