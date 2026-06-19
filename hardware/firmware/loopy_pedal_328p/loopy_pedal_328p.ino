// loopy MIDI foot-pedal — ATmega328P firmware skeleton
// ---------------------------------------------------------------------------
// Reads the 10 footswitches and emits MIDI over the hardware UART (31250 baud).
// On the board that UART feeds BOTH the ATmega16U2 (-> USB-MIDI) and the
// 74AHCT125 buffer (-> DIN-5 MIDI OUT), so this one stream covers both ports.
//
// Pin / note map is taken straight from hardware/loopy_pedal_pcb_design.md:
//   D3  SW_RECPLAY  note 0     D8   SW_TRACK2  note 5
//   D4  SW_STOP     note 1     D9   SW_TRACK3  note 6
//   D5  SW_UNDO     note 2     D10  SW_TRACK4  note 7
//   D6  SW_MODE     note 3     D11  SW_CLEAR   note 8
//   D7  SW_TRACK1   note 4     D12  SW_BANK    note 9
//
// Footswitch wiring: header pin 1 -> MCU pin, pin 2 -> GND. A closed switch
// pulls the MCU pin LOW, so we use INPUT_PULLUP and treat LOW = pressed.
//
// Two build modes (toggle MIDI_DEBUG below):
//   * MIDI_DEBUG 0  -> real MIDI: Serial @ 31250, raw 3-byte messages.
//   * MIDI_DEBUG 1  -> Wokwi/console: Serial @ 115200, human-readable lines.
// ---------------------------------------------------------------------------

#define MIDI_DEBUG     1      // 1 for Wokwi/serial-monitor testing, 0 for hardware
#define MIDI_CHANNEL   1      // 1..16
#define NOTE_BASE      0      // note for SW_RECPLAY; rest are NOTE_BASE+index.
                             // NOTE: must match what the loopy app listens for.
#define VELOCITY       127
#define DEBOUNCE_MS    8

const uint8_t SW_PIN[10]   = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
const char*   SW_NAME[10]  = { "RECPLAY","STOP","UNDO","MODE","TRACK1",
                               "TRACK2","TRACK3","TRACK4","CLEAR","BANK" };

uint8_t  lastStable[10];      // last debounced level (HIGH = released)
uint8_t  lastReading[10];
uint32_t lastChange[10];

void midiSend(uint8_t status, uint8_t d1, uint8_t d2) {
#if MIDI_DEBUG
  Serial.print(status >= 0x90 ? "NoteOn  " : "NoteOff ");
  Serial.print("ch="); Serial.print((status & 0x0F) + 1);
  Serial.print(" note="); Serial.print(d1);
  Serial.print(" vel="); Serial.println(d2);
#else
  Serial.write(status);
  Serial.write(d1);
  Serial.write(d2);
#endif
}

void noteOn(uint8_t note)  { midiSend(0x90 | ((MIDI_CHANNEL - 1) & 0x0F), note, VELOCITY); }
void noteOff(uint8_t note) { midiSend(0x80 | ((MIDI_CHANNEL - 1) & 0x0F), note, 0); }

void setup() {
#if MIDI_DEBUG
  Serial.begin(115200);
  Serial.println(F("loopy pedal — DEBUG mode (press a footswitch)"));
#else
  Serial.begin(31250);       // MIDI standard baud
#endif
  for (uint8_t i = 0; i < 10; i++) {
    pinMode(SW_PIN[i], INPUT_PULLUP);
    lastStable[i] = lastReading[i] = HIGH;
    lastChange[i] = 0;
  }
}

void loop() {
  uint32_t now = millis();
  for (uint8_t i = 0; i < 10; i++) {
    uint8_t r = digitalRead(SW_PIN[i]);
    if (r != lastReading[i]) {          // bounced — restart the timer
      lastReading[i] = r;
      lastChange[i] = now;
    }
    if ((now - lastChange[i]) >= DEBOUNCE_MS && r != lastStable[i]) {
      lastStable[i] = r;                // a real, settled transition
      uint8_t note = NOTE_BASE + i;
      if (r == LOW) noteOn(note);       // pressed
      else          noteOff(note);      // released
      // -- looper state machine goes here: interpret SW_NAME[i] (RECPLAY,
      //    BANK page-shift, MODE toggle, etc.) instead of / in addition to
      //    the raw note, and read MIDI back on Serial for bidirectional sync.
    }
  }
}
