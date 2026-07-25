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
#include <pthread.h>   /* pthread_setschedparam for the appliance RT audio thread */
#include <sched.h>     /* SCHED_FIFO, struct sched_param */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>  /* stat() — probe /proc/asound/cardN pcm direction */

#include "engine_platform.h"  /* the seam */
#include "engine_private.h"   /* struct le_engine, enumerate_devices, store_i32;
                               * le_config / le_device_info / LE_MAX_CHANNELS /
                               * LE_OK + ma_backend arrive transitively */

/* The appliance sets LOOPY_ALSA_ONLY (via the kiosk launcher): a single app owns
 * the card with no PipeWire/JACK/Pulse in the image, so we drive ALSA directly
 * for the lowest latency and zero IPC, and skip all the PipeWire quantum plumbing.
 * Read once and cache — the env does not change over a process's life. */
static int le_alsa_only(void) {
  static int cached = -1;
  if (cached < 0) {
    const char* v = getenv("LOOPY_ALSA_ONLY");
    cached = (v != NULL && v[0] != '\0' && v[0] != '0') ? 1 : 0;
  }
  return cached;
}

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
#define LE_JACK_PHYSICAL 0x4UL
/* jack_client_open option: never auto-start a JACK server for a transient probe. */
#define LE_JACK_NO_START_SERVER 0x1
/* Well-known JACK metadata key (jack/metadata.h) — PipeWire publishes a node's
 * description here, giving us "Scarlett 4i4 USB" instead of the raw node id. */
#define LE_JACK_PRETTY_NAME "http://jackaudio.org/metadata/pretty-name"

/* The trailing decimal index of a port name (e.g. "…AUX10" -> 10), or -1 when it
 * has none — used to sort ports numerically rather than by registration order. */
static long le_trailing_int(const char* s) {
  size_t end = strlen(s);
  size_t i = end;
  while (i > 0 && s[i - 1] >= '0' && s[i - 1] <= '9') --i;
  return i < end ? strtol(s + i, NULL, 10) : -1;
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
    /* The selected device id IS the JACK client/node name (that is how
     * le_platform_enumerate_devices reports it), so the port prefix is just
     * "<id>:capture_" / "<id>:playback_" — no name resolution needed. An empty
     * id (system default) or a stale non-JACK id simply matches no ports, and
     * le_jack_rewire leaves miniaudio's default auto-connections in place. */
    char prefix[300];

    const char* cap_id = config->capture_device_id;
    if (cap_id != NULL && cap_id[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:capture_", cap_id);
      int32_t m = le_jack_rewire(
          client, get_ports, connect_port, disconnect_port, port_name,
          port_conns, jfree, (void**)engine->device.jack.ppPortsCapture,
          engine->in_channels, prefix, LE_JACK_OUTPUT, /*we_are_src=*/0);
      if (m > 0 && m <= engine->in_channels) {
        store_i32(&engine->a_in_channels, m);
      }
    }

    const char* play_id = config->playback_device_id;
    if (play_id != NULL && play_id[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:playback_", play_id);
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

/* JACK entry points used only for enumeration (opened transiently, separate from
 * the engine's own client). jack_client_open is variadic in the header, but we
 * pass no variadic args, so a fixed 3-arg pointer is ABI-correct. The metadata
 * trio is optional — older libjack lacks it — so each is NULL-guarded. */
typedef void* (*le_jack_open_t)(const char*, int, int*);
typedef int (*le_jack_close_t)(void*);
typedef char* (*le_jack_uuid_for_name_t)(void*, const char*);
typedef int (*le_jack_uuid_parse_t)(const char*, uint64_t*);
typedef int (*le_jack_get_prop_t)(uint64_t, const char*, char**, char**);

/* Resolve a JACK client/node's friendly name via its pretty-name metadata
 * (PipeWire publishes node.description there). Leaves out[0]='\0' if the
 * metadata API or the property is absent, so the caller can fall back. */
static void le_jack_pretty_name(void* client, const char* node,
                                le_jack_uuid_for_name_t uuid_for_name,
                                le_jack_uuid_parse_t uuid_parse,
                                le_jack_get_prop_t get_prop,
                                le_jack_free_t jfree, char* out, size_t cap) {
  out[0] = '\0';
  if (!uuid_for_name || !uuid_parse || !get_prop) return;
  char* uuid_str = uuid_for_name(client, node);
  if (uuid_str == NULL) return;
  uint64_t uuid = 0;
  if (uuid_parse(uuid_str, &uuid) == 0) {
    char* value = NULL;
    char* type = NULL;
    if (get_prop(uuid, LE_JACK_PRETTY_NAME, &value, &type) == 0 &&
        value != NULL) {
      strncpy(out, value, cap - 1);
      out[cap - 1] = '\0';
    }
    if (value) jfree(value);
    if (type) jfree(type);
  }
  jfree(uuid_str);
}

/* Lowest PCM device index on ALSA card `card` that has a stream in the requested
 * direction, or -1 if none — probed from /proc/asound/cardN/pcm<dev><c|p>. */
static int le_alsa_card_pcm_dev(int card, int capture) {
  const char suffix = capture ? 'c' : 'p';
  for (int dev = 0; dev < 8; ++dev) {
    char path[64];
    struct stat st;
    snprintf(path, sizeof(path), "/proc/asound/card%d/pcm%d%c", card, dev,
             suffix);
    if (stat(path, &st) == 0) return dev;
  }
  return -1;
}

/* Appliance ALSA enumeration: one clean entry per real sound card from
 * /proc/asound/cards (e.g. "Scarlett 4i4 USB"), NOT the ALSA PCM-hint namespace
 * (default, sysdefault, plughw, dmix, front, surround40, samplerate, speex, ...)
 * which is the clutter miniaudio would otherwise surface. The id is
 * ":<card>,<dev>", which is exactly the token miniaudio's simplified ALSA
 * enumeration produces for that hardware device, so le_resolve_device_id still
 * pins it and it opens the raw device directly. Cards without a PCM in the
 * requested direction (HDMI has no capture, say) are skipped. */
static int le_alsa_enumerate_cards(le_device_info* out, int32_t max,
                                   int32_t* count, int capture) {
  *count = 0;
  FILE* f = fopen("/proc/asound/cards", "r");
  if (f == NULL) return 0;

  char line[512];
  int32_t n = 0;
  while (n < max && fgets(line, sizeof(line), f) != NULL) {
    /* Card header lines start with the index: " 2 [USB    ]: USB-Audio - Name".
     * The indented continuation line (the longname) has no leading digit. */
    const char* p = line;
    while (*p == ' ') ++p;
    if (*p < '0' || *p > '9') continue;
    const int card = (int)strtol(p, NULL, 10);
    if (card < 0) continue;

    /* Card name = text after " - " (the driver's card name, e.g. the friendly
     * interface name), trimmed. */
    char* name = strstr(line, " - ");
    if (name == NULL) continue;
    name += 3;
    size_t len = strlen(name);
    while (len > 0 && (name[len - 1] == '\n' || name[len - 1] == '\r' ||
                       name[len - 1] == ' ')) {
      name[--len] = '\0';
    }
    if (len == 0) continue;

    /* Drop the SoC HDMI audio outputs — a live-looping appliance routes through
     * its audio interface, not the display's HDMI audio, so they are only clutter
     * in the picker. Matched by the vc4-hdmi card name. */
    if (strstr(line, "vc4-hdmi") != NULL || strstr(line, "vc4hdmi") != NULL) {
      continue;
    }

    const int dev = le_alsa_card_pcm_dev(card, capture);
    if (dev < 0) continue; /* no PCM in this direction on this card */

    le_device_info* d = &out[n];
    memset(d, 0, sizeof(*d));
    snprintf(d->id, sizeof(d->id), ":%d,%d", card, dev);
    strncpy(d->name, name, sizeof(d->name) - 1);
    d->name[sizeof(d->name) - 1] = '\0';
    ++n;
  }

  fclose(f);
  *count = n;
  return n > 0 ? 1 : 0;
}

static int le_jack_enumerate_devices(le_device_info* out, int32_t max,
                                     int32_t* count, int capture) {
  *count = 0;
  void* lib = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) lib = dlopen("libjack.so", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) return 0; /* no JACK/PipeWire -> defer to ALSA enumeration */

  le_jack_open_t jopen = (le_jack_open_t)dlsym(lib, "jack_client_open");
  le_jack_close_t jclose = (le_jack_close_t)dlsym(lib, "jack_client_close");
  le_jack_get_ports_t get_ports =
      (le_jack_get_ports_t)dlsym(lib, "jack_get_ports");
  le_jack_free_t jfree = (le_jack_free_t)dlsym(lib, "jack_free");
  le_jack_uuid_for_name_t uuid_for_name =
      (le_jack_uuid_for_name_t)dlsym(lib, "jack_get_uuid_for_client_name");
  le_jack_uuid_parse_t uuid_parse =
      (le_jack_uuid_parse_t)dlsym(lib, "jack_uuid_parse");
  le_jack_get_prop_t get_prop =
      (le_jack_get_prop_t)dlsym(lib, "jack_get_property");

  if (!jopen || !jclose || !get_ports || !jfree) {
    dlclose(lib);
    return 0;
  }

  int status = 0;
  void* client = jopen("loopy-enum", LE_JACK_NO_START_SERVER, &status);
  if (client == NULL) {
    dlclose(lib); /* server not running -> defer to ALSA enumeration */
    return 0;
  }

  /* One entry per real interface. capture wants the device's OUTPUT ports (it
   * produces audio into the graph), playback its INPUT ports; physical-only
   * keeps it to hardware, not app/monitor nodes. Group ports by their
   * "<node>:" prefix — that prefix is the id le_jack_pin_to_device pins by. */
  const unsigned long flags =
      (capture ? LE_JACK_OUTPUT : LE_JACK_INPUT) | LE_JACK_PHYSICAL;
  const char** ports = get_ports(client, NULL, NULL, flags);

  int32_t n = 0;
  for (int k = 0; ports != NULL && ports[k] != NULL && n < max; ++k) {
    const char* colon = strchr(ports[k], ':');
    if (colon == NULL) continue;
    const size_t plen = (size_t)(colon - ports[k]);
    if (plen == 0 || plen >= sizeof(out[0].id)) continue;

    int32_t found = -1;
    for (int32_t d = 0; d < n; ++d) {
      if (strncmp(out[d].id, ports[k], plen) == 0 && out[d].id[plen] == '\0') {
        found = d;
        break;
      }
    }
    if (found >= 0) {
      if (capture) {
        out[found].input_channels++;
      } else {
        out[found].output_channels++;
      }
      continue;
    }

    le_device_info* dev = &out[n];
    memset(dev, 0, sizeof(*dev));
    memcpy(dev->id, ports[k], plen);
    dev->id[plen] = '\0';
    if (capture) {
      dev->input_channels = 1;
    } else {
      dev->output_channels = 1;
    }
    le_jack_pretty_name(client, dev->id, uuid_for_name, uuid_parse, get_prop,
                        jfree, dev->name, sizeof(dev->name));
    if (dev->name[0] == '\0') {
      strncpy(dev->name, dev->id, sizeof(dev->name) - 1);
      dev->name[sizeof(dev->name) - 1] = '\0';
    }
    ++n;
  }

  if (ports != NULL) jfree((void*)ports);
  jclose(client);
  dlclose(lib);

  if (n == 0) return 0; /* JACK up but no hardware ports -> let ALSA try */
  *count = n;
  return 1;
}

int le_platform_enumerate_devices(le_device_info* out, int32_t max,
                                  int32_t* count, int capture) {
  /* Appliance (direct ALSA, no JACK): list real sound cards cleanly. Desktop
   * Linux runs under PipeWire/JACK, so use the JACK enumeration there (clean
   * names + only real interfaces). Either way, no ALSA PCM-hint clutter. */
  if (le_alsa_only()) {
    return le_alsa_enumerate_cards(out, max, count, capture);
  }
  return le_jack_enumerate_devices(out, max, count, capture);
}

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* Appliance (LOOPY_ALSA_ONLY): drive the card directly through ALSA — lowest
   * latency, zero IPC, and the image ships no PipeWire/JACK/Pulse anyway.
   * Elsewhere (desktop Linux) miniaudio's PulseAudio backend returns silent
   * capture buffers under PipeWire's pulse emulation (verified on a Clarett+
   * 8Pre: pulse = silence, JACK = full multichannel capture), so prefer JACK
   * (PipeWire ships a JACK server), then PulseAudio, then ALSA. */
  static const ma_backend k_alsa_only[] = {ma_backend_alsa};
  static const ma_backend k_backends[] = {
      ma_backend_jack, ma_backend_pulseaudio, ma_backend_alsa};
  if (le_alsa_only()) {
    *out_list = k_alsa_only;
    *out_count = 1;
  } else {
    *out_list = k_backends;
    *out_count = 3;
  }
}

void le_platform_before_context_init(const le_config* config) {
  /* ALSA takes its period directly from ma_device_config (periodSizeInFrames),
   * so the appliance needs none of the PipeWire quantum plumbing. */
  if (le_alsa_only()) return;
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

/* Appliance only: put the miniaudio worker thread (which runs the ALSA duplex
 * read/write loop and calls the audio callback, so it is the thread that must
 * meet the period deadline) on SCHED_FIFO 80 — above all normal work, with
 * headroom below for the USB sound-card IRQ thread (raised higher by the rtirq
 * service) so the interrupt delivering a period always preempts the thread
 * consuming it. Cross-thread setschedparam is fine. Needs LimitRTPRIO/MEMLOCK on
 * loopy.service; without them it EPERMs and is a harmless no-op. */
static void le_alsa_set_rt_priority(le_engine* engine) {
  if (!le_alsa_only() || !engine->device_initialised) return;
  /* Opt-in via LOOPY_RT_AUDIO=1 (set by the kiosk launcher once the ALSA path is
   * validated). Gated so a misbehaving audio loop cannot hard-starve the machine
   * at SCHED_FIFO before it has been proven to sleep between periods. */
  const char* rt = getenv("LOOPY_RT_AUDIO");
  if (rt == NULL || rt[0] != '1') return;
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = 80;
  (void)pthread_setschedparam(engine->device.thread, SCHED_FIFO, &sp);
}

void le_platform_after_device_open(le_engine* engine) {
  /* Appliance: promote the audio thread to real-time BEFORE it starts reading,
   * while it is still idle, so it never runs its deadline-critical first reads
   * at normal priority (which overruns the capture at tiny buffers). */
  le_alsa_set_rt_priority(engine);
}

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  /* Repin JACK ports to the selected interface (overriding miniaudio's connect-
   * to-every-physical-port default), so channels map to that device only. No-op
   * unless the JACK backend is active, so it does nothing on the ALSA appliance. */
  le_jack_pin_to_device(engine, config);
}

void le_platform_on_engine_teardown(void) {
  if (le_alsa_only()) return; /* no PipeWire quantum was forced */
  le_pipewire_force_quantum(0); /* restore PipeWire's dynamic quantum */
}

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
  /* No Linux channel-label source yet (PipeWire labels are future work). */
  (void)uid;
  (void)channel_count;
  return 0;
}

void le_platform_device_id_to_str(const ma_device_id* id, char* out,
                                  size_t cap) {
  /* ALSA/PulseAudio/JACK device ids are NUL-terminated char strings. */
  if (cap == 0) return;
  strncpy(out, (const char*)id, cap - 1);
  out[cap - 1] = '\0';
}

#else
typedef int loopy_engine_linux_tu_unused; /* keep the TU non-empty off Linux */
#endif
