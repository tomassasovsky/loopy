/*
 * perf_drain.c — see perf_drain.h.
 *
 * CONTROL-THREAD OWNERSHIP for le_perf_drain_start/stop (called only from
 * engine_commands.c's le_perf_arm/disarm and engine.c's reconfigure hook).
 * Everything between start and stop runs on the dedicated drain thread this
 * file spawns; it never touches the audio callback or pushes to the command
 * ring (that would be a second producer on control's SPSC ring).
 *
 * Sidecar writes are hand-rolled (no JSON library in this tree): the schema is
 * a flat handful of fields plus a small gap array, well within what snprintf
 * can build in one bounded pass. Every flush writes a fresh temp file and
 * atomically renames it over performance.json, so a reader never sees a
 * half-written sidecar.
 */
#include "perf_drain.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h"      /* le_audio_ring_pop */
#include "engine_private.h"  /* le_engine, le_perf_capture, LE_MAX_INPUTS */
#include "perf_log_ring.h"   /* le_perf_log_ring_pop (performance event log) */

#if defined(_WIN32)
#include <direct.h> /* _mkdir */
#include <windows.h>
#else
#include <pthread.h>
#include <sys/stat.h> /* mkdir */
#include <time.h>     /* nanosleep */
#endif

/* ---- tuning ---- */
#define LE_PD_FLUSH_MS 250   /* drain + sidecar flush cadence */
#define LE_PD_POLL_MS 10     /* stop-flag poll granularity (snappy shutdown) */
#define LE_PD_MAX_GAPS 128   /* recorded gap entries; beyond this, frames are
                              * still silence-filled, just not individually
                              * logged in the sidecar */
#define LE_PD_PATH_MAX 960   /* capture_dir length; +32 headroom for filenames */
#define LE_PD_FULL_PATH_MAX (LE_PD_PATH_MAX + 32)
#define LE_PD_JSON_BUF 32768 /* generous for LE_PD_MAX_GAPS entries + fields */
#define LE_PD_SCRATCH_SAMPLES 2048 /* per-drain-cycle pop buffer, in samples */

/* events.log wire format (docs/design/performance-event-log-format.md): a
 * 12-byte header (4-byte magic "PLEV", uint32 version, int32 sample_rate)
 * followed by fixed-size 28-byte entries (uint64 frame, int32 code, 16 bytes
 * of raw union payload — le_command's union has no internal padding of its
 * own, every arm being plain 4-byte-aligned int32_t/float/uint32_t fields).
 * The 28 bytes ARE dumped from memory (frame via one memcpy, code + union via
 * two more) — what le_pd_write_log_entry avoids is `sizeof(le_perf_log_entry)`
 * itself, which is 32 (not 28): the struct's 8-byte alignment (from its
 * uint64_t frame) pads 4 trailing bytes onto the end that a naive
 * `fwrite(&entry, sizeof(entry), 1, f)` would write as uninitialised garbage.
 * Writing exactly 28 explicit bytes sidesteps that trailing pad; it is not a
 * claim that every byte is otherwise reinterpreted independent of this
 * process's compiler — this is a private, same-process wire format (both
 * sides compiled together), not a cross-language ABI. Part 9's .als
 * generator is meant to parse the resulting bytes without importing engine
 * code, using the per-code arm layout documented in the format doc. */
#define LE_PD_EVENTS_ENTRY_BYTES 28 /* 8 (frame) + 4 (code) + 16 (union payload) */

/* ---- portable thread + sleep shim (extends engine_plugin.c's
 * control_sleep_ms one-file-branch-by-platform style to a real joinable
 * thread; see engine_plugin.c for the sibling sleep-only version). ---- */
#if defined(_WIN32)
typedef HANDLE le_pd_thread_t;

static void le_pd_drain_thread_main(void* arg);

static DWORD WINAPI le_pd_win_trampoline(LPVOID arg) {
  le_pd_drain_thread_main(arg);
  return 0;
}

static int le_pd_thread_start(le_pd_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_pd_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}

static void le_pd_thread_join(le_pd_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}

static void le_pd_sleep_ms(int ms) { Sleep((DWORD)ms); }

static int le_pd_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (_mkdir(path) == 0) return 1;
  return errno == EEXIST;
}
#else
typedef pthread_t le_pd_thread_t;

static void le_pd_drain_thread_main(void* arg);

static void* le_pd_posix_trampoline(void* arg) {
  le_pd_drain_thread_main(arg);
  return NULL;
}

static int le_pd_thread_start(le_pd_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_pd_posix_trampoline, arg) == 0;
}

static void le_pd_thread_join(le_pd_thread_t th) { pthread_join(th, NULL); }

static void le_pd_sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

static int le_pd_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (mkdir(path, 0755) == 0) return 1;
  return errno == EEXIST;
}
#endif

/* mkdir -p: creates every missing path segment. Splits on '/' or '\\' so a
 * caller can pass either style; each segment is created in order so a nested
 * capture dir works with no pre-existing parent. Known limitation: a bare
 * Windows drive letter ("C:") as the first segment is not special-cased —
 * not exercised by this codebase's paths (always under a resolved documents
 * dir), so left as a follow-up rather than solved speculatively here. */
static int le_pd_mkdir_recursive(const char* path) {
  char buf[LE_PD_PATH_MAX];
  snprintf(buf, sizeof(buf), "%s", path);
  size_t len = strlen(buf);
  while (len > 0 && (buf[len - 1] == '/' || buf[len - 1] == '\\')) {
    buf[--len] = '\0';
  }
  for (size_t i = 1; i < len; ++i) {
    if (buf[i] == '/' || buf[i] == '\\') {
      const char sep = buf[i];
      buf[i] = '\0';
      if (!le_pd_mkdir_one(buf)) return 0;
      buf[i] = sep;
    }
  }
  return le_pd_mkdir_one(buf);
}

/* Test-only global: forces every subsequent write attempt to fail, simulating
 * a full disk without needing a real one (engine_internal.h). Relaxed: a lone
 * on/off switch a test flips before/after driving a drain thread, not raced
 * against anything else. */
static _Atomic int g_pd_force_write_failure = 0;

void le_perf_drain_force_write_failure_for_test(int enabled) {
  atomic_store_explicit(&g_pd_force_write_failure, enabled ? 1 : 0,
                        memory_order_relaxed);
}

typedef struct le_pd_gap {
  uint64_t frame;
  uint64_t duration_frames;
} le_pd_gap;

typedef struct le_pd_file {
  FILE* f;
  uint64_t written; /* frames written so far, in THIS file's own channel width */
} le_pd_file;

struct le_perf_drain {
  le_engine* engine;
  le_pd_thread_t thread;

  _Atomic int running;       /* cleared by le_perf_drain_stop to end the loop */
  _Atomic int disk_full;     /* 1 once a write failure self-stopped the thread */
  _Atomic int device_changed; /* 1 once le_perf_drain_stop(..., DEVICE_CHANGED) */

  char capture_dir[LE_PD_PATH_MAX];

  le_pd_file master_file;
  le_pd_file monitor_file[LE_MAX_INPUTS]; /* valid iff input_mask bit set */

  /* Performance event log (part 3): append-only, header written once at
   * start; every subsequent drain cycle appends whatever both perf-log rings
   * have accumulated since the last cycle. Never reopened/truncated mid-
   * session, unlike the sidecar. */
  FILE* events_file;

  le_pd_gap gaps[LE_PD_MAX_GAPS];
  int gap_count;
};

int le_perf_drain_self_stopped_for_test(struct le_perf_drain* drain) {
  if (drain == NULL) return 0;
  return atomic_load_explicit(&drain->disk_full, memory_order_acquire);
}

/* Low-level bounded write; checks the force-failure test hook so every PCM/
 * silence-fill write path fails uniformly (le_pd_flush and
 * le_pd_write_sidecar each check it too, at their own I/O boundary). */
static int le_pd_write(FILE* f, const void* data, size_t bytes) {
  if (atomic_load_explicit(&g_pd_force_write_failure, memory_order_relaxed)) {
    return 0;
  }
  if (bytes == 0) return 1;
  return fwrite(data, 1, bytes, f) == bytes;
}

/* Flushes a long-lived PCM file handle so its writes actually reach the OS
 * (and become visible to any other reader) rather than sitting in this
 * stream's userspace buffer until an eventual fclose — the file is kept open
 * for the whole capture session, unlike the sidecar's per-cycle fopen/fclose.
 * This IS the ~250 ms flush cadence perf_drain.h documents. Not itself
 * subject to the force-write-failure test hook (le_pd_write already covers
 * the PCM data path; by the time flush would run, either the write already
 * failed and this is unreached, or there is genuinely nothing forced to
 * fail). */
static int le_pd_flush(FILE* f) { return fflush(f) == 0; }

/* Writes events.log's 12-byte header once, right after the file is created:
 * magic "PLEV", a uint32 version (bump if the entry layout ever changes), and
 * the session's sample rate (so a reader can convert frame -> seconds without
 * cross-referencing the sidecar). */
static int le_pd_write_events_header(FILE* f, int32_t sample_rate) {
  static const char magic[4] = {'P', 'L', 'E', 'V'};
  const uint32_t version = 1;
  if (!le_pd_write(f, magic, sizeof(magic))) return 0;
  if (!le_pd_write(f, &version, sizeof(version))) return 0;
  if (!le_pd_write(f, &sample_rate, sizeof(sample_rate))) return 0;
  return 1;
}

/* Serializes one log entry into the fixed 28-byte on-disk record: frame,
 * code, then the union's raw 16 bytes taken directly from memory (every
 * le_command union arm is laid out as plain int32_t/float/uint32_t fields
 * with no arm exceeding 16 bytes, so this is a faithful, code-agnostic copy —
 * the reader interprets those 16 bytes per the audited table's per-code arm
 * documentation, the same way apply_command does in-process). */
static int le_pd_write_log_entry(FILE* f, const le_perf_log_entry* entry) {
  unsigned char buf[LE_PD_EVENTS_ENTRY_BYTES];
  memcpy(buf, &entry->frame, sizeof(entry->frame));
  memcpy(buf + sizeof(entry->frame), &entry->cmd.code,
        sizeof(entry->cmd.code));
  memcpy(buf + sizeof(entry->frame) + sizeof(entry->cmd.code),
        ((const char*)&entry->cmd) + sizeof(entry->cmd.code),
        LE_PD_EVENTS_ENTRY_BYTES - sizeof(entry->frame) -
            sizeof(entry->cmd.code));
  return le_pd_write(f, buf, sizeof(buf));
}

/* Drains everything currently available from a perf-log ring (either
 * log_ring or log_ctrl_ring) into events.log, one entry at a time — these
 * rings carry one event per pop, unlike the bulk-sample le_audio_ring above. */
static int le_pd_drain_log_ring(FILE* f, le_perf_log_ring* ring) {
  le_perf_log_entry entry;
  while (le_perf_log_ring_pop(ring, &entry)) {
    if (!le_pd_write_log_entry(f, &entry)) return 0;
  }
  return 1;
}

/* Drains everything currently available from `ring` (a le_audio_ring of
 * `channels`-wide frames) into `pf`'s file, looping until the ring reports
 * less than a full scratch buffer (i.e. it is now empty). */
static int le_pd_drain_ring(le_pd_file* pf, le_audio_ring* ring, int channels,
                           float* scratch, size_t scratch_samples) {
  if (channels <= 0) return 1;
  const size_t max_frames = scratch_samples / (size_t)channels;
  for (;;) {
    const size_t popped =
        le_audio_ring_pop(ring, scratch, max_frames * (size_t)channels);
    if (popped == 0) return 1;
    if (!le_pd_write(pf->f, scratch, popped * sizeof(float))) return 0;
    const size_t popped_frames = popped / (size_t)channels;
    pf->written += popped_frames;
    if (popped_frames < max_frames) return 1;
  }
}

/* Tops `pf` up to `elapsed` frames with silence when the ring dropped frames
 * (an overrun) and it has fallen behind, so the file stays sample-consistent
 * with wall-clock time. Records a gap entry {frame, duration_frames} — the
 * position it started falling behind, and how many frames were padded. */
static int le_pd_catch_up(le_perf_drain* d, le_pd_file* pf, int channels,
                          uint64_t elapsed) {
  if (pf->written >= elapsed || channels <= 0) return 1;
  const uint64_t gap = elapsed - pf->written;

  if (d->gap_count < LE_PD_MAX_GAPS) {
    d->gaps[d->gap_count].frame = pf->written;
    d->gaps[d->gap_count].duration_frames = gap;
    d->gap_count++;
  }

  static const float kZeros[1024] = {0};
  uint64_t remaining = gap * (uint64_t)channels;
  while (remaining > 0) {
    const size_t chunk = remaining < 1024 ? (size_t)remaining : 1024;
    if (!le_pd_write(pf->f, kZeros, chunk * sizeof(float))) return 0;
    remaining -= chunk;
  }
  pf->written = elapsed;
  return 1;
}

static int le_pd_atomic_rename(const char* tmp, const char* final_path) {
#if defined(_WIN32)
  /* Windows' rename() refuses to replace an existing destination (unlike
   * POSIX) — a best-effort pre-remove closes that gap at the cost of a
   * brief window with neither file present there (acceptable: a reader
   * mid-window just sees the previous flush's absence, not corruption, and
   * the next cycle's temp file already has fresh content queued). */
  remove(final_path);
#endif
  /* POSIX rename() already atomically replaces an existing destination, so
   * skipping the remove() there means the final path is NEVER momentarily
   * absent — a reader can fopen() it at any instant and always see either
   * the previous flush or this one, never neither. */
  return rename(tmp, final_path) == 0;
}

static const char* le_pd_basename(const char* path) {
  const char* slash = strrchr(path, '/');
  const char* backslash = strrchr(path, '\\');
  if (backslash != NULL && (slash == NULL || backslash > slash)) slash = backslash;
  return slash != NULL ? slash + 1 : path;
}

/* Minimal JSON string escaping (quote + backslash only) — the sidecar's only
 * string field is the capture-dir basename, a machine-generated timestamp
 * slug with no expected special characters; this is defensive, not a general
 * JSON encoder. */
static void le_pd_json_escape(const char* in, char* out, size_t out_cap) {
  size_t o = 0;
  for (size_t i = 0; in[i] != '\0' && o + 2 < out_cap; ++i) {
    if (in[i] == '"' || in[i] == '\\') out[o++] = '\\';
    out[o++] = in[i];
  }
  out[o] = '\0';
}

/* Builds performance.json and atomically replaces it. Always
 * `"finalized": false` in this slice — flipping it to true happens at
 * finalize, a later part. `stopped_early` is omitted entirely on a normal,
 * still-running (or normally disarmed) capture; present only for the two
 * abnormal-stop reasons this part defines.
 *
 * NOT subject to the force-write-failure test hook (unlike le_pd_write/
 * le_pd_flush): a disk-full failure realistically hits the large,
 * continuously-growing PCM files long before it hits this tiny, occasional
 * JSON write, and — more importantly — is the ONLY place `stopped_early`
 * ever reaches disk, so it must still be able to succeed after a PCM write
 * has already failed this same cycle.
 *
 * `report_disk_full` is an explicit parameter, not a read of d->disk_full:
 * the caller (le_pd_drain_cycle) only sets that externally-observable atomic
 * AFTER this call returns, so a test polling it can never see "disk_full"
 * before the marker it implies has actually finished its remove()+rename()
 * on disk. */
static int le_pd_write_sidecar(le_perf_drain* d, int report_disk_full) {
  char slug_esc[128];
  le_pd_json_escape(le_pd_basename(d->capture_dir), slug_esc, sizeof(slug_esc));

  const uint64_t elapsed = atomic_load_explicit(&d->engine->a_perf_frames,
                                                memory_order_relaxed);
  const uint32_t overruns = atomic_load_explicit(&d->engine->a_perf_overruns,
                                                 memory_order_relaxed);

  char buf[LE_PD_JSON_BUF];
  int off = snprintf(buf, sizeof(buf),
                     "{\n"
                     "  \"slug\": \"%s\",\n"
                     "  \"sample_rate\": %d,\n"
                     "  \"channel_layout\": {\"master_channels\": %d, "
                     "\"captured_inputs\": [",
                     slug_esc, d->engine->sample_rate,
                     d->engine->perf.master_channels);
  if (off < 0) return 0;

  int first = 1;
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (!(d->engine->perf.input_mask & (1u << c))) continue;
    off += snprintf(buf + off, sizeof(buf) - (size_t)off, "%s%d",
                    first ? "" : ", ", c);
    first = 0;
  }

  off += snprintf(buf + off, sizeof(buf) - (size_t)off,
                 "]},\n"
                 "  \"capture_frames\": %llu,\n"
                 "  \"overrun_count\": %u,\n"
                 "  \"overrun_gaps\": [",
                 (unsigned long long)elapsed, overruns);

  for (int i = 0; i < d->gap_count; ++i) {
    off += snprintf(buf + off, sizeof(buf) - (size_t)off,
                   "%s{\"frame\": %llu, \"duration_frames\": %llu}",
                   i == 0 ? "" : ", ", (unsigned long long)d->gaps[i].frame,
                   (unsigned long long)d->gaps[i].duration_frames);
  }
  off += snprintf(buf + off, sizeof(buf) - (size_t)off, "],\n");

  if (report_disk_full) {
    off += snprintf(buf + off, sizeof(buf) - (size_t)off,
                   "  \"stopped_early\": \"disk_full\",\n");
  } else if (atomic_load_explicit(&d->device_changed, memory_order_acquire)) {
    off += snprintf(buf + off, sizeof(buf) - (size_t)off,
                   "  \"stopped_early\": \"device_changed\",\n");
  }

  off += snprintf(buf + off, sizeof(buf) - (size_t)off,
                 "  \"finalized\": false\n}\n");
  if (off < 0 || (size_t)off >= sizeof(buf)) return 0; /* truncated */

  char tmp_path[LE_PD_FULL_PATH_MAX];
  char final_path[LE_PD_FULL_PATH_MAX];
  snprintf(tmp_path, sizeof(tmp_path), "%s/performance.json.tmp",
          d->capture_dir);
  snprintf(final_path, sizeof(final_path), "%s/performance.json",
          d->capture_dir);

  FILE* f = fopen(tmp_path, "wb");
  if (f == NULL) return 0;
  const size_t len = (size_t)off;
  const int ok = fwrite(buf, 1, len, f) == len;
  fclose(f);
  if (!ok) return 0;

  return le_pd_atomic_rename(tmp_path, final_path);
}

/* One drain-and-flush pass: pop everything available from every captured
 * ring, silence-fill any file that has fallen behind wall-clock elapsed
 * frames, flush the PCM files, then rewrite the sidecar. The sidecar write is
 * ALWAYS attempted, even after a PCM failure earlier in the same pass — it is
 * the only place `stopped_early` ever reaches disk, so it must still run
 * while there is something to report. Returns 0 if the PCM path failed (the
 * caller stops the thread — a partial pass is not retried mid-cycle) or the
 * sidecar write itself failed. */
static int le_pd_drain_cycle(le_perf_drain* d) {
  le_engine* e = d->engine;
  float scratch[LE_PD_SCRATCH_SAMPLES];
  int ok = 1;

  if (!le_pd_drain_ring(&d->master_file, &e->perf.master_ring,
                       e->perf.master_channels, scratch,
                       LE_PD_SCRATCH_SAMPLES)) {
    ok = 0;
  }
  for (int32_t c = 0; ok && c < LE_MAX_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (!le_pd_drain_ring(&d->monitor_file[c], &e->perf.monitor_ring[c], 2,
                         scratch, LE_PD_SCRATCH_SAMPLES)) {
      ok = 0;
    }
  }

  if (ok) {
    const uint64_t elapsed =
        atomic_load_explicit(&e->a_perf_frames, memory_order_relaxed);
    if (!le_pd_catch_up(d, &d->master_file, e->perf.master_channels, elapsed)) {
      ok = 0;
    }
    for (int32_t c = 0; ok && c < LE_MAX_INPUTS; ++c) {
      if (!(e->perf.input_mask & (1u << c))) continue;
      if (!le_pd_catch_up(d, &d->monitor_file[c], 2, elapsed)) ok = 0;
    }
  }

  /* Performance event log (part 3): drain both perf-log rings — the audio-
   * thread-producer log_ring first, then the control-thread-producer
   * log_ctrl_ring — and append every entry to events.log. Order between the
   * two streams is a file-write-order interleaving, not a global frame sort
   * (see docs/design/performance-event-log-format.md): each stream is
   * monotonic in frame on its own, but a control-side param change and an
   * audio-thread command from the same drain interval can land in either
   * order in the file. */
  if (ok && !le_pd_drain_log_ring(d->events_file, &e->perf.log_ring)) ok = 0;
  if (ok && !le_pd_drain_log_ring(d->events_file, &e->perf.log_ctrl_ring)) {
    ok = 0;
  }

  /* The PCM files stay open for the whole capture session (never closed
   * until disarm), so without an explicit flush here their buffered writes
   * would sit invisible to any other reader (a crash-consistency check, or
   * this very drain cycle's sidecar reporting a capture_frames count nothing
   * has actually reached disk for yet) until fclose. This is THE flush the
   * ~250 ms cadence documented in perf_drain.h refers to. */
  if (ok && !le_pd_flush(d->master_file.f)) ok = 0;
  for (int32_t c = 0; ok && c < LE_MAX_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (!le_pd_flush(d->monitor_file[c].f)) ok = 0;
  }
  if (ok && !le_pd_flush(d->events_file)) ok = 0;

  /* Write the sidecar (with the disk_full marker, if this cycle just failed)
   * BEFORE publishing d->disk_full — le_perf_drain_self_stopped_for_test
   * lets a caller observe that flag while the thread is still alive (unlike
   * device_changed, only ever checked after a full join), so the store must
   * happen strictly after the marker it implies is already durably on disk,
   * never before. */
  const int sidecar_ok = le_pd_write_sidecar(d, !ok);
  if (!ok) atomic_store_explicit(&d->disk_full, 1, memory_order_release);
  return ok && sidecar_ok;
}

static void le_pd_drain_thread_main(void* arg) {
  le_perf_drain* d = (le_perf_drain*)arg;
  int since_flush_ms = 0;

  while (atomic_load_explicit(&d->running, memory_order_acquire)) {
    le_pd_sleep_ms(LE_PD_POLL_MS);
    since_flush_ms += LE_PD_POLL_MS;
    if (since_flush_ms < LE_PD_FLUSH_MS) continue;
    since_flush_ms = 0;
    if (!le_pd_drain_cycle(d)) {
      atomic_store_explicit(&d->disk_full, 1, memory_order_release);
      break;
    }
  }

  /* Final pass regardless of how we got here (a graceful stop request, or a
   * disk-full self-stop above): best-effort drain + one last sidecar flush,
   * so the on-disk state reflects everything captured up to this moment.
   * Its own failure is not actionable — the thread is exiting either way. */
  le_pd_drain_cycle(d);
}

le_perf_drain* le_perf_drain_start(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return NULL;
  }
  if (strlen(capture_dir) >= sizeof(((le_perf_drain*)0)->capture_dir)) {
    return NULL; /* reject rather than silently truncate into a wrong path */
  }
  if (!le_pd_mkdir_recursive(capture_dir)) return NULL;

  le_perf_drain* d = (le_perf_drain*)calloc(1, sizeof(le_perf_drain));
  if (d == NULL) return NULL;
  d->engine = engine;
  snprintf(d->capture_dir, sizeof(d->capture_dir), "%s", capture_dir);

  char path[LE_PD_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/master.pcm", d->capture_dir);
  d->master_file.f = fopen(path, "wb");
  if (d->master_file.f == NULL) {
    free(d);
    return NULL;
  }

  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (!(engine->perf.input_mask & (1u << c))) continue;
    snprintf(path, sizeof(path), "%s/input-%d.pcm", d->capture_dir, c);
    d->monitor_file[c].f = fopen(path, "wb");
    if (d->monitor_file[c].f == NULL) {
      fclose(d->master_file.f);
      for (int32_t k = 0; k < c; ++k) {
        if (d->monitor_file[k].f != NULL) fclose(d->monitor_file[k].f);
      }
      free(d);
      return NULL;
    }
  }

  snprintf(path, sizeof(path), "%s/events.log", d->capture_dir);
  d->events_file = fopen(path, "wb");
  if (d->events_file == NULL ||
      !le_pd_write_events_header(d->events_file, engine->sample_rate)) {
    if (d->events_file != NULL) fclose(d->events_file);
    fclose(d->master_file.f);
    for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
      if (d->monitor_file[c].f != NULL) fclose(d->monitor_file[c].f);
    }
    free(d);
    return NULL;
  }

  atomic_store_explicit(&d->running, 1, memory_order_release);
  if (!le_pd_thread_start(&d->thread, d)) {
    fclose(d->events_file);
    fclose(d->master_file.f);
    for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
      if (d->monitor_file[c].f != NULL) fclose(d->monitor_file[c].f);
    }
    free(d);
    return NULL;
  }
  return d;
}

void le_perf_drain_stop(le_perf_drain* drain, le_perf_stop_reason reason) {
  if (drain == NULL) return;
  if (!atomic_load_explicit(&drain->disk_full, memory_order_acquire) &&
      reason == LE_PERF_STOP_DEVICE_CHANGED) {
    atomic_store_explicit(&drain->device_changed, 1, memory_order_release);
  }
  atomic_store_explicit(&drain->running, 0, memory_order_release);
  le_pd_thread_join(drain->thread);

  if (drain->master_file.f != NULL) fclose(drain->master_file.f);
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (drain->monitor_file[c].f != NULL) fclose(drain->monitor_file[c].f);
  }
  if (drain->events_file != NULL) fclose(drain->events_file);
  free(drain);
}
