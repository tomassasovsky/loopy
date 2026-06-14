/*
 * midi_backend_linux.c - ALSA sequencer implementation of the MIDI-capture seam
 * (le_midi_backend.h).
 *
 * enumerate() opens a transient sequencer client and walks every other client's
 * readable MIDI ports. open() creates our own writable port, subscribes it to
 * the chosen source, and runs a dedicated read thread that poll()s the sequencer
 * descriptors (plus a shutdown self-pipe) and converts each Note/CC event to raw
 * bytes through le_midi_ring_push + le_midi_drain.
 *
 * Device identity: ALSA client:port numbers are not stable across replug, so the
 * id is the source client name (matched by name on open); the label is the port
 * name. Hotplug is handled at the Dart layer by re-enumerating and diffing (the
 * same approach the audio device picker uses), so this backend subscribes to no
 * announce events.
 *
 * The whole file is wrapped in `#if defined(__linux__)`; off Linux it compiles
 * to a near-empty object, mirroring engine_linux.c.
 */
#if defined(__linux__)

#include <alsa/asoundlib.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "le_midi_backend.h"
#include "loopy_engine_api.h"

/* A source port must be readable AND subscribable-for-read to capture from it. */
#define LE_ALSA_READ_CAPS (SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ)

typedef struct le_alsa_midi_state {
  snd_seq_t* seq;
  int my_port;
  int stop_pipe[2]; /* [0] read end polled by the thread, [1] written by close */
  pthread_t thread;
  int thread_started;
  volatile int running;
  le_midi* owner;
} le_alsa_midi_state;

static uint64_t le_alsa_now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static int32_t le_alsa_midi_enumerate(le_midi_info* out, int32_t max,
                                      int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  snd_seq_t* seq = NULL;
  if (snd_seq_open(&seq, "default", SND_SEQ_OPEN_INPUT, 0) < 0) {
    return LE_OK; /* no sequencer available: empty list */
  }
  const int self = snd_seq_client_id(seq);

  snd_seq_client_info_t* cinfo;
  snd_seq_port_info_t* pinfo;
  snd_seq_client_info_alloca(&cinfo);
  snd_seq_port_info_alloca(&pinfo);
  snd_seq_client_info_set_client(cinfo, -1);
  while (snd_seq_query_next_client(seq, cinfo) >= 0 && *count < max) {
    const int client = snd_seq_client_info_get_client(cinfo);
    if (client == self || client == SND_SEQ_CLIENT_SYSTEM) continue;
    const char* cname = snd_seq_client_info_get_name(cinfo);
    snd_seq_port_info_set_client(pinfo, client);
    snd_seq_port_info_set_port(pinfo, -1);
    while (snd_seq_query_next_port(seq, pinfo) >= 0 && *count < max) {
      const unsigned int caps = snd_seq_port_info_get_capability(pinfo);
      if ((caps & LE_ALSA_READ_CAPS) != LE_ALSA_READ_CAPS) continue;
      const char* pname = snd_seq_port_info_get_name(pinfo);
      le_midi_info* info = &out[*count];
      memset(info, 0, sizeof(*info));
      snprintf(info->id, sizeof(info->id), "%s", (cname != NULL) ? cname : "");
      snprintf(info->name, sizeof(info->name), "%s",
               (pname != NULL) ? pname : ((cname != NULL) ? cname : ""));
      info->is_default = 0; /* ALSA has no system-default MIDI input */
      (*count)++;
    }
  }
  snd_seq_close(seq);
  return LE_OK;
}

/* Finds the first readable port whose client name matches `id`. */
static int le_alsa_find_source(snd_seq_t* seq, const char* id, int self,
                               int* out_client, int* out_port) {
  snd_seq_client_info_t* cinfo;
  snd_seq_port_info_t* pinfo;
  snd_seq_client_info_alloca(&cinfo);
  snd_seq_port_info_alloca(&pinfo);
  snd_seq_client_info_set_client(cinfo, -1);
  while (snd_seq_query_next_client(seq, cinfo) >= 0) {
    const int client = snd_seq_client_info_get_client(cinfo);
    if (client == self || client == SND_SEQ_CLIENT_SYSTEM) continue;
    const char* cname = snd_seq_client_info_get_name(cinfo);
    if (cname == NULL || strcmp(cname, id) != 0) continue;
    snd_seq_port_info_set_client(pinfo, client);
    snd_seq_port_info_set_port(pinfo, -1);
    while (snd_seq_query_next_port(seq, pinfo) >= 0) {
      const unsigned int caps = snd_seq_port_info_get_capability(pinfo);
      if ((caps & LE_ALSA_READ_CAPS) != LE_ALSA_READ_CAPS) continue;
      *out_client = client;
      *out_port = snd_seq_port_info_get_port(pinfo);
      return 1;
    }
  }
  return 0;
}

static void* le_alsa_midi_thread(void* arg) {
  le_alsa_midi_state* st = (le_alsa_midi_state*)arg;
  const int seq_fds = snd_seq_poll_descriptors_count(st->seq, POLLIN);
  struct pollfd* pfds =
      (struct pollfd*)calloc((size_t)seq_fds + 1, sizeof(struct pollfd));
  if (pfds == NULL) return NULL;
  snd_seq_poll_descriptors(st->seq, pfds, (unsigned int)seq_fds, POLLIN);
  pfds[seq_fds].fd = st->stop_pipe[0];
  pfds[seq_fds].events = POLLIN;

  while (st->running) {
    const int r = poll(pfds, (nfds_t)(seq_fds + 1), -1);
    if (r < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (pfds[seq_fds].revents & POLLIN) break; /* shutdown self-pipe */

    snd_seq_event_t* ev = NULL;
    while (snd_seq_event_input(st->seq, &ev) >= 0 && ev != NULL) {
      uint8_t status = 0, d1 = 0, d2 = 0;
      int have = 0;
      switch (ev->type) {
        case SND_SEQ_EVENT_NOTEON:
          status = (uint8_t)(0x90u | (ev->data.note.channel & 0x0Fu));
          d1 = ev->data.note.note;
          d2 = ev->data.note.velocity;
          have = 1;
          break;
        case SND_SEQ_EVENT_NOTEOFF:
          status = (uint8_t)(0x80u | (ev->data.note.channel & 0x0Fu));
          d1 = ev->data.note.note;
          d2 = ev->data.note.velocity;
          have = 1;
          break;
        case SND_SEQ_EVENT_CONTROLLER:
          status = (uint8_t)(0xB0u | (ev->data.control.channel & 0x0Fu));
          d1 = (uint8_t)(ev->data.control.param & 0x7F);
          d2 = (uint8_t)(ev->data.control.value & 0x7F);
          have = 1;
          break;
        default:
          break;
      }
      if (have) {
        le_midi_ring_push(st->owner, status, d1, d2, le_alsa_now_us());
        le_midi_drain(st->owner);
      }
    }
  }
  free(pfds);
  return NULL;
}

static int32_t le_alsa_midi_close(le_midi* m) {
  le_alsa_midi_state* st = (le_alsa_midi_state*)le_midi_get_backend_state(m);
  if (st == NULL) return LE_OK; /* idempotent */

  if (st->thread_started) {
    st->running = 0;
    if (st->stop_pipe[1] >= 0) {
      const char b = 1;
      ssize_t w = write(st->stop_pipe[1], &b, 1); /* wake the poll() */
      (void)w;
    }
    pthread_join(st->thread, NULL);
  }
  if (st->stop_pipe[0] >= 0) close(st->stop_pipe[0]);
  if (st->stop_pipe[1] >= 0) close(st->stop_pipe[1]);
  if (st->seq != NULL) {
    if (st->my_port >= 0) snd_seq_delete_simple_port(st->seq, st->my_port);
    snd_seq_close(st->seq);
  }
  free(st);
  le_midi_set_backend_state(m, NULL);
  return LE_OK;
}

static int32_t le_alsa_midi_open(le_midi* m, const char* id) {
  if (id == NULL || id[0] == '\0') return LE_ERR_DEVICE;

  le_alsa_midi_state* st =
      (le_alsa_midi_state*)calloc(1, sizeof(le_alsa_midi_state));
  if (st == NULL) return LE_ERR_DEVICE;
  st->owner = m;
  st->my_port = -1;
  st->stop_pipe[0] = -1;
  st->stop_pipe[1] = -1;
  le_midi_set_backend_state(m, st); /* so a failure path can close() cleanly */

  if (snd_seq_open(&st->seq, "default", SND_SEQ_OPEN_DUPLEX, 0) < 0) {
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }
  snd_seq_set_client_name(st->seq, "loopy");
  snd_seq_nonblock(st->seq, 1);
  const int self = snd_seq_client_id(st->seq);

  st->my_port = snd_seq_create_simple_port(
      st->seq, "loopy MIDI in",
      SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE,
      SND_SEQ_PORT_TYPE_APPLICATION | SND_SEQ_PORT_TYPE_MIDI_GENERIC);
  if (st->my_port < 0) {
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }

  int src_client = -1, src_port = -1;
  if (!le_alsa_find_source(st->seq, id, self, &src_client, &src_port)) {
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }
  if (snd_seq_connect_from(st->seq, st->my_port, src_client, src_port) < 0) {
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }

  if (pipe(st->stop_pipe) != 0) {
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }
  st->running = 1;
  if (pthread_create(&st->thread, NULL, le_alsa_midi_thread, st) != 0) {
    st->running = 0;
    le_alsa_midi_close(m);
    return LE_ERR_DEVICE;
  }
  st->thread_started = 1;
  return LE_OK;
}

static const le_midi_backend kLeAlsaMidiBackend = {
    le_alsa_midi_enumerate,
    le_alsa_midi_open,
    le_alsa_midi_close,
};

const le_midi_backend* le_midi_linux_backend(void) {
  return &kLeAlsaMidiBackend;
}

#else
typedef int loopy_midi_linux_tu_unused; /* keep the TU non-empty off Linux */
#endif
