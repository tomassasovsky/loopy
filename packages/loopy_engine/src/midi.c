/*
 * midi.c - portable core of the native MIDI-input seam.
 *
 * Holds everything that is NOT OS-specific: the le_midi handle, a single-
 * producer / single-consumer lock-free message ring, the pure 3-byte parser,
 * the atomic callback pointer, the drain step, and the FFI entry points
 * (le_midi_create/destroy/enumerate/open/close). The per-OS capture code lives
 * in midi_backend_{apple,linux,windows}.c behind le_midi_backend; this file
 * includes NO CoreMIDI / ALSA / WinMM headers.
 *
 * Threading: an OS MIDI callback (any thread) calls le_midi_ring_push, which
 * parses + filters + enqueues without allocation, locking, or blocking. A
 * backend-owned drain thread calls le_midi_drain, which pops and invokes the
 * registered callback. le_midi_open stores the callback (release) before the
 * backend starts; le_midi_close nulls it (release) before the backend tears the
 * threads down, so a drain racing the close sees NULL and never calls into freed
 * Dart state (no use-after-free).
 */
#include "le_midi_backend.h"
#include "le_midi_internal.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* One captured message. POD; the ring stores these by value. */
typedef struct le_midi_msg {
  uint8_t status;
  uint8_t data1;
  uint8_t data2;
  uint64_t ts_us;
} le_midi_msg;

/* Ring capacity (power of two). A footswitch produces a handful of messages per
 * press; 128 slots is far beyond any plausible backlog between drains. One slot
 * is kept empty to distinguish full from empty, so usable slots == CAP - 1. */
#define LE_MIDI_RING_CAP 128u
#define LE_MIDI_RING_MASK (LE_MIDI_RING_CAP - 1u)

struct le_midi {
  /* SPSC ring (producer: OS callback thread; consumer: drain thread). */
  le_midi_msg ring[LE_MIDI_RING_CAP];
  _Atomic size_t head; /* consumer index (drain reads) */
  _Atomic size_t tail; /* producer index (OS callback writes) */

  /* Delivery callback. Nulled by le_midi_close before backend teardown. */
  _Atomic(le_midi_event_cb) cb;

  const le_midi_backend* backend; /* compiled-in per-OS backend (may be NULL) */
  void* backend_state;            /* OS state owned by the backend while open */
  _Atomic int is_open;            /* 1 between a successful open and a close */
};

/* ---- pure parser ---------------------------------------------------------- */

le_midi_kind le_midi_parse(uint8_t status, uint8_t data1, uint8_t data2,
                           le_midi_parsed* out) {
  le_midi_parsed p = {LE_MIDI_IGNORE, 0, 0, 0};
  /* A data byte (high bit clear) is never a status: running status is not
   * supported (the backends always deliver complete messages). */
  if (status >= 0x80u) {
    const uint8_t type = (uint8_t)(status & 0xF0u);
    p.channel = (uint8_t)(status & 0x0Fu);
    switch (type) {
      case 0x90u: /* Note On (velocity 0 == Note Off) */
        p.number = (uint8_t)(data1 & 0x7Fu);
        p.value = (uint8_t)(data2 & 0x7Fu);
        p.kind = (p.value == 0u) ? LE_MIDI_NOTE_OFF : LE_MIDI_NOTE_ON;
        break;
      case 0x80u: /* Note Off */
        p.number = (uint8_t)(data1 & 0x7Fu);
        p.value = (uint8_t)(data2 & 0x7Fu);
        p.kind = LE_MIDI_NOTE_OFF;
        break;
      case 0xB0u: /* Control Change */
        p.number = (uint8_t)(data1 & 0x7Fu);
        p.value = (uint8_t)(data2 & 0x7Fu);
        p.kind = LE_MIDI_CC;
        break;
      default:
        /* 0xA0 aftertouch, 0xC0 program change, 0xD0 channel pressure,
         * 0xE0 pitch bend, 0xF0 system/real-time/SysEx: all ignored. */
        p.kind = LE_MIDI_IGNORE;
        break;
    }
  }
  if (out != NULL) *out = p;
  return p.kind;
}

/* ---- ring + drain --------------------------------------------------------- */

int le_midi_ring_push(le_midi* m, uint8_t status, uint8_t data1, uint8_t data2,
                      uint64_t ts_us) {
  if (m == NULL) return 0;
  /* Drop anything that is not a Note/CC before it ever reaches the ring, so the
   * consumer (and the Dart activity indicator) never sees clock/sysex/etc. */
  if (le_midi_parse(status, data1, data2, NULL) == LE_MIDI_IGNORE) return 0;

  const size_t tail = atomic_load_explicit(&m->tail, memory_order_relaxed);
  const size_t head = atomic_load_explicit(&m->head, memory_order_acquire);
  if (tail - head >= LE_MIDI_RING_CAP - 1u) return 0; /* full: drop newest */

  le_midi_msg* slot = &m->ring[tail & LE_MIDI_RING_MASK];
  slot->status = status;
  slot->data1 = data1;
  slot->data2 = data2;
  slot->ts_us = ts_us;
  /* Release so the consumer sees the slot write before the advanced tail. */
  atomic_store_explicit(&m->tail, tail + 1u, memory_order_release);
  return 1;
}

void le_midi_drain(le_midi* m) {
  if (m == NULL) return;
  for (;;) {
    const size_t head = atomic_load_explicit(&m->head, memory_order_relaxed);
    const size_t tail = atomic_load_explicit(&m->tail, memory_order_acquire);
    if (head == tail) break; /* empty */
    const le_midi_msg msg = m->ring[head & LE_MIDI_RING_MASK];
    atomic_store_explicit(&m->head, head + 1u, memory_order_release);
    /* Load the callback per message: a concurrent le_midi_close may null it
     * mid-drain, after which we stop delivering immediately. */
    le_midi_event_cb cb = atomic_load_explicit(&m->cb, memory_order_acquire);
    if (cb != NULL) cb(msg.status, msg.data1, msg.data2, msg.ts_us);
  }
}

/* ---- backend state slot --------------------------------------------------- */

void le_midi_set_backend_state(le_midi* m, void* state) {
  if (m != NULL) m->backend_state = state;
}

void* le_midi_get_backend_state(le_midi* m) {
  return (m != NULL) ? m->backend_state : NULL;
}

/* ---- backend selection ---------------------------------------------------- */

const le_midi_backend* le_midi_select_backend(void) {
#if defined(__APPLE__)
  return le_midi_apple_backend();
#elif defined(__linux__)
  return le_midi_linux_backend();
#elif defined(_WIN32)
  return le_midi_windows_backend();
#else
  return NULL;
#endif
}

/* ---- FFI surface ---------------------------------------------------------- */

le_midi* le_midi_create(void) {
  le_midi* m = (le_midi*)calloc(1, sizeof(le_midi));
  if (m == NULL) return NULL;
  atomic_store_explicit(&m->head, 0, memory_order_relaxed);
  atomic_store_explicit(&m->tail, 0, memory_order_relaxed);
  atomic_store_explicit(&m->cb, NULL, memory_order_relaxed);
  atomic_store_explicit(&m->is_open, 0, memory_order_relaxed);
  m->backend = le_midi_select_backend();
  m->backend_state = NULL;
  return m;
}

int32_t le_midi_close(le_midi* m) {
  if (m == NULL) return LE_ERR_INVALID;
  /* Stop delivering BEFORE tearing down the backend threads, so an in-flight
   * drain cannot call the callback after this returns. */
  atomic_store_explicit(&m->cb, NULL, memory_order_release);
  if (m->backend != NULL && m->backend->close != NULL) {
    m->backend->close(m); /* idempotent: no-op when no state is set */
  }
  m->backend_state = NULL;
  atomic_store_explicit(&m->is_open, 0, memory_order_release);
  return LE_OK;
}

void le_midi_destroy(le_midi* m) {
  if (m == NULL) return;
  le_midi_close(m);
  free(m);
}

int32_t le_midi_enumerate(le_midi_info* out, int32_t max, int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  const le_midi_backend* b = le_midi_select_backend();
  if (b == NULL || b->enumerate == NULL) return LE_OK; /* no backend: empty */
  return b->enumerate(out, max, count);
}

int32_t le_midi_open(le_midi* m, const char* id, le_midi_event_cb cb) {
  if (m == NULL || cb == NULL) return LE_ERR_INVALID;
  if (m->backend == NULL || m->backend->open == NULL) return LE_ERR_DEVICE;

  /* Re-opening switches devices: drop the current one first (atomic A->B). */
  if (atomic_load_explicit(&m->is_open, memory_order_acquire)) {
    le_midi_close(m);
  }

  /* Publish the callback before the backend starts pushing/draining. */
  atomic_store_explicit(&m->cb, cb, memory_order_release);
  const int32_t rc = m->backend->open(m, id);
  if (rc != LE_OK) {
    /* Open failed: undo the callback and any partial state. */
    atomic_store_explicit(&m->cb, NULL, memory_order_release);
    if (m->backend->close != NULL) m->backend->close(m);
    m->backend_state = NULL;
    return rc;
  }
  atomic_store_explicit(&m->is_open, 1, memory_order_release);
  return LE_OK;
}

/* ---- MIDI output (portable core) ------------------------------------------ *
 *
 * Output is far simpler than input: no ring, no callback, no worker thread. The
 * handle just remembers the selected backend and its OS state; open/close/send
 * forward straight to the backend, which owns all OS-specific work. */

struct le_midi_out {
  const le_midi_out_backend* backend; /* compiled-in per-OS backend (may be NULL) */
  void* backend_state;                /* OS state owned by the backend while open */
  _Atomic int is_open;                /* 1 between a successful open and a close */
};

const le_midi_out_backend* le_midi_out_select_backend(void) {
#if defined(__APPLE__)
  return le_midi_apple_out_backend();
#elif defined(__linux__)
  return le_midi_linux_out_backend();
#elif defined(_WIN32)
  return le_midi_windows_out_backend();
#else
  return NULL;
#endif
}

void le_midi_out_set_backend_state(le_midi_out* m, void* state) {
  if (m != NULL) m->backend_state = state;
}

void* le_midi_out_get_backend_state(le_midi_out* m) {
  return (m != NULL) ? m->backend_state : NULL;
}

le_midi_out* le_midi_out_create(void) {
  le_midi_out* m = (le_midi_out*)calloc(1, sizeof(le_midi_out));
  if (m == NULL) return NULL;
  atomic_store_explicit(&m->is_open, 0, memory_order_relaxed);
  m->backend = le_midi_out_select_backend();
  m->backend_state = NULL;
  return m;
}

int32_t le_midi_out_close(le_midi_out* m) {
  if (m == NULL) return LE_ERR_INVALID;
  if (m->backend != NULL && m->backend->close != NULL) {
    m->backend->close(m); /* idempotent: no-op when no state is set */
  }
  m->backend_state = NULL;
  atomic_store_explicit(&m->is_open, 0, memory_order_release);
  return LE_OK;
}

void le_midi_out_destroy(le_midi_out* m) {
  if (m == NULL) return;
  le_midi_out_close(m);
  free(m);
}

int32_t le_midi_out_enumerate(le_midi_info* out, int32_t max, int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  const le_midi_out_backend* b = le_midi_out_select_backend();
  if (b == NULL || b->enumerate == NULL) return LE_OK; /* no backend: empty */
  return b->enumerate(out, max, count);
}

int32_t le_midi_out_open(le_midi_out* m, const char* id) {
  if (m == NULL) return LE_ERR_INVALID;
  if (m->backend == NULL || m->backend->open == NULL) return LE_ERR_DEVICE;

  /* Re-opening switches devices: drop the current one first (atomic A->B). */
  if (atomic_load_explicit(&m->is_open, memory_order_acquire)) {
    le_midi_out_close(m);
  }

  const int32_t rc = m->backend->open(m, id);
  if (rc != LE_OK) {
    if (m->backend->close != NULL) m->backend->close(m);
    m->backend_state = NULL;
    return rc;
  }
  atomic_store_explicit(&m->is_open, 1, memory_order_release);
  return LE_OK;
}

int32_t le_midi_out_send(le_midi_out* m, const uint8_t* data, int32_t len) {
  if (m == NULL || data == NULL || len <= 0) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&m->is_open, memory_order_acquire)) {
    return LE_ERR_DEVICE; /* nothing open */
  }
  if (m->backend == NULL || m->backend->send == NULL) return LE_ERR_DEVICE;
  return m->backend->send(m, data, len);
}

/* ---- test hooks ----------------------------------------------------------- */

void le_midi_set_cb_for_test(le_midi* m, le_midi_event_cb cb) {
  if (m != NULL) atomic_store_explicit(&m->cb, cb, memory_order_release);
}

int le_midi_push_for_test(le_midi* m, uint8_t status, uint8_t data1,
                          uint8_t data2, uint64_t ts_us) {
  return le_midi_ring_push(m, status, data1, data2, ts_us);
}
