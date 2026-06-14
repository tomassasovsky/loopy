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
static const uint8_t kModeLed = 12;   // global / mode color
static const uint8_t kTrackLed0 = 13; // active-bank tracks 1..4 = LEDs 13..16
static const uint8_t kClearLed = 17;  // lit during a clear fade
static const uint8_t kBankLed = 18;   // lit when bank B is active
static CRGB g_leds[kNumLeds];

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
  renderRing(); // the loop-position ring, LEDs 0..11
  if (g_haveFrame) {
    // Show the active bank's 4 tracks on the physical Tr1..Tr4 LEDs.
    const uint8_t base = g_frame.active_bank * 4; // bank A: 0..3, bank B: 4..7
    for (uint8_t i = 0; i < 4; i++) {
      g_leds[kTrackLed0 + i] = ledColor(g_frame.track_leds[base + i]);
    }
    g_leds[kModeLed] = globalColor(g_frame.global_color);
    g_leds[kClearLed] = g_frame.clear_fade ? CRGB::Blue : CRGB::Black;
    g_leds[kBankLed] = (g_frame.active_bank == 1) ? CRGB(0, 0, 80) : CRGB::Black;
  } else {
    g_leds[kModeLed] = CRGB::Black;
    g_leds[kClearLed] = CRGB::Black;
    g_leds[kBankLed] = CRGB::Black;
    for (uint8_t i = 0; i < 4; i++) g_leds[kTrackLed0 + i] = CRGB::Black;
  }

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
  FastLED.addLeds<WS2812B, kLedPin, GRB>(g_leds, kNumLeds);
  FastLED.setBrightness(64);

  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(kButtonPins[i], INPUT_PULLUP);
    g_btnState[i] = false;
    g_btnChangedMs[i] = 0;
  }
  pinMode(kEncoderClk, INPUT_PULLUP);
  pinMode(kEncoderDat, INPUT_PULLUP);
  g_encClkPrev = (digitalRead(kEncoderClk) == HIGH) ? 1 : 0;

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
