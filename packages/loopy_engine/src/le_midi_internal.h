/*
 * le_midi_internal.h - non-public MIDI entry points for deterministic tests.
 *
 * Exposes the pure parser, the backend selector, and injection hooks so the
 * portable core (the ring, the parser, the drain/callback path, and the
 * dispose-ordering guarantee) can be unit-tested without any MIDI hardware.
 * Not part of the FFI surface (excluded from ffigen).
 */
#ifndef LOOPY_ENGINE_MIDI_INTERNAL_H
#define LOOPY_ENGINE_MIDI_INTERNAL_H

#include <stdint.h>

#include "le_midi_backend.h" /* le_midi_backend, le_midi_ring_push/drain */
#include "loopy_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Classification of a 3-byte MIDI channel-voice message. Everything the control
 * path cares about is Note On/Off and Control Change; all else is IGNORE. */
typedef enum le_midi_kind {
  LE_MIDI_IGNORE = 0,   /* SysEx, real-time, aftertouch, pitch-bend, etc. */
  LE_MIDI_CC = 1,       /* Control Change */
  LE_MIDI_NOTE_ON = 2,  /* Note On with non-zero velocity */
  LE_MIDI_NOTE_OFF = 3, /* Note Off, or Note On with velocity 0 */
} le_midi_kind;

/* Parsed channel-voice message. `channel` is 0..15; `number` is the CC number
 * or note number; `value` is the CC value or velocity. */
typedef struct le_midi_parsed {
  le_midi_kind kind;
  uint8_t channel;
  uint8_t number;
  uint8_t value;
} le_midi_parsed;

/* Pure classifier: maps a raw (status, data1, data2) triple to its kind, filling
 * *out when out != NULL. Note On with velocity 0 is reported as LE_MIDI_NOTE_OFF
 * (the standard running-status convention). A status byte below 0x80 (a data
 * byte / running status, which the backends never forward) is LE_MIDI_IGNORE.
 * No state, no allocation - safe anywhere. */
le_midi_kind le_midi_parse(uint8_t status, uint8_t data1, uint8_t data2,
                           le_midi_parsed* out);

/* Returns the compiled-in per-OS backend, or NULL when the platform has none.
 * Mirrors le_select_backend (engine_internal.h). */
const le_midi_backend* le_midi_select_backend(void);

/* Test hook: register a callback on `m` directly, without opening a device, so
 * the ring -> drain -> callback path can be exercised in isolation. */
void le_midi_set_cb_for_test(le_midi* m, le_midi_event_cb cb);

/* Test hook: push a raw message as if it arrived from an OS callback (identical
 * to le_midi_ring_push). Returns 1 if enqueued, 0 if dropped/full. */
int le_midi_push_for_test(le_midi* m, uint8_t status, uint8_t data1,
                          uint8_t data2, uint64_t ts_us);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_MIDI_INTERNAL_H */
