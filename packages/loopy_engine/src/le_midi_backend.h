/*
 * le_midi_backend.h - the internal per-OS MIDI-capture backend seam.
 *
 * A thin vtable (a struct of function pointers) that the portable core
 * (midi.c) drives instead of calling CoreMIDI / ALSA / WinMM directly. The core
 * selects one backend with le_midi_select_backend (le_midi_internal.h) and owns
 * the le_midi handle, the lock-free message ring, the atomic callback pointer,
 * and the pure parser; a backend impl only enumerates ports, opens/closes one,
 * and feeds captured bytes back through le_midi_ring_push + le_midi_drain.
 *
 * This mirrors le_device_backend.h (the audio device seam) but is entirely
 * independent of the audio engine: MIDI capture has its own handle, its own
 * ring, and its own lifecycle.
 *
 * Each backend lives in its own OS-guarded translation unit
 * (midi_backend_{apple,linux,windows}.c). All three are listed unconditionally
 * in CMake; the two that don't match the build target compile to near-empty
 * objects (like engine_{linux,apple,windows}.c), and le_midi_select_backend
 * references only the matching one, so the others' factories need not link.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h) or ffigen.
 */
#ifndef LOOPY_ENGINE_MIDI_BACKEND_H
#define LOOPY_ENGINE_MIDI_BACKEND_H

#include <stdint.h>

#include "loopy_engine_api.h" /* le_midi (opaque), le_midi_info, le_result */

#ifdef __cplusplus
extern "C" {
#endif

/* One MIDI input backend. enumerate() is a static probe (no open handle).
 * open()/close() drive a single input port; both are idempotent and own all
 * OS-specific state, which they stash on the handle via le_midi_set_backend_state.
 * The core has already stored/cleared the callback pointer around these calls,
 * so a backend never touches the callback directly. */
typedef struct le_midi_backend {
  /* Fills `out` (room for `max`) with the host's MIDI input ports and writes the
   * count into *count (clamped to `max`). Returns LE_OK, or an le_result error;
   * degrades to *count = 0, LE_OK on an empty/again-unavailable host. */
  int32_t (*enumerate)(le_midi_info* out, int32_t max, int32_t* count);
  /* Opens the port matching `id` and starts capture, pushing parsed messages
   * through le_midi_ring_push(m, ...) and draining via le_midi_drain(m). On
   * success stores its OS state with le_midi_set_backend_state(m, state) and
   * returns LE_OK; on failure leaves no state and returns an le_result error. */
  int32_t (*open)(le_midi* m, const char* id);
  /* Stops capture and releases the OS state stored on `m`; idempotent (a no-op
   * when no state is set). Returns LE_OK or an le_result error. */
  int32_t (*close)(le_midi* m);
} le_midi_backend;

/* ---- core services a backend calls (defined in midi.c) ---- */

/* Producer side: parse one raw MIDI message and, if it is a Note On/Off or
 * Control Change, push it onto the handle's lock-free ring. Other messages
 * (SysEx / real-time / aftertouch / pitch-bend / program-change / data bytes)
 * are dropped and 0 is returned. Wait-free and allocation/lock/syscall free, so
 * it is safe to call directly from an OS MIDI callback (incl. WinMM MidiInProc).
 * Returns 1 when a message was enqueued, 0 when dropped or the ring was full. */
int le_midi_ring_push(le_midi* m, uint8_t status, uint8_t data1, uint8_t data2,
                      uint64_t ts_us);

/* Consumer side: pop every queued message and deliver each to the registered
 * callback (acquire-loaded; skipped once le_midi_close has nulled it). Call from
 * a backend-owned drain/worker thread, never from a restricted OS callback. */
void le_midi_drain(le_midi* m);

/* Per-handle backend state slot (the backend's own OS structs). */
void le_midi_set_backend_state(le_midi* m, void* state);
void* le_midi_get_backend_state(le_midi* m);

/* ---- per-OS backend factories (each defined only in its matching TU) ---- */
const le_midi_backend* le_midi_apple_backend(void);
const le_midi_backend* le_midi_linux_backend(void);
const le_midi_backend* le_midi_windows_backend(void);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_MIDI_BACKEND_H */
