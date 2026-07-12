// Loopy floor-console WS2812 LED driver — RP2040 firmware.
//
// Offloads the hard-real-time WS2812 timing from the Raspberry Pi. Receives
// compact transport-state frames from the Pi over UART (115200 8N1 on Serial1),
// drives a 12-LED loop-position ring plus per-track indicator LEDs, and answers
// a boot-time health ping so a missing/unflashed driver is a visible fault on
// the Pi rather than silent dark LEDs.
//
// Wire format and protocol: see README.md (the Pi side is packages/led_client).
// UNVERIFIED on hardware — written from the spec; flash + bring up on a real
// RP2040 + ring before relying on it.
//
// Build: Arduino with the "Raspberry Pi Pico/RP2040" core + Adafruit NeoPixel.

#include <Adafruit_NeoPixel.h>

// --- Wiring -----------------------------------------------------------------
static const uint8_t LED_PIN = 2;       // WS2812 data (GP2) via a level shifter.
static const uint16_t RING_LEDS = 12;   // Loop-position ring.
static const uint16_t TRACK_LEDS = 8;   // Per-track indicators.
static const uint16_t NUM_LEDS = RING_LEDS + TRACK_LEDS;

// Serial1 = the Pi link: GP1 (RX) <- Pi TX, GP0 (TX) -> Pi RX.
#define LINK Serial1
static const unsigned long LINK_BAUD = 115200;

// --- Protocol (see README.md) ----------------------------------------------
static const uint8_t SYNC = 0xA5;
static const uint8_t TYPE_STATE = 0x01;
static const uint8_t TYPE_PING = 0x02;
static const uint8_t TYPE_ACK = 0x82;
static const uint8_t MAX_PAYLOAD = 64;

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);

// --- Last good state (the ring animates locally between frames) -------------
static bool g_running = false;
static uint8_t g_global = 0;      // 0 off,1 green,2 red,3 amber
static uint32_t g_loopUs = 0;     // master loop length in microseconds
static uint8_t g_trackCount = 0;
static uint8_t g_tracks[TRACK_LEDS];
static unsigned long g_frameMs = 0;  // millis() when the last frame arrived

// Colors are gamma-corrected (strip.gamma32) so brightness reads perceptually
// even: a WS2812's duty cycle is linear but the eye's response is not, so without
// it the ring's dim head and the amber mix look top-heavy. gamma32(0) == 0, so
// "off" stays off.
static uint32_t colorOf(uint8_t code) {
  uint32_t c;
  switch (code) {
    case 1: c = strip.Color(0, 160, 0); break;   // green
    case 2: c = strip.Color(180, 0, 0); break;   // red
    case 3: c = strip.Color(180, 90, 0); break;  // amber
    default: return 0;                            // off
  }
  return strip.gamma32(c);
}

// Parse one STATE frame from a buffer that starts at the byte after the length
// byte (layout: flags, global, loopUs LE x4, trackCount, tracks...).
static void applyState(const uint8_t* p, uint8_t len) {
  if (len < 7) return;
  g_running = (p[0] & 0x1) != 0;
  g_global = p[1];
  g_loopUs = (uint32_t)p[2] | ((uint32_t)p[3] << 8) | ((uint32_t)p[4] << 16) |
             ((uint32_t)p[5] << 24);
  g_trackCount = p[6] < TRACK_LEDS ? p[6] : TRACK_LEDS;
  for (uint8_t i = 0; i < g_trackCount && (7 + i) < len; i++) {
    g_tracks[i] = p[7 + i];
  }
  g_frameMs = millis();
}

static void sendAck() {
  const uint8_t ack[4] = {SYNC, TYPE_ACK, 0x00, TYPE_ACK};
  LINK.write(ack, sizeof(ack));
}

// Minimal framing state machine: SYNC, type, len, payload, checksum (XOR of
// type..last payload byte). A bad checksum drops the frame (the Pi re-sends).
static void pumpLink() {
  static uint8_t buf[MAX_PAYLOAD];
  static uint8_t type = 0, len = 0, idx = 0, checksum = 0;
  static uint8_t stage = 0;  // 0 sync,1 type,2 len,3 payload,4 checksum
  while (LINK.available() > 0) {
    const uint8_t b = (uint8_t)LINK.read();
    switch (stage) {
      case 0:
        if (b == SYNC) stage = 1;
        break;
      case 1:
        type = b;
        checksum = b;
        stage = 2;
        break;
      case 2:
        len = b <= MAX_PAYLOAD ? b : 0;
        checksum ^= b;
        idx = 0;
        stage = (len == 0) ? 4 : 3;
        break;
      case 3:
        buf[idx++] = b;
        checksum ^= b;
        if (idx >= len) stage = 4;
        break;
      case 4:
        if (b == checksum) {
          if (type == TYPE_STATE) applyState(buf, len);
          else if (type == TYPE_PING) sendAck();
        }
        stage = 0;
        break;
    }
  }
}

static void render() {
  strip.clear();
  // Ring: light a head LED at the loop position when running, in the global
  // colour; otherwise a dim idle dot at the top.
  if (g_running && g_loopUs > 0) {
    const uint32_t loopMs = g_loopUs / 1000;
    const uint32_t pos = loopMs > 0 ? ((millis() - g_frameMs) % loopMs) : 0;
    const uint16_t head = loopMs > 0 ? (pos * RING_LEDS) / loopMs : 0;
    // While running, a global of 'off' still shows a moving green head so the
    // ring is never dark mid-loop.
    strip.setPixelColor(head % RING_LEDS, colorOf(g_global == 0 ? 1 : g_global));
  } else {
    strip.setPixelColor(0, strip.gamma32(strip.Color(10, 10, 10)));
  }
  // Per-track indicators.
  for (uint8_t i = 0; i < TRACK_LEDS; i++) {
    strip.setPixelColor(RING_LEDS + i, colorOf(i < g_trackCount ? g_tracks[i] : 0));
  }
  strip.show();
}

void setup() {
  LINK.begin(LINK_BAUD);
  strip.begin();
  strip.setBrightness(120);
  strip.show();
}

void loop() {
  pumpLink();
  render();
  delay(16);  // ~60 fps ring animation; well below WS2812 refresh limits.
}
