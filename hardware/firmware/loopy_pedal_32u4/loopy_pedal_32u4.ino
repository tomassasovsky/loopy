// loopy MIDI foot-pedal — ATmega32U4 firmware (THT main-board re-spin)
// ---------------------------------------------------------------------------
// A PURE THIN CLIENT, ported from firmware/loopy_pedal/ (the UNO/MocoLUFA build)
// to the Pro Micro (ATmega32U4) THT board. It holds NO looper state: it renders
// LEDs only from the last good state frame loopy pushes, and sends raw
// footswitch / encoder events. loopy runs the behavior machine and is the single
// source of truth. See hardware/loopy_pedal_pcb_tht_plan.md and main_board.py.
//
// WHAT CHANGED vs. the UNO build (firmware/loopy_pedal/loopy_pedal.ino):
//   * Transport: native class-compliant USB-MIDI (MIDIUSB) over the module's
//     USB-C, AND the DIN-5 MIDI OUT/IN over the hardware UART (Serial1, 31250).
//     They are SEPARATE transports — no MocoLUFA bridge, no 74HC08 merge. Both
//     inputs (USB + DIN) are read for bidirectional sync; outbound events and the
//     identity reply go to BOTH.
//   * LEDs: TWO WS2812 strips instead of one 19-LED strip —
//       - RING (D15): the off-the-shelf 16-LED NeoPixel ring, loop-position.
//       - INDICATOR (D16): a 7-LED strip: [mode, Tr1, Tr2, Tr3, Tr4, clear, bank].
//   * Pin map matches main_board.py / the THT plan §1 (footswitches D2–D10/D14).
//
// POWER NOTE: both strips run off the +5V_LED rail, which the on-board buck makes
// from the 9 V barrel. On USB-ONLY there is no 9 V, the buck is off, and the LEDs
// stay DARK by design (main_board.py) — connect the 9 V supply to see them light.
//
// pedal_protocol.c/.h are mirrored byte-for-byte from firmware/loopy_pedal/ (the
// host contract test guards the canonical copy). Keep them in sync — a diff of the
// two pedal_protocol.h (and .c) files must be empty (see this folder's README).
//
// Requires the "MIDIUSB" and "FastLED" libraries (Library Manager). Board:
// SparkFun Pro Micro 5V/16MHz, or Arduino Leonardo (same ATmega32U4 core).
// ---------------------------------------------------------------------------

#include <FastLED.h>
#include <MIDIUSB.h>

#include "pedal_protocol.h"

// ---- hardware layout — matches main_board.py / the THT plan -----------------

// RING strip: the 16-LED NeoPixel ring on D15 (loop-position playhead).
static const uint8_t kRingPin = 15;
static const uint8_t kRingCount = 16;
static CRGB g_ring[kRingCount];

// INDICATOR strip: 7 LEDs on D16, in this order (the off-board strip is wired to
// follow it): mode/global, the active bank's Tr1..Tr4, clear-fade, bank.
static const uint8_t kIndPin = 16;
static const uint8_t kIndCount = 7;
static const uint8_t kIndMode = 0;    // global transport-activity color
static const uint8_t kIndTrack0 = 1;  // active-bank tracks 1..4 = LEDs 1..4
static const uint8_t kIndClear = 5;   // lit during a clear fade
static const uint8_t kIndBank = 6;    // lit when bank B is active
static CRGB g_ind[kIndCount];

// The 10 footswitches, indexed by PEDAL_BTN_* (recPlay, stop, undo, mode,
// track1..4, clear, bank); active-low with INPUT_PULLUP. THT board wiring.
static const uint8_t kButtonPins[PEDAL_BTN_COUNT] = {
    2,  // recPlay
    3,  // stop
    4,  // undo
    5,  // mode
    6,  // track1
    7,  // track2
    8,  // track3
    9,  // track4
    10, // clear
    14, // bank
};
// Rotary encoder: clock A0, data A1 (the push switch on A2 is unused in v1).
static const uint8_t kEncoderClk = A0;
static const uint8_t kEncoderDat = A1;
static const uint8_t kEncoderSw = A2;

static const unsigned long kDebounceMs = 25; // foot-switch contact debounce
static const uint8_t kMidiChannel = 0; // channel 1 (0-based on the wire)

// ---- inbound state ----------------------------------------------------------

static pedal_frame g_frame;       // last good frame loopy pushed
static bool g_haveFrame = false;  // false until the first valid frame
static uint8_t g_sysex[40];
static uint8_t g_sysexLen = 0;
static bool g_inSysex = false;
static unsigned long g_lastLoopTopMs = 0; // time of the last loop-top pulse

// ---- button / encoder debounce state ----------------------------------------

static bool g_btnStable[PEDAL_BTN_COUNT];  // last debounced (reported) state
static bool g_btnLastRaw[PEDAL_BTN_COUNT]; // previous raw sample
static unsigned long g_btnRawSinceMs[PEDAL_BTN_COUNT]; // when raw last changed
static uint8_t g_encState = 0;         // quadrature decoder state (see pollEncoder)
static unsigned long g_lastDetentMs = 0; // for encoder velocity acceleration

// Ring volume indicator. The AUTHORITATIVE gain travels in the state frame
// (g_frame.master_gain, 0..255) — loopy fills it, so the meter shows exactly what
// the engine applies, with no local drift. The bar is shown for kGainShowMs
// whenever the frame's gain CHANGES (from the encoder OR an on-screen control).
// g_localGain is a same-math local echo (unity boot, step 1/64 — matches
// ControlCubit) used only as a fallback before the first frame / when unbound, so
// the meter still works during bring-up with no app. Presentational only.
static const float kEncoderStep = 1.0f / 64.0f;      // matches ControlCubit._encoderStep
static const unsigned long kGainShowMs = 1200;       // ring shows the bar this long after a change
// Encoder velocity acceleration: a detent arriving faster than kEncFastMs steps
// the gain by kEncFastStep; between that and kEncBriskMs by kEncBriskStep; slower
// than kEncBriskMs by 1 (fine). The relative CC carries the scaled delta, so both
// the local echo and loopy accelerate together.
static const unsigned long kEncFastMs = 20;
static const uint8_t kEncFastStep = 5;
static const unsigned long kEncBriskMs = 45;
static const uint8_t kEncBriskStep = 2;
static float g_localGain = 1.0f;                     // fallback echo (used until a frame arrives)
static unsigned long g_gainShownUntilMs = 0;         // 0 = nothing to show yet
static uint8_t g_lastFrameGain = 255;                // last frame's gain (unity at boot)
static bool g_frameGainSeen = false;                 // ignore the first frame's "change"

// ---- MIDI out: send to BOTH USB-MIDI and the DIN UART -----------------------

// A 3-byte channel message (Note / CC) to both transports.
static void sendChannelMsg(const uint8_t* m) {
  midiEventPacket_t e = {(uint8_t)(m[0] >> 4), m[0], m[1], m[2]};
  MidiUSB.sendMIDI(e);
  MidiUSB.flush();
  Serial1.write(m, 3);
}

// A complete SysEx message (F0..F7) to both transports. Over USB-MIDI it is
// chunked into the class packets (CIN 0x4 continue, 0x5/0x6/0x7 end 1/2/3 bytes).
static void sendSysex(const uint8_t* data, int len) {
  Serial1.write(data, len);
  int i = 0;
  while (len - i > 3) {
    midiEventPacket_t e = {0x04, data[i], data[i + 1], data[i + 2]};
    MidiUSB.sendMIDI(e);
    i += 3;
  }
  const int rem = len - i; // 1..3 (SysEx is never zero-length here)
  const uint8_t cin = (rem == 1) ? 0x05 : (rem == 2) ? 0x06 : 0x07;
  midiEventPacket_t e = {cin, data[i], (uint8_t)(rem > 1 ? data[i + 1] : 0),
                         (uint8_t)(rem > 2 ? data[i + 2] : 0)};
  MidiUSB.sendMIDI(e);
  MidiUSB.flush();
}

// The pedal's identity reply: a fixed family signature loopy recognizes. Sent in
// response to the Universal Identity Request, per the spec's future inbound path.
static void sendIdentityReply() {
  static const uint8_t kReply[] = {
      0xF0, 0x7E, 0x7F, 0x06, 0x02, PEDAL_MANUFACTURER_ID,
      0x4C, 0x50, // family "LP"
      0x01, 0x00, // member
      0x01, 0x00, 0x00, 0x00, // revision
      0xF7};
  sendSysex(kReply, sizeof(kReply));
}

// ---- inbound MIDI -----------------------------------------------------------

static void handleSysex(const uint8_t* msg, int len) {
  if (pedal_is_identity_request(msg, len)) {
    sendIdentityReply();
    return;
  }
  pedal_frame decoded;
  if (pedal_decode_frame(msg, len, &decoded)) {
    // Flash the ring volume meter whenever the master gain changes (encoder OR
    // an on-screen control) — but not on the very first frame we ever see.
    if (g_frameGainSeen && decoded.master_gain != g_lastFrameGain) {
      g_gainShownUntilMs = millis() + kGainShowMs;
    }
    g_lastFrameGain = decoded.master_gain;
    g_frameGainSeen = true;
    g_frame = decoded;
    g_haveFrame = true;
  }
  // A malformed frame is silently dropped; the last good frame is retained.
}

// Feeds one raw MIDI byte through the SysEx assembler, handling the interleaved
// real-time loop-top pulse (0xFA) without corrupting a SysEx in progress.
static void consumeByte(uint8_t b) {
  if (b == PEDAL_LOOP_TOP) {
    g_lastLoopTopMs = millis();
    return; // real-time: may interleave inside a SysEx
  }
  if (b >= 0xF8) return; // other real-time: ignore, don't disturb a SysEx
  if (b == PEDAL_SYSEX_START) {
    g_sysexLen = 0;
    g_inSysex = true;
    g_sysex[g_sysexLen++] = b;
    return;
  }
  if (!g_inSysex) return; // loopy sends only SysEx + real-time; ignore strays
  if (g_sysexLen >= sizeof(g_sysex)) {
    g_inSysex = false; // overflow: drop this (partial) frame
    return;
  }
  g_sysex[g_sysexLen++] = b;
  if (b == PEDAL_SYSEX_END) {
    g_inSysex = false;
    handleSysex(g_sysex, g_sysexLen);
  }
}

// USB-MIDI in: decode each class packet back to raw bytes by its code-index.
static void pollUsbIn() {
  for (;;) {
    midiEventPacket_t rx = MidiUSB.read();
    if (!rx.header) break;
    switch (rx.header & 0x0F) {
      case 0x4: case 0x7:            // SysEx start/continue, or end-with-3
      case 0x8: case 0x9: case 0xA:  // Note off / on / poly-aftertouch
      case 0xB: case 0xE:            // control change / pitch-bend
        consumeByte(rx.byte1); consumeByte(rx.byte2); consumeByte(rx.byte3);
        break;
      case 0x6:                      // SysEx end-with-2
      case 0xC: case 0xD:            // program change / channel-pressure
        consumeByte(rx.byte1); consumeByte(rx.byte2);
        break;
      case 0x5:                      // single-byte SysEx end
      case 0xF:                      // single byte (system real-time, e.g. 0xFA)
        consumeByte(rx.byte1);
        break;
      default:
        break;
    }
  }
}

// DIN-5 MIDI in (opto -> Serial1 RX): a plain byte stream.
static void pollDinIn() {
  while (Serial1.available() > 0) consumeByte((uint8_t)Serial1.read());
}

static void pollMidiIn() {
  pollUsbIn();
  pollDinIn();
}

// ---- rendering --------------------------------------------------------------

static CRGB ledColor(uint8_t led) {
  switch (led) {
    case PEDAL_LED_GREEN: return CRGB::Green;
    case PEDAL_LED_RED:   return CRGB::Red;
    default:              return CRGB::Black;
  }
}

static CRGB globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN: return CRGB::Green;
    case PEDAL_GLOBAL_RED:   return CRGB::Red;
    case PEDAL_GLOBAL_AMBER: return CRGB(255, 150, 0);
    case PEDAL_GLOBAL_BLUE:  return CRGB::Blue;
    default:                 return CRGB::Black;
  }
}

static CRGB scaled(CRGB c, uint8_t level) {
  c.nscale8_video(level);
  return c;
}

// A smooth brightness hump rotates around the ring (see the UNO build for the
// full rationale). Widths tuned for the 16-LED ring. A Stop that leaves a loop
// loaded freezes the ring in place; clearing keeps it advancing to dark.
static const unsigned long kRingMsPerRev = 700;
static const float kRingWidth = 7.0f;  // ~5.5 * 16/12, scaled for 16 LEDs
static const float kRingShape = 1.5f;
static float g_ringPhase = 0.0f;
static unsigned long g_ringLastMs = 0;

static void renderRing() {
  const CRGB activity = g_haveFrame ? globalColor(g_frame.global_color)
                                    : CRGB::Black;
  const bool goodbye = g_haveFrame && g_frame.goodbye;
  const bool active = g_haveFrame && !goodbye &&
                      (activity.r || activity.g || activity.b) &&
                      g_frame.global_color != PEDAL_GLOBAL_BLUE;
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;
  if (goodbye) {
    for (uint8_t i = 0; i < kRingCount; i++) g_ring[i] = CRGB::Black;
    return;
  }
  if (!active && g_frame.loop_length_micros > 0) return; // Stop freezes the ring
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
    // Map the logical playhead to the mirrored physical LED so the hump rotates
    // CLOCKWISE against this ring's DIN-chain wiring order.
    g_ring[(kRingCount - 1) - i] = scaled(activity, level);
  }
}

// The ring as a volume meter: a green (low) -> red (full) level bar of the local
// gain echo, shown for kGainShowMs after each encoder turn. Fills clockwise (the
// same sense as the loop-position hump); the top LED dims for the fractional part.
static void renderVolumeBar() {
  // Authoritative gain from the frame; fall back to the local echo pre-bind.
  const float gain = g_haveFrame ? (g_frame.master_gain / 255.0f) : g_localGain;
  const float lvl = gain * (float)kRingCount; // 0..kRingCount LEDs lit
  for (uint8_t i = 0; i < kRingCount; i++) {
    uint8_t level = 0;
    if ((float)i + 1.0f <= lvl) level = 255;                       // fully inside the bar
    else if ((float)i < lvl) level = (uint8_t)((lvl - (float)i) * 255.0f); // partial top LED
    const uint8_t hue = (uint8_t)(96.0f * (1.0f - (float)i / (float)(kRingCount - 1)));
    g_ring[(kRingCount - 1) - i] = scaled(CRGB(CHSV(hue, 255, 255)), level);
  }
}

// Performance-recording armed (D-PEDAL): the mode LED BLINKS red, distinct
// eyes-free from looper-recording's own SOLID red. 400 ms half-period.
static const unsigned long kBlinkHalfPeriodMs = 400;

static void render() {
  // A recent encoder turn takes over the ring as a volume meter; otherwise it
  // shows the loop-position playhead. Signed compare is millis()-wrap safe.
  if ((long)(g_gainShownUntilMs - millis()) > 0) {
    renderVolumeBar();
    g_ringLastMs = millis(); // keep the hump's dt small when the bar lapses
  } else {
    renderRing();
  }
  if (g_haveFrame) {
    const uint8_t base = g_frame.active_bank * 4; // A: 0..3, B: 4..7
    for (uint8_t i = 0; i < 4; i++) {
      g_ind[kIndTrack0 + i] = ledColor(g_frame.track_leds[base + i]);
    }
    if (g_frame.performance_armed) {
      const bool blinkOn = (millis() / kBlinkHalfPeriodMs) % 2 == 0;
      g_ind[kIndMode] = blinkOn ? CRGB::Red : CRGB::Black;
    } else {
      g_ind[kIndMode] = (g_frame.global_color == PEDAL_GLOBAL_OFF)
                            ? CRGB::Green
                            : globalColor(g_frame.global_color);
    }
    g_ind[kIndClear] = g_frame.clear_fade ? CRGB::Red : CRGB::Black;
    g_ind[kIndBank] = (g_frame.active_bank == 1) ? CRGB(0, 0, 80) : CRGB::Black;
  } else {
    for (uint8_t i = 0; i < kIndCount; i++) g_ind[i] = CRGB::Black;
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
    const bool raw = (digitalRead(kButtonPins[i]) == LOW); // active-low
    if (raw != g_btnLastRaw[i]) { // chatter: restart the stability timer
      g_btnLastRaw[i] = raw;
      g_btnRawSinceMs[i] = now;
      continue;
    }
    if (raw != g_btnStable[i] && (now - g_btnRawSinceMs[i]) >= kDebounceMs) {
      g_btnStable[i] = raw;
      uint8_t msg[3];
      pedal_encode_button(i, raw ? 1 : 0, kMidiChannel, msg);
      sendChannelMsg(msg);
    }
  }
}

// Rotary encoder decode — a Gray-code state table (Ben Buxton's rotary decoder).
// A naive "act on every edge" read is swamped by EC11 contact bounce (dozens of
// spurious counts of mixed direction per detent — observed on the bench). This
// state machine emits a step ONLY on a complete, valid quadrature sequence and
// silently absorbs bounces, so one detent = exactly one clean ±1.
#define R_START     0x0
#define R_CW_FINAL  0x1
#define R_CW_BEGIN  0x2
#define R_CW_NEXT   0x3
#define R_CCW_BEGIN 0x4
#define R_CCW_FINAL 0x5
#define R_CCW_NEXT  0x6
#define DIR_CW      0x10
#define DIR_CCW     0x20
static const uint8_t kEncTable[7][4] = {
    {R_START,    R_CW_BEGIN,  R_CCW_BEGIN, R_START},           // R_START
    {R_CW_NEXT,  R_START,     R_CW_FINAL,  R_START | DIR_CW},  // R_CW_FINAL
    {R_CW_NEXT,  R_CW_BEGIN,  R_START,     R_START},           // R_CW_BEGIN
    {R_CW_NEXT,  R_CW_BEGIN,  R_CW_FINAL,  R_START},           // R_CW_NEXT
    {R_CCW_NEXT, R_START,     R_CCW_BEGIN, R_START},           // R_CCW_BEGIN
    {R_CCW_NEXT, R_CCW_FINAL, R_START,     R_START | DIR_CCW}, // R_CCW_FINAL
    {R_CCW_NEXT, R_CCW_FINAL, R_CCW_BEGIN, R_START},           // R_CCW_NEXT
};

// One relative CC per detent, with VELOCITY ACCELERATION: a fast spin steps the
// gain in bigger increments (coarse), a slow turn by one (fine). Turning the knob
// CLOCKWISE (right) increases the gain — the board's A/B wiring makes physical CW
// read as the table's DIR_CCW, so the sign is flipped here (verified on bench).
static void pollEncoder() {
  const uint8_t pinstate = (uint8_t)((digitalRead(kEncoderDat) << 1) |
                                     digitalRead(kEncoderClk));
  g_encState = kEncTable[g_encState & 0x0F][pinstate];
  const uint8_t dir = g_encState & 0x30;
  if (dir == 0) return; // mid-sequence or absorbed bounce: emit nothing

  // Scale the step by how fast detents are arriving.
  const unsigned long now = millis();
  const unsigned long dt = now - g_lastDetentMs;
  g_lastDetentMs = now;
  int step = 1;
  if (dt < kEncFastMs) step = kEncFastStep;
  else if (dt < kEncBriskMs) step = kEncBriskStep;

  const int delta = ((dir == DIR_CW) ? -1 : 1) * step; // CW (right) = louder
  uint8_t msg[3];
  pedal_encode_encoder(delta, kMidiChannel, msg);
  sendChannelMsg(msg);

  // Mirror loopy's accumulator locally and arm the ring volume indicator.
  g_localGain += (float)delta * kEncoderStep;
  if (g_localGain < 0.0f) g_localGain = 0.0f;
  if (g_localGain > 1.0f) g_localGain = 1.0f;
  g_gainShownUntilMs = now + kGainShowMs;
}

// ---- lifecycle --------------------------------------------------------------

void setup() {
  Serial1.begin(31250); // DIN-5 MIDI @ standard baud
  FastLED.addLeds<WS2812B, kRingPin, GRB>(g_ring, kRingCount);
  FastLED.addLeds<WS2812B, kIndPin, GRB>(g_ind, kIndCount);
  FastLED.setBrightness(64);

  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(kButtonPins[i], INPUT_PULLUP);
    g_btnStable[i] = false; // released at boot
    g_btnLastRaw[i] = false;
    g_btnRawSinceMs[i] = 0;
  }
  pinMode(kEncoderClk, INPUT_PULLUP);
  pinMode(kEncoderDat, INPUT_PULLUP);
  pinMode(kEncoderSw, INPUT_PULLUP);
  g_encState = R_START;

  // Startup self-test: a green comet sweeps the ring then the indicator strip so
  // the builder sees the pedal is alive and both strips are wired before loopy
  // binds. (Needs the +5V_LED rail — i.e. the 9 V supply — to actually light.)
  for (uint8_t i = 0; i < kRingCount; i++) {
    g_ring[i] = CRGB(0, 24, 0);
    FastLED.show();
    delay(15);
    g_ring[i] = CRGB::Black;
  }
  FastLED.show();
  for (uint8_t i = 0; i < kIndCount; i++) {
    g_ind[i] = CRGB(0, 24, 0);
    FastLED.show();
    delay(40);
    g_ind[i] = CRGB::Black;
  }
  FastLED.show();
}

void loop() {
  pollMidiIn();
  pollButtons();
  pollEncoder();
  render(); // polls MIDI around show()
}
