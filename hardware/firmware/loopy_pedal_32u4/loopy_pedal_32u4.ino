// loopy MIDI foot-pedal — ATmega32U4 firmware skeleton
// ---------------------------------------------------------------------------
// THT main-board re-spin: an Arduino Pro Micro (ATmega32U4) replaces 328P + 16U2.
// It is a *native* USB-MIDI device (class-compliant, via the MIDIUSB library)
// AND drives the DIN-5 MIDI OUT over the hardware UART (Serial1, 31250 baud).
// USB-MIDI and DIN-MIDI are now SEPARATE transports — no MocoLUFA bridge, no
// 74HC08 AND-merge. Both MIDI inputs (USB + DIN-in on Serial1 RX) are read for
// bidirectional sync with the loopy app.
//
// Pin map — matches hardware/loopy_pedal_pcb_tht_plan.md / main_board.py:
//   Footswitches (active-low, INPUT_PULLUP, LOW = pressed):
//     D2  RECPLAY note 0     D7   TRACK2 note 5
//     D3  STOP    note 1     D8   TRACK3 note 6
//     D4  UNDO    note 2     D9   TRACK4 note 7
//     D5  MODE    note 3     D10  CLEAR  note 8
//     D6  TRACK1  note 4     D14  BANK   note 9
//   D15 -> ring-LED data (buffered to ring board)   A0 -> ENC_A
//   D16 -> indicator-LED data (off-board strip)     A1 -> ENC_B
//   D0/RX <- DIN MIDI IN (opto)                     A2 -> ENC_SW
//   D1/TX -> DIN MIDI OUT (buffer)                  A3 -> spare
//
// Two build modes (toggle MIDI_DEBUG below):
//   * MIDI_DEBUG 0 -> real: native USB-MIDI + Serial1 DIN @ 31250.
//   * MIDI_DEBUG 1 -> USB serial monitor @ 115200, human-readable lines.
//
// Requires the "MIDIUSB" library (Library Manager). Board: SparkFun Pro Micro
// 5V/16MHz, or Arduino Leonardo (same 32U4 core).
// ---------------------------------------------------------------------------

#define MIDI_DEBUG     0      // 1 for USB-serial-monitor testing, 0 for real MIDI
#define MIDI_CHANNEL   1      // 1..16
#define NOTE_BASE      0      // note for RECPLAY; rest are NOTE_BASE+index.
                             // NOTE: must match what the loopy app listens for.
#define VELOCITY       127
#define DEBOUNCE_MS    8

#if !MIDI_DEBUG
#include <MIDIUSB.h>
#endif

const uint8_t SW_PIN[10]  = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 14 };
const char*   SW_NAME[10] = { "RECPLAY","STOP","UNDO","MODE","TRACK1",
                              "TRACK2","TRACK3","TRACK4","CLEAR","BANK" };

// LED data + encoder pins (wired on the board; logic is a TODO — see loop()).
const uint8_t PIN_RING_DATA = 15;   // D15 -> 74HCT125 -> ring board
const uint8_t PIN_IND_DATA  = 16;   // D16 -> 330R -> off-board indicator strip
const uint8_t PIN_ENC_A     = A0;
const uint8_t PIN_ENC_B     = A1;
const uint8_t PIN_ENC_SW    = A2;

uint8_t  lastStable[10];      // last debounced level (HIGH = released)
uint8_t  lastReading[10];
uint32_t lastChange[10];
uint8_t  encPrevA;            // for quadrature decode

// ---- MIDI out: send to BOTH USB-MIDI and the DIN UART ----------------------

void midiSend(uint8_t status, uint8_t d1, uint8_t d2) {
#if MIDI_DEBUG
  Serial.print(status >= 0x90 ? "NoteOn  " : "NoteOff ");
  Serial.print("ch=");   Serial.print((status & 0x0F) + 1);
  Serial.print(" note="); Serial.print(d1);
  Serial.print(" vel=");  Serial.println(d2);
#else
  // native USB-MIDI (event packet: cable 0, code index = status high nibble)
  midiEventPacket_t e = { (uint8_t)(status >> 4), status, d1, d2 };
  MidiUSB.sendMIDI(e);
  MidiUSB.flush();
  // DIN-5 MIDI OUT over the hardware UART
  Serial1.write(status);
  Serial1.write(d1);
  Serial1.write(d2);
#endif
}

void noteOn(uint8_t note)  { midiSend(0x90 | ((MIDI_CHANNEL - 1) & 0x0F), note, VELOCITY); }
void noteOff(uint8_t note) { midiSend(0x80 | ((MIDI_CHANNEL - 1) & 0x0F), note, 0); }

// ---- MIDI in: app -> pedal (LED feedback / state sync) ---------------------

void handleIncoming(uint8_t status, uint8_t d1, uint8_t d2) {
  (void)status; (void)d1; (void)d2;
  // TODO: drive indicator/ring LEDs from app state (track armed/recording/etc.)
  //       and any mode/bank changes pushed back from the loopy app.
}

void pollMidiIn() {
#if !MIDI_DEBUG
  // USB-MIDI in
  midiEventPacket_t rx;
  do {
    rx = MidiUSB.read();
    if (rx.header) handleIncoming(rx.byte1, rx.byte2, rx.byte3);
  } while (rx.header);
  // DIN-5 MIDI IN (opto -> Serial1 RX). Minimal 3-byte channel-message parser.
  static uint8_t st = 0, d1 = 0, idx = 0;
  while (Serial1.available()) {
    uint8_t b = Serial1.read();
    if (b & 0x80) { st = b; idx = 1; }          // status byte
    else if (idx == 1) { d1 = b; idx = 2; }     // data 1
    else if (idx == 2) { handleIncoming(st, d1, b); idx = 1; }  // data 2 (running status)
  }
#endif
}

// ---- setup / loop ----------------------------------------------------------

void setup() {
#if MIDI_DEBUG
  Serial.begin(115200);
  while (!Serial && millis() < 2000) {}         // wait briefly for the monitor
  Serial.println(F("loopy pedal 32U4 — DEBUG mode (press a footswitch)"));
#else
  Serial1.begin(31250);                          // DIN-5 MIDI @ standard baud
#endif
  for (uint8_t i = 0; i < 10; i++) {
    pinMode(SW_PIN[i], INPUT_PULLUP);
    lastStable[i] = lastReading[i] = HIGH;
    lastChange[i] = 0;
  }
  pinMode(PIN_ENC_A, INPUT_PULLUP);
  pinMode(PIN_ENC_B, INPUT_PULLUP);
  pinMode(PIN_ENC_SW, INPUT_PULLUP);
  encPrevA = digitalRead(PIN_ENC_A);
  pinMode(PIN_RING_DATA, OUTPUT);
  pinMode(PIN_IND_DATA, OUTPUT);
  // TODO: FastLED.addLeds<WS2812B, PIN_IND_DATA, GRB>(indicatorLeds, 7);
  //       FastLED.addLeds<WS2812B, PIN_RING_DATA, GRB>(ringLeds, 16);
}

void loop() {
  uint32_t now = millis();

  // footswitches -> MIDI (debounced, active-low)
  for (uint8_t i = 0; i < 10; i++) {
    uint8_t r = digitalRead(SW_PIN[i]);
    if (r != lastReading[i]) {                    // bounced — restart the timer
      lastReading[i] = r;
      lastChange[i] = now;
    }
    // NOTE (deferred): this is wait-for-stable debounce, which adds ~DEBOUNCE_MS
    // (~8 ms) latency to every PRESS. For tighter loop timing, switch to
    // leading-edge + lockout: act on the first HIGH->LOW edge immediately, then
    // ignore this switch for DEBOUNCE_MS. The board's RC already kills hardware
    // bounce (fast press / slow release), so press latency would drop to ~0.
    if ((now - lastChange[i]) >= DEBOUNCE_MS && r != lastStable[i]) {
      lastStable[i] = r;                          // a real, settled transition
      uint8_t note = NOTE_BASE + i;
      if (r == LOW) noteOn(note);                 // pressed
      else          noteOff(note);                // released
      // -- looper state machine goes here: interpret SW_NAME[i] (RECPLAY,
      //    BANK page-shift, MODE toggle, etc.) instead of / with the raw note.
    }
  }

  // rotary encoder -> delta (quadrature). Mapping to MIDI/looper is a TODO.
  uint8_t a = digitalRead(PIN_ENC_A);
  if (a != encPrevA && a == LOW) {                // falling edge on A
    int8_t dir = (digitalRead(PIN_ENC_B) == LOW) ? +1 : -1;
    (void)dir;  // TODO: map encoder turns (and PIN_ENC_SW press) to app actions
  }
  encPrevA = a;

  pollMidiIn();                                   // app -> pedal sync
}
