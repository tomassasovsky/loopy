/*
 * engine_linux.c — Linux implementation of the engine platform seam
 * (engine_platform.h).
 *
 * Linux carries two real capabilities the portable core does not: a backend
 * preference (JACK first, since miniaudio's PulseAudio backend returns silent
 * capture under PipeWire's pulse emulation) plus PipeWire quantum forcing, and
 * JACK port-pinning that repins our ports to the user-selected interface. The
 * whole file is wrapped in `#if defined(__linux__)` so it compiles to a
 * near-empty object on macOS/Windows — a dummy typedef in the `#else` keeps the
 * translation unit non-empty (an entirely #if'd-out TU is UB in ISO C and warns
 * under -Wempty-translation-unit / -pedantic).
 */
#if defined(__linux__)

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_platform.h"  /* the seam */
#include "engine_private.h"   /* struct le_engine, enumerate_devices, store_i32;
                               * le_config / le_device_info / LE_MAX_CHANNELS /
                               * LE_OK + ma_backend arrive transitively */

/* Force PipeWire's global graph quantum to `frames` (0 restores the dynamic
 * quantum). The per-app PIPEWIRE_QUANTUM env wins only on the first connection
 * and loses to another driver's quantum on a reopen, so we force it globally.
 * Best-effort: pw-metadata ships with PipeWire; if it is missing or fails, the
 * env remains the fallback, so a discarded result is intentional. */
static void le_pipewire_force_quantum(int frames) {
  char cmd[160];
  snprintf(cmd, sizeof(cmd),
           "pw-metadata -n settings 0 clock.force-quantum %d >/dev/null 2>&1",
           frames);
  (void)system(cmd);
}

/* JACK port flags (jack/types.h). */
#define LE_JACK_INPUT 0x1UL
#define LE_JACK_OUTPUT 0x2UL

/* The trailing decimal index of a port name (e.g. "…AUX10" -> 10), or -1 when it
 * has none — used to sort ports numerically rather than by registration order. */
static long le_trailing_int(const char* s) {
  size_t end = strlen(s);
  size_t i = end;
  while (i > 0 && s[i - 1] >= '0' && s[i - 1] <= '9') --i;
  return i < end ? strtol(s + i, NULL, 10) : -1;
}

/* JACK port names are "<friendly device name>:<port>" (e.g.
 * "Clarett+ 8Pre Pro:capture_AUX0"), not the alsa object id we pin by. Resolve
 * the friendly name for a selected device id via our own enumeration. (The
 * enumeration runs on the default backend; on PipeWire its node description
 * matches the JACK port prefix, which is the case this targets.) */
static void le_jack_device_name(const char* id, int capture, char* out,
                                size_t cap) {
  out[0] = '\0';
  if (id == NULL || id[0] == '\0') return;
  le_device_info* devs = (le_device_info*)calloc(64, sizeof(le_device_info));
  if (devs == NULL) return;
  int32_t n = 0;
  if (enumerate_devices(devs, 64, &n, capture) != LE_OK) {
    free(devs);
    return;
  }
  for (int32_t i = 0; i < n; ++i) {
    if (strcmp(devs[i].id, id) == 0) {
      strncpy(out, devs[i].name, cap - 1);
      out[cap - 1] = '\0';
      break;
    }
  }
  free(devs);
}

/* Reconnects our `count` JACK ports (ppPorts) to the selected device's ports
 * whose name begins with `prefix` ("<name>:capture_" / ":playback_"), in order,
 * dropping miniaudio's aggregate auto-connections; the rest are left silent.
 * Returns the device's matching port count (so the caller can publish it as the
 * channel count). `flags` selects which device ports to match; `we_are_src`
 * is 1 for playback (our port -> device), 0 for capture (device -> our port). */
typedef const char** (*le_jack_get_ports_t)(void*, const char*, const char*,
                                            unsigned long);
typedef int (*le_jack_link_t)(void*, const char*, const char*);
typedef const char* (*le_jack_pname_t)(void*);
typedef const char** (*le_jack_conns_t)(void*, void*);
typedef void (*le_jack_free_t)(void*);

static int32_t le_jack_rewire(void* client, le_jack_get_ports_t get_ports,
                              le_jack_link_t connect_port,
                              le_jack_link_t disconnect_port,
                              le_jack_pname_t port_name,
                              le_jack_conns_t port_conns, le_jack_free_t jfree,
                              void** ppPorts, int32_t count, const char* prefix,
                              unsigned long flags, int we_are_src) {
  const char** all = get_ports(client, NULL, NULL, flags);
  if (all == NULL) return 0;
  const char* match[LE_MAX_CHANNELS];
  int32_t m = 0;
  const size_t plen = strlen(prefix);
  for (int k = 0; all[k] != NULL && m < LE_MAX_CHANNELS; ++k) {
    if (strncmp(all[k], prefix, plen) == 0) match[m++] = all[k];
  }
  /* jack_get_ports returns registration order, not numeric — sort by the port
   * name's trailing index (e.g. AUX2 before AUX10) so channel i maps to the i-th
   * physical channel. Names without a trailing number keep their order (stable
   * insertion sort), covering FL/FR-style ports. */
  for (int32_t a = 1; a < m; ++a) {
    const char* key = match[a];
    const long kn = le_trailing_int(key);
    int32_t b = a - 1;
    while (b >= 0 && le_trailing_int(match[b]) > kn) {
      match[b + 1] = match[b];
      --b;
    }
    match[b + 1] = key;
  }
  for (int32_t i = 0; i < count; ++i) {
    void* port = ppPorts[i];
    if (port == NULL) continue;
    const char* mine = port_name(port);
    const char** cur = port_conns(client, port);
    if (cur != NULL) {
      for (int j = 0; cur[j] != NULL; ++j) {
        if (we_are_src) {
          disconnect_port(client, mine, cur[j]);
        } else {
          disconnect_port(client, cur[j], mine);
        }
      }
      jfree((void*)cur);
    }
    if (i < m) {
      if (we_are_src) {
        connect_port(client, mine, match[i]);
      } else {
        connect_port(client, match[i], mine);
      }
    }
  }
  jfree((void*)all);
  return m;
}

/* miniaudio's JACK backend auto-connects our ports to ALL physical system ports
 * — every device PipeWire aggregates — so on a multi-device box our channels
 * land on the wrong hardware (a webcam mic on input 0, etc.). Rewire our ports
 * to connect ONLY to the user-selected device's "<name>:capture_*" /
 * ":playback_*" ports (skipping its monitor ports), in order, and publish that
 * device's channel count, so the mapping and the exposed channel count match the
 * interface like on CoreAudio. Best-effort: leaves the default auto-connections
 * if anything is unavailable. */
static void le_jack_pin_to_device(le_engine* engine, const le_config* config) {
  if (!engine->context_initialised ||
      engine->context.backend != ma_backend_jack) {
    return;
  }
  void* client = engine->device.jack.pClient;
  if (client == NULL) return;

  void* lib = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) lib = dlopen("libjack.so", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) return;

  le_jack_get_ports_t get_ports =
      (le_jack_get_ports_t)dlsym(lib, "jack_get_ports");
  le_jack_link_t connect_port = (le_jack_link_t)dlsym(lib, "jack_connect");
  le_jack_link_t disconnect_port = (le_jack_link_t)dlsym(lib, "jack_disconnect");
  le_jack_pname_t port_name = (le_jack_pname_t)dlsym(lib, "jack_port_name");
  le_jack_conns_t port_conns =
      (le_jack_conns_t)dlsym(lib, "jack_port_get_all_connections");
  le_jack_free_t jfree = (le_jack_free_t)dlsym(lib, "jack_free");

  if (get_ports && connect_port && disconnect_port && port_name && port_conns &&
      jfree) {
    char name[256];
    char prefix[300];

    le_jack_device_name(config->capture_device_id, /*capture=*/1, name,
                        sizeof(name));
    if (name[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:capture_", name);
      int32_t m = le_jack_rewire(
          client, get_ports, connect_port, disconnect_port, port_name,
          port_conns, jfree, (void**)engine->device.jack.ppPortsCapture,
          engine->in_channels, prefix, LE_JACK_OUTPUT, /*we_are_src=*/0);
      if (m > 0 && m <= engine->in_channels) {
        store_i32(&engine->a_in_channels, m);
      }
    }

    le_jack_device_name(config->playback_device_id, /*capture=*/0, name,
                        sizeof(name));
    if (name[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:playback_", name);
      int32_t m = le_jack_rewire(
          client, get_ports, connect_port, disconnect_port, port_name,
          port_conns, jfree, (void**)engine->device.jack.ppPortsPlayback,
          engine->out_channels, prefix, LE_JACK_INPUT, /*we_are_src=*/1);
      if (m > 0 && m <= engine->out_channels) {
        store_i32(&engine->a_out_channels, m);
      }
    }
  }
  dlclose(lib);
}

/* ---- platform seam ---- */

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* miniaudio's PulseAudio backend returns silent capture buffers under
   * PipeWire's pulse emulation (verified on a Clarett+ 8Pre: pulse = silence,
   * JACK = full multichannel capture). Prefer JACK (PipeWire ships a JACK
   * server), then PulseAudio, then ALSA. */
  static const ma_backend k_backends[] = {
      ma_backend_jack, ma_backend_pulseaudio, ma_backend_alsa};
  *out_list = k_backends;
  *out_count = 3;
}

void le_platform_before_context_init(const le_config* config) {
  /* JACK/PipeWire takes its buffer size (quantum) from the server and ignores
   * our requested period, so the in-app buffer selector would otherwise have no
   * effect on Linux latency. Two steps make it stick:
   *   1. export PIPEWIRE_QUANTUM before the JACK client connects (wins on the
   *      first connection);
   *   2. force the graph quantum globally via pw-metadata — a later reopen can
   *      otherwise inherit another driver's larger quantum (e.g. a webcam mic),
   *      and a per-app request loses to it. Best-effort: pw-metadata ships with
   *      PipeWire; if absent the env in (1) is the fallback. le_engine_destroy
   *      restores the dynamic quantum. */
  /* setenv is POSIX, not ISO C; declare it so a strict -std=c11 build (the
   * device-free test harness) sees it — the CMake build uses gnu11. */
  extern int setenv(const char* name, const char* value, int overwrite);
  /* Default to 256 frames (~5 ms) when no buffer is selected, instead of the
   * PipeWire server default (often 1024 / ~21 ms). */
  const int q_rate = config->sample_rate > 0 ? config->sample_rate : 48000;
  const int q_frames =
      config->buffer_frames > 0 ? (int)config->buffer_frames : 256;
  char quantum[32];
  snprintf(quantum, sizeof(quantum), "%d/%d", q_frames, q_rate);
  setenv("PIPEWIRE_QUANTUM", quantum, /*overwrite=*/1);
  le_pipewire_force_quantum(q_frames);
}

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  /* Repin JACK ports to the selected interface (overriding miniaudio's connect-
   * to-every-physical-port default), so channels map to that device only. */
  le_jack_pin_to_device(engine, config);
}

void le_platform_on_engine_teardown(void) {
  le_pipewire_force_quantum(0); /* restore PipeWire's dynamic quantum */
}

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
  /* No Linux channel-label source yet (PipeWire labels are future work). */
  (void)uid;
  (void)channel_count;
  return 0;
}

#else
typedef int loopy_engine_linux_tu_unused; /* keep the TU non-empty off Linux */
#endif
