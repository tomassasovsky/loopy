/*
 * midi_backend_windows.c - WinMM implementation of the MIDI-capture seam
 * (le_midi_backend.h).
 *
 * WinMM delivers short MIDI messages to a MidiInProc callback that runs in a
 * restricted context: it MUST NOT call back into winmm or do allocation/blocking
 * work. So MidiInProc only parses + pushes to the lock-free ring (both
 * allocation/lock free) and signals an auto-reset event; a dedicated worker
 * thread waits on that event and runs le_midi_drain (which invokes the Dart
 * callback) off the callback context.
 *
 * Device identity: WinMM exposes no stable id and no system-default input, so
 * the id is the device name (szPname, truncated to 31 chars by the API).
 * Duplicate names are disambiguated with a "#<index>" suffix; the device index
 * is NOT stable across replug, which is the documented WinMM caveat. enumerate()
 * and open() build the exact same disambiguated names so a persisted id maps
 * back to the right device whenever the set of ports is unchanged.
 *
 * The whole file is wrapped in `#if defined(_WIN32)`; off Windows it compiles to
 * a near-empty object (a dummy typedef keeps the TU non-empty), mirroring
 * engine_windows.c.
 */
#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmeapi.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "le_midi_backend.h"
#include "loopy_engine_api.h"

/* Per-open OS state stashed on the le_midi handle via le_midi_set_backend_state. */
typedef struct le_win_midi_state {
  HMIDIIN handle;     /* open input device */
  HANDLE signal;      /* auto-reset event, set by MidiInProc */
  HANDLE thread;      /* worker that drains the ring -> callback */
  volatile LONG running;
  le_midi* owner;
} le_win_midi_state;

/* UTF-8 base name (szPname) of input device `idx`. Returns 1 on success. */
static int le_win_base_name(UINT idx, char* out, size_t cap) {
  if (cap == 0) return 0;
  out[0] = '\0';
  MIDIINCAPSW caps;
  if (midiInGetDevCapsW(idx, &caps, sizeof(caps)) != MMSYSERR_NOERROR) {
    return 0;
  }
  const int written = WideCharToMultiByte(CP_UTF8, 0, caps.szPname, -1, out,
                                          (int)cap, NULL, NULL);
  if (written <= 0) {
    out[0] = '\0';
    return 0;
  }
  out[cap - 1] = '\0';
  return 1;
}

/* Disambiguated name of device `idx` given `total` devices: appends "#<idx>"
 * when another device shares the same base name. Deterministic, so enumerate()
 * and open() agree. */
static void le_win_disambiguated(UINT idx, UINT total, char* out, size_t cap) {
  char base[256];
  if (!le_win_base_name(idx, base, sizeof(base))) {
    out[0] = '\0';
    return;
  }
  int duplicate = 0;
  for (UINT j = 0; j < total; ++j) {
    if (j == idx) continue;
    char other[256];
    if (le_win_base_name(j, other, sizeof(other)) &&
        strcmp(other, base) == 0) {
      duplicate = 1;
      break;
    }
  }
  if (duplicate) {
    snprintf(out, cap, "%s #%u", base, idx);
  } else {
    snprintf(out, cap, "%s", base);
  }
}

static int32_t le_win_midi_enumerate(le_midi_info* out, int32_t max,
                                     int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  const UINT total = midiInGetNumDevs();
  for (UINT i = 0; i < total && *count < max; ++i) {
    char name[256];
    le_win_disambiguated(i, total, name, sizeof(name));
    if (name[0] == '\0') continue; /* unreadable caps: skip */
    le_midi_info* info = &out[*count];
    memset(info, 0, sizeof(*info));
    snprintf(info->id, sizeof(info->id), "%s", name);   /* id == name */
    snprintf(info->name, sizeof(info->name), "%s", name);
    info->is_default = 0; /* WinMM has no system-default MIDI input */
    (*count)++;
  }
  return LE_OK;
}

/* Resolves a persisted id back to a current device index, or -1 if absent. */
static int le_win_find_index(const char* id) {
  if (id == NULL || id[0] == '\0') return -1;
  const UINT total = midiInGetNumDevs();
  for (UINT i = 0; i < total; ++i) {
    char name[256];
    le_win_disambiguated(i, total, name, sizeof(name));
    if (name[0] != '\0' && strcmp(name, id) == 0) return (int)i;
  }
  return -1;
}

static void CALLBACK le_win_midi_proc(HMIDIIN h, UINT msg, DWORD_PTR inst,
                                      DWORD_PTR p1, DWORD_PTR p2) {
  (void)h;
  if (msg != MIM_DATA) return; /* ignore MIM_LONGDATA (SysEx), open/close, etc. */
  le_win_midi_state* st = (le_win_midi_state*)inst;
  if (st == NULL) return;
  const uint8_t status = (uint8_t)(p1 & 0xFFu);
  const uint8_t d1 = (uint8_t)((p1 >> 8) & 0xFFu);
  const uint8_t d2 = (uint8_t)((p1 >> 16) & 0xFFu);
  const uint64_t ts_us = (uint64_t)p2 * 1000ull; /* dwParam2 is ms since start */
  /* Only push (allocation/lock free) and signal; the worker does the delivery. */
  if (le_midi_ring_push(st->owner, status, d1, d2, ts_us)) {
    SetEvent(st->signal);
  }
}

static DWORD WINAPI le_win_midi_worker(LPVOID arg) {
  le_win_midi_state* st = (le_win_midi_state*)arg;
  while (WaitForSingleObject(st->signal, INFINITE) == WAIT_OBJECT_0) {
    le_midi_drain(st->owner);
    if (st->running == 0) break; /* volatile read; set to 0 by close */
  }
  le_midi_drain(st->owner); /* final flush after shutdown signal */
  return 0;
}

static int32_t le_win_midi_close(le_midi* m) {
  le_win_midi_state* st = (le_win_midi_state*)le_midi_get_backend_state(m);
  if (st == NULL) return LE_OK; /* idempotent */

  if (st->handle != NULL) {
    midiInStop(st->handle);
    midiInReset(st->handle); /* return any pending buffers; flush callbacks */
    midiInClose(st->handle); /* no further MidiInProc after this returns */
  }
  if (st->thread != NULL) {
    InterlockedExchange(&st->running, 0);
    if (st->signal != NULL) SetEvent(st->signal); /* wake the worker to exit */
    WaitForSingleObject(st->thread, INFINITE);
    CloseHandle(st->thread);
  }
  if (st->signal != NULL) CloseHandle(st->signal);
  free(st);
  le_midi_set_backend_state(m, NULL);
  return LE_OK;
}

static int32_t le_win_midi_open(le_midi* m, const char* id) {
  const int idx = le_win_find_index(id);
  if (idx < 0) return LE_ERR_DEVICE;

  le_win_midi_state* st =
      (le_win_midi_state*)calloc(1, sizeof(le_win_midi_state));
  if (st == NULL) return LE_ERR_DEVICE;
  st->owner = m;
  InterlockedExchange(&st->running, 1);
  st->signal = CreateEvent(NULL, FALSE, FALSE, NULL); /* auto-reset */
  if (st->signal == NULL) {
    free(st);
    return LE_ERR_DEVICE;
  }
  st->thread = CreateThread(NULL, 0, le_win_midi_worker, st, 0, NULL);
  if (st->thread == NULL) {
    CloseHandle(st->signal);
    free(st);
    return LE_ERR_DEVICE;
  }

  /* Stash state before opening so a MidiInProc that fires immediately finds it. */
  le_midi_set_backend_state(m, st);
  const MMRESULT mr =
      midiInOpen(&st->handle, (UINT)idx, (DWORD_PTR)le_win_midi_proc,
                 (DWORD_PTR)st, CALLBACK_FUNCTION);
  if (mr != MMSYSERR_NOERROR) {
    st->handle = NULL;
    le_win_midi_close(m); /* tears down thread + event, clears state */
    return LE_ERR_DEVICE;
  }
  midiInStart(st->handle);
  return LE_OK;
}

static const le_midi_backend kLeWinMidiBackend = {
    le_win_midi_enumerate,
    le_win_midi_open,
    le_win_midi_close,
};

const le_midi_backend* le_midi_windows_backend(void) {
  return &kLeWinMidiBackend;
}

#else
typedef int loopy_midi_windows_tu_unused; /* keep the TU non-empty off Windows */
#endif
