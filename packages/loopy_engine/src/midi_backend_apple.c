/*
 * midi_backend_apple.c - CoreMIDI implementation of the MIDI-capture seam
 * (le_midi_backend.h).
 *
 * enumerate() walks MIDIGetSource(), reading kMIDIPropertyDisplayName for the
 * label and kMIDIPropertyUniqueID for the id (stable across replug/reboot).
 * open() creates a MIDI client + input port, connects the chosen source, and
 * the input read callback (run on CoreMIDI's own delivery thread) splits each
 * packet into messages and feeds Note/CC bytes through le_midi_ring_push +
 * le_midi_drain.
 *
 * It uses the classic MIDIInputPortCreate / MIDIReadProc rather than the macOS
 * 11 MIDIInputPortCreateWithProtocol: the classic API is a plain C function
 * pointer (no Blocks runtime, no @available guard in a C TU) and delivers raw
 * MIDI 1.0 bytes directly, so it compiles cleanly at the pod's existing 10.14
 * deployment target. The only cost is a deprecation warning, which does not fail
 * the build.
 *
 * The whole file is wrapped in `#if defined(__APPLE__)`; off Apple it compiles
 * to a near-empty object, mirroring engine_apple.c.
 */
#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "le_midi_backend.h"
#include "loopy_engine_api.h"

typedef struct le_core_midi_state {
  MIDIClientRef client;
  MIDIPortRef port;
  MIDIEndpointRef source;
  le_midi* owner;
  uint32_t numer; /* mach timebase: ns = ticks * numer / denom */
  uint32_t denom;
} le_core_midi_state;

/* Reads a CFString endpoint property into a UTF-8 buffer (empty on failure). */
static void le_core_string_prop(MIDIObjectRef obj, CFStringRef prop, char* out,
                                size_t cap) {
  if (cap == 0) return;
  out[0] = '\0';
  CFStringRef s = NULL;
  if (MIDIObjectGetStringProperty(obj, prop, &s) == noErr && s != NULL) {
    CFStringGetCString(s, out, (CFIndex)cap, kCFStringEncodingUTF8);
    CFRelease(s);
  }
}

/* The persisted id for a source: its unique id as a decimal string, falling
 * back to the display name when the property is unavailable. */
static void le_core_source_id(MIDIEndpointRef src, char* out, size_t cap) {
  SInt32 uid = 0;
  if (MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid) == noErr) {
    snprintf(out, cap, "%d", (int)uid);
  } else {
    le_core_string_prop(src, kMIDIPropertyDisplayName, out, cap);
  }
}

static int32_t le_core_midi_enumerate(le_midi_info* out, int32_t max,
                                      int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  const ItemCount n = MIDIGetNumberOfSources();
  for (ItemCount i = 0; i < n && *count < max; ++i) {
    MIDIEndpointRef src = MIDIGetSource(i);
    if (src == 0) continue;
    le_midi_info* info = &out[*count];
    memset(info, 0, sizeof(*info));
    le_core_string_prop(src, kMIDIPropertyDisplayName, info->name,
                        sizeof(info->name));
    le_core_source_id(src, info->id, sizeof(info->id));
    info->is_default = 0; /* CoreMIDI exposes no system-default input */
    (*count)++;
  }
  return LE_OK;
}

static MIDIEndpointRef le_core_find_source(const char* id) {
  const ItemCount n = MIDIGetNumberOfSources();
  for (ItemCount i = 0; i < n; ++i) {
    MIDIEndpointRef src = MIDIGetSource(i);
    if (src == 0) continue;
    char buf[256];
    le_core_source_id(src, buf, sizeof(buf));
    if (strcmp(buf, id) == 0) return src;
  }
  return 0;
}

static uint64_t le_core_ts_to_us(const le_core_midi_state* st,
                                 MIDITimeStamp ts) {
  if (ts == 0) ts = mach_absolute_time(); /* 0 means "now" */
  /* ns = ts * numer / denom; widen to 128-bit to avoid overflow. */
  const unsigned __int128 ns =
      (unsigned __int128)ts * st->numer / st->denom;
  return (uint64_t)(ns / 1000u);
}

/* Splits a packet's raw byte stream into complete channel-voice / system
 * messages and pushes the Note/CC ones (the ring filters the rest). */
static void le_core_push_bytes(le_midi* owner, const Byte* data, UInt16 len,
                               uint64_t ts_us) {
  UInt16 i = 0;
  while (i < len) {
    const uint8_t status = data[i];
    if (status < 0x80u) {
      i++; /* stray data byte (CoreMIDI does not use running status): skip */
      continue;
    }
    if (status == 0xF0u) { /* SysEx: skip through the 0xF7 terminator */
      i++;
      while (i < len && data[i] != 0xF7u) i++;
      if (i < len) i++;
      continue;
    }
    if (status >= 0xF1u) {
      i++; /* single-byte system / real-time message */
      continue;
    }
    const uint8_t hi = (uint8_t)(status & 0xF0u);
    const int datalen = (hi == 0xC0u || hi == 0xD0u) ? 1 : 2;
    const uint8_t d1 = (i + 1 < len) ? data[i + 1] : 0;
    const uint8_t d2 = (datalen == 2 && i + 2 < len) ? data[i + 2] : 0;
    le_midi_ring_push(owner, status, d1, d2, ts_us);
    i = (UInt16)(i + 1 + datalen);
  }
}

static void le_core_read_proc(const MIDIPacketList* pktlist, void* readRefCon,
                              void* srcRefCon) {
  (void)srcRefCon;
  le_core_midi_state* st = (le_core_midi_state*)readRefCon;
  if (st == NULL || pktlist == NULL) return;
  const MIDIPacket* pkt = &pktlist->packet[0];
  for (UInt32 i = 0; i < pktlist->numPackets; ++i) {
    le_core_push_bytes(st->owner, pkt->data, pkt->length,
                       le_core_ts_to_us(st, pkt->timeStamp));
    pkt = MIDIPacketNext(pkt);
  }
  le_midi_drain(st->owner);
}

static int32_t le_core_midi_close(le_midi* m) {
  le_core_midi_state* st = (le_core_midi_state*)le_midi_get_backend_state(m);
  if (st == NULL) return LE_OK; /* idempotent */
  if (st->port != 0 && st->source != 0) {
    MIDIPortDisconnectSource(st->port, st->source);
  }
  if (st->port != 0) MIDIPortDispose(st->port);
  if (st->client != 0) MIDIClientDispose(st->client);
  free(st);
  le_midi_set_backend_state(m, NULL);
  return LE_OK;
}

static int32_t le_core_midi_open(le_midi* m, const char* id) {
  if (id == NULL || id[0] == '\0') return LE_ERR_DEVICE;

  le_core_midi_state* st =
      (le_core_midi_state*)calloc(1, sizeof(le_core_midi_state));
  if (st == NULL) return LE_ERR_DEVICE;
  st->owner = m;
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  st->numer = tb.numer;
  st->denom = (tb.denom != 0) ? tb.denom : 1;
  le_midi_set_backend_state(m, st);

  st->source = le_core_find_source(id);
  if (st->source == 0) {
    le_core_midi_close(m);
    return LE_ERR_DEVICE;
  }
  if (MIDIClientCreate(CFSTR("loopy"), NULL, NULL, &st->client) != noErr) {
    le_core_midi_close(m);
    return LE_ERR_DEVICE;
  }
  if (MIDIInputPortCreate(st->client, CFSTR("loopy MIDI in"),
                          le_core_read_proc, st, &st->port) != noErr) {
    le_core_midi_close(m);
    return LE_ERR_DEVICE;
  }
  if (MIDIPortConnectSource(st->port, st->source, st) != noErr) {
    le_core_midi_close(m);
    return LE_ERR_DEVICE;
  }
  return LE_OK;
}

static const le_midi_backend kLeCoreMidiBackend = {
    le_core_midi_enumerate,
    le_core_midi_open,
    le_core_midi_close,
};

const le_midi_backend* le_midi_apple_backend(void) {
  return &kLeCoreMidiBackend;
}

#else
typedef int loopy_midi_apple_tu_unused; /* keep the TU non-empty off Apple */
#endif
