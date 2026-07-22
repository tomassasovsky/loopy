/*
 * perf_render.c — see perf_render.h.
 *
 * CONTROL-THREAD OWNERSHIP for le_perf_render_begin/poll/track_status/cancel
 * (the only callers touching `engine->perf.render`). Everything between
 * begin and done/cancel runs on the dedicated render worker thread this file
 * spawns; the worker never touches the audio callback, the command ring, or
 * any live engine state — it reads exclusively from the capture directory on
 * disk (see perf_render.h), so a render has no live-engine dependency at all
 * beyond the `engine*` handle used to reach `engine->perf.render` from the
 * control-thread API calls.
 *
 * Dry pass (part 7): a per-track stem is reconstructed as unity-gain loop
 * content — volume/mute are NOT baked into the stem's samples. They remain
 * expressed only in the arm/disarm snapshots + events.log, for the `.als`
 * generator (parts 9-10) to turn into mixer/track-activator automation on
 * top of this stem, the same way a real DAW workflow bounces a dry stem once
 * and then automates its fader rather than destructively baking gain changes
 * into the audio.
 *
 * Wet pass + master reconstruction (part 8): mirrors what the live engine's
 * mix_tracks_frame/master_bus_frame (engine_process.c) actually computed —
 * lane-0 volume/mute gate the dry content *before* the logged FX chain (the
 * live mix order: `wl = audible ? loopsample*vol : 0`, then fx_apply_chain),
 * summed across channels, then the master gain + feed-forward limiter. This
 * uses the engine's OWN fx_apply_chain/le_fx_prepare/le_fx_entry_reset
 * (engine_fx.h) rather than reimplementing per-effect DSP — a fresh, heap-
 * owned `le_fx_state` per channel, never touching any live engine state, so
 * the no-live-engine-dependency guarantee above still holds. A hosted
 * LE_FX_PLUGIN slot's `fx->plugin[slot]` stays NULL on this fresh state, so
 * fx_apply_chain already renders it as dry passthrough with no special-
 * casing here (fx_plugin_process's own documented NULL behavior) — the
 * chain data recorded in the manifest (already carrying each plugin entry's
 * `type`/`plugin` fields, part 6) is what part 10's `.als` generator reads to
 * surface the passthrough.
 */
#include "perf_render.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"       /* fx_apply_chain, le_fx_prepare, le_fx_entry_reset,
                              * le_fx_free_octaver — reused verbatim for the wet
                              * pass, not reimplemented */
#include "engine_private.h" /* le_engine, le_perf_capture, LE_MAX_TRACKS */
#include "json_read.h"
#include "loopy_engine_api.h" /* le_command_code, le_command, LE_MAX_LANES */
#include "perf_log_ring.h"    /* le_perf_log_code */

#if defined(_WIN32)
#include <direct.h> /* _mkdir */
#include <windows.h>
#else
#include <pthread.h>
#include <sys/stat.h> /* mkdir */
#endif

/* ---- tuning ---- */
#define LE_PR_PATH_MAX 960
#define LE_PR_FULL_PATH_MAX (LE_PR_PATH_MAX + 64)
#define LE_PR_JSON_ARENA_NODES 8192 /* generous for a full performance.json —
                                    * see json_read.h; a manifest this large
                                    * would need > 1000 layer entries or
                                    * hundreds of lane/fx entries to exhaust
                                    * this */
#define LE_PR_EVENTS_ENTRY_BYTES 28 /* matches perf_drain.c's on-disk layout,
                                    * docs/design/performance-event-log-format.md */
#define LE_PR_MAX_SEGMENTS 4096 /* per-track content-source transitions; a
                                * scripted-storm session could retire many
                                * layers, but a single performance realistically
                                * never approaches this */

/* ---- portable thread shim (mirrors perf_drain.c's own; duplicated per
 * translation unit rather than shared, matching this codebase's existing
 * one-file-branch-by-platform convention for background threads). ---- */
#if defined(_WIN32)
typedef HANDLE le_pr_thread_t;
static void le_pr_worker_main(void* arg);
static DWORD WINAPI le_pr_win_trampoline(LPVOID arg) {
  le_pr_worker_main(arg);
  return 0;
}
static int le_pr_thread_start(le_pr_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_pr_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}
static void le_pr_thread_join(le_pr_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}
static int le_pr_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (_mkdir(path) == 0) return 1;
  return errno == EEXIST;
}
#else
typedef pthread_t le_pr_thread_t;
static void le_pr_worker_main(void* arg);
static void* le_pr_posix_trampoline(void* arg) {
  le_pr_worker_main(arg);
  return NULL;
}
static int le_pr_thread_start(le_pr_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_pr_posix_trampoline, arg) == 0;
}
static void le_pr_thread_join(le_pr_thread_t th) { pthread_join(th, NULL); }
static int le_pr_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (mkdir(path, 0755) == 0) return 1;
  return errno == EEXIST;
}
#endif

static int le_pr_mkdir_recursive(const char* path) {
  char buf[LE_PR_PATH_MAX];
  snprintf(buf, sizeof(buf), "%s", path);
  size_t len = strlen(buf);
  while (len > 0 && (buf[len - 1] == '/' || buf[len - 1] == '\\')) {
    buf[--len] = '\0';
  }
  for (size_t i = 1; i < len; ++i) {
    if (buf[i] == '/' || buf[i] == '\\') {
      const char sep = buf[i];
      buf[i] = '\0';
      if (!le_pr_mkdir_one(buf)) return 0;
      buf[i] = sep;
    }
  }
  return le_pr_mkdir_one(buf);
}

/* ---- render session ---- */

typedef struct le_pr_track_result {
  _Atomic int32_t channel;
  _Atomic int32_t succeeded;
} le_pr_track_result;

struct le_perf_render {
  le_engine* engine;
  le_pr_thread_t thread;

  _Atomic int running; /* cleared by le_perf_render_cancel to end the loop
                        * early, between tracks */
  _Atomic int done;
  _Atomic int progress_pct;
  _Atomic int track_count; /* number of valid entries in results[] so far */

  le_pr_track_result results[LE_MAX_TRACKS];

  char capture_dir[LE_PR_PATH_MAX];
};

/* ---- minimal fixed-format WAV reader (this project's own WavCodec output
 * only: a 44-byte header, format code 3 = IEEE float, fmt chunk size 16, no
 * extra chunks before `data` — see packages/wav_codec/lib/src/wav.dart. Not a
 * general WAV parser. ---- */
static float* le_pr_read_wav_mono(const char* path, int32_t* out_frames) {
  *out_frames = 0;
  FILE* f = fopen(path, "rb");
  if (f == NULL) return NULL;
  unsigned char header[44];
  if (fread(header, 1, sizeof(header), f) != sizeof(header) ||
      memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0 ||
      memcmp(header + 12, "fmt ", 4) != 0 || memcmp(header + 36, "data", 4) != 0) {
    fclose(f);
    return NULL;
  }
  const uint16_t format = (uint16_t)(header[20] | (header[21] << 8));
  const uint16_t channels = (uint16_t)(header[22] | (header[23] << 8));
  const uint32_t data_bytes = (uint32_t)header[40] | ((uint32_t)header[41] << 8) |
                             ((uint32_t)header[42] << 16) |
                             ((uint32_t)header[43] << 24);
  if (format != 3 || channels == 0 || data_bytes == 0) {
    fclose(f);
    return NULL;
  }
  const int32_t total_samples = (int32_t)(data_bytes / sizeof(float));
  const int32_t frames = total_samples / channels;
  float* mono = (float*)malloc((size_t)frames * sizeof(float));
  if (mono == NULL) {
    fclose(f);
    return NULL;
  }
  /* This part renders lane-0 stems only (matching this codebase's existing
   * lane-0 export precedent elsewhere, e.g. session_repository); a mono
   * source reads straight through, a multi-channel one reads channel 0. */
  float* scratch = (float*)malloc((size_t)channels * sizeof(float));
  if (scratch == NULL) {
    free(mono);
    fclose(f);
    return NULL;
  }
  int ok = 1;
  for (int32_t i = 0; i < frames && ok; ++i) {
    if (fread(scratch, sizeof(float), (size_t)channels, f) !=
        (size_t)channels) {
      ok = 0;
      break;
    }
    mono[i] = scratch[0];
  }
  free(scratch);
  fclose(f);
  if (!ok) {
    free(mono);
    return NULL;
  }
  *out_frames = frames;
  return mono;
}

/* Reads a retired-layer raw PCM file (part 5: interleaved by lane, no
 * header) and returns lane 0's samples only, matching the lane-0-stem scope
 * above. */
static float* le_pr_read_layer_lane0(const char* path, int32_t frame_count,
                                     int32_t lane_count) {
  if (frame_count <= 0 || lane_count <= 0) return NULL;
  FILE* f = fopen(path, "rb");
  if (f == NULL) return NULL;
  float* interleaved =
      (float*)malloc((size_t)frame_count * (size_t)lane_count * sizeof(float));
  if (interleaved == NULL) {
    fclose(f);
    return NULL;
  }
  const size_t want = (size_t)frame_count * (size_t)lane_count;
  const size_t got = fread(interleaved, sizeof(float), want, f);
  fclose(f);
  if (got != want) {
    free(interleaved);
    return NULL;
  }
  float* mono = (float*)malloc((size_t)frame_count * sizeof(float));
  if (mono == NULL) {
    free(interleaved);
    return NULL;
  }
  for (int32_t i = 0; i < frame_count; ++i) {
    mono[i] = interleaved[(size_t)i * (size_t)lane_count];
  }
  free(interleaved);
  return mono;
}

/* Encodes `samples` as a 32-bit float mono WAV at `sample_rate`, mirroring
 * wav_codec's own format (this codebase's only WAV writer besides that Dart
 * package — duplicated here so the native renderer needs no Dart round-trip
 * to produce its stems). */
static int le_pr_write_wav_mono(const char* path, const float* samples,
                                int32_t frame_count, int32_t sample_rate) {
  FILE* f = fopen(path, "wb");
  if (f == NULL) return 0;
  const uint32_t data_bytes = (uint32_t)frame_count * (uint32_t)sizeof(float);
  unsigned char header[44] = {0};
  memcpy(header + 0, "RIFF", 4);
  const uint32_t riff_size = 36 + data_bytes;
  memcpy(header + 4, &riff_size, 4);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  const uint32_t fmt_size = 16;
  memcpy(header + 16, &fmt_size, 4);
  const uint16_t format_code = 3; /* IEEE float */
  memcpy(header + 20, &format_code, 2);
  const uint16_t channels = 1;
  memcpy(header + 22, &channels, 2);
  const uint32_t sr = (uint32_t)sample_rate;
  memcpy(header + 24, &sr, 4);
  const uint32_t byte_rate = sr * channels * (uint32_t)sizeof(float);
  memcpy(header + 28, &byte_rate, 4);
  const uint16_t block_align = (uint16_t)(channels * sizeof(float));
  memcpy(header + 32, &block_align, 2);
  const uint16_t bits_per_sample = 32;
  memcpy(header + 34, &bits_per_sample, 2);
  memcpy(header + 36, "data", 4);
  memcpy(header + 40, &data_bytes, 4);

  int ok = fwrite(header, 1, sizeof(header), f) == sizeof(header);
  if (ok && frame_count > 0) {
    ok = fwrite(samples, sizeof(float), (size_t)frame_count, f) ==
        (size_t)frame_count;
  }
  fclose(f);
  return ok;
}

/* ---- performance.json access ---- */

typedef struct le_pr_manifest {
  int32_t sample_rate;
  uint64_t capture_frames;
  uint64_t arm_clock_frame;           /* armSnapshot.clockFrame — the master
                                       * playhead position AT arm (
                                       * PerformanceArmSnapshot.clockFrame /
                                       * `snapshot.masterPositionFrames`), i.e.
                                       * the loop phase capture frame 0 lands
                                       * on; 0 when armSnapshot is absent or
                                       * the capture was armed from silence */
  int32_t arm_master_len;             /* armSnapshot.masterLenFrames — the
                                       * master loop length at arm; the base
                                       * modulus for arm_clock_frame when the
                                       * master was locked before this capture
                                       * ever started (no LOOP_LENGTH_LOCKED
                                       * inside the log); 0 when armed from
                                       * silence */
  const le_json_value* arm_tracks;    /* armSnapshot.tracks array, or NULL */
  const le_json_value* disarm_tracks; /* disarmSnapshot.tracks array, or NULL */
  const le_json_value* layers;        /* layers array, or NULL */
  /* Master-bus state at arm time (armSnapshot.masterGain/limiterOn/
   * limiterCeiling) — the wet pass's starting point before events.log's
   * LE_CMD_SET_MASTER_GAIN / LE_PLOG_SET_LIMITER entries are replayed
   * forward. Defaults match engine.c's own fresh-engine values (unity gain,
   * limiter off, 0.99 ceiling) when armSnapshot is absent. */
  float arm_master_gain;
  int32_t arm_limiter_on;
  float arm_limiter_ceiling;
} le_pr_manifest;

static int le_pr_load_manifest(const char* dir, char** out_text,
                               le_json_arena* arena, le_json_value** out_root,
                               le_pr_manifest* out) {
  char path[LE_PR_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size <= 0) {
    fclose(f);
    return 0;
  }
  char* text = (char*)malloc((size_t)size + 1);
  if (text == NULL) {
    fclose(f);
    return 0;
  }
  const size_t got = fread(text, 1, (size_t)size, f);
  fclose(f);
  text[got] = '\0';

  le_json_value* root = le_json_parse(text, arena);
  if (root == NULL) {
    free(text);
    return 0;
  }

  out->sample_rate = (int32_t)le_json_number(le_json_get(root, "sample_rate"), 0);
  out->capture_frames =
      (uint64_t)le_json_number(le_json_get(root, "capture_frames"), 0);
  const le_json_value* arm = le_json_get(root, "armSnapshot");
  out->arm_clock_frame = (uint64_t)le_json_number(
      arm != NULL ? le_json_get(arm, "clockFrame") : NULL, 0);
  out->arm_master_len = (int32_t)le_json_number(
      arm != NULL ? le_json_get(arm, "masterLenFrames") : NULL, 0);
  out->arm_tracks = arm != NULL ? le_json_get(arm, "tracks") : NULL;
  const le_json_value* disarm = le_json_get(root, "disarmSnapshot");
  out->disarm_tracks = disarm != NULL ? le_json_get(disarm, "tracks") : NULL;
  out->layers = le_json_get(root, "layers");
  out->arm_master_gain =
      (float)le_json_number(arm != NULL ? le_json_get(arm, "masterGain") : NULL,
                            1.0);
  out->arm_limiter_on = le_json_bool(
      arm != NULL ? le_json_get(arm, "limiterOn") : NULL, 0);
  out->arm_limiter_ceiling = (float)le_json_number(
      arm != NULL ? le_json_get(arm, "limiterCeiling") : NULL, 0.99);

  *out_text = text;
  *out_root = root;
  return 1;
}

/* Finds channel `channel`'s track entry within a `tracks` array (either
 * armSnapshot's or disarmSnapshot's), or NULL if the channel is absent. The
 * wet pass needs the track-level `volume`/`muted` fields this returns
 * directly, alongside the lane-0 lookup below (which shares this scan). */
static const le_json_value* le_pr_find_track(const le_json_value* tracks,
                                             int32_t channel) {
  if (tracks == NULL) return NULL;
  const int n = le_json_length(tracks);
  for (int i = 0; i < n; ++i) {
    const le_json_value* track = le_json_at(tracks, i);
    if ((int32_t)le_json_number(le_json_get(track, "channel"), -1) == channel) {
      return track;
    }
  }
  return NULL;
}

/* Finds channel `channel`'s lane-0 entry within a `tracks` array, or NULL if
 * the channel is absent or has no lane 0. */
static const le_json_value* le_pr_find_lane0(const le_json_value* tracks,
                                             int32_t channel) {
  const le_json_value* track = le_pr_find_track(tracks, channel);
  if (track == NULL) return NULL;
  const le_json_value* lanes = le_json_get(track, "lanes");
  const int lane_n = le_json_length(lanes);
  for (int l = 0; l < lane_n; ++l) {
    const le_json_value* lane = le_json_at(lanes, l);
    if ((int32_t)le_json_number(le_json_get(lane, "lane"), -1) == 0) {
      return lane;
    }
  }
  return NULL;
}

/* Every distinct channel that appears in either snapshot's tracks array —
 * the set of tracks this render considers non-empty and worth a stem. */
static int le_pr_collect_channels(const le_pr_manifest* m, int32_t* out,
                                  int cap) {
  int n = 0;
  for (int pass = 0; pass < 2; ++pass) {
    const le_json_value* tracks = pass == 0 ? m->arm_tracks : m->disarm_tracks;
    const int count = le_json_length(tracks);
    for (int i = 0; i < count && n < cap; ++i) {
      const le_json_value* track = le_json_at(tracks, i);
      const int32_t channel =
          (int32_t)le_json_number(le_json_get(track, "channel"), -1);
      if (channel < 0) continue;
      int seen = 0;
      for (int k = 0; k < n; ++k) {
        if (out[k] == channel) {
          seen = 1;
          break;
        }
      }
      if (!seen) out[n++] = channel;
    }
  }
  return n;
}

/* ---- events.log access ---- */

typedef struct le_pr_log_entry {
  uint64_t frame;
  le_command cmd;
} le_pr_log_entry;

static int le_pr_frame_cmp(const void* a, const void* b) {
  const le_pr_log_entry* ea = (const le_pr_log_entry*)a;
  const le_pr_log_entry* eb = (const le_pr_log_entry*)b;
  if (ea->frame < eb->frame) return -1;
  if (ea->frame > eb->frame) return 1;
  return 0; /* qsort is not required to be stable; same-frame ties are rare
            * and this render doesn't depend on their relative order */
}

/* Loads and frame-sorts every entry in events.log. Returns the entry count
 * (0 if the file is missing/empty/unreadable — a render with no log is
 * still valid, it just has no stitching transitions beyond the snapshots
 * themselves) and sets *out_entries (caller frees). */
static int le_pr_load_log(const char* dir, le_pr_log_entry** out_entries) {
  *out_entries = NULL;
  char path[LE_PR_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;

  unsigned char header[12];
  if (fread(header, 1, sizeof(header), f) != sizeof(header) ||
      memcmp(header, "PLEV", 4) != 0) {
    fclose(f);
    return 0;
  }

  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, sizeof(header), SEEK_SET);
  if (size < (long)sizeof(header)) {
    fclose(f);
    return 0;
  }
  const long body_bytes = size - (long)sizeof(header);
  const int max_entries = (int)(body_bytes / LE_PR_EVENTS_ENTRY_BYTES);
  if (max_entries <= 0) {
    fclose(f);
    return 0;
  }

  le_pr_log_entry* entries =
      (le_pr_log_entry*)malloc((size_t)max_entries * sizeof(le_pr_log_entry));
  if (entries == NULL) {
    fclose(f);
    return 0;
  }

  int n = 0;
  unsigned char raw[LE_PR_EVENTS_ENTRY_BYTES];
  while (n < max_entries &&
        fread(raw, 1, LE_PR_EVENTS_ENTRY_BYTES, f) == LE_PR_EVENTS_ENTRY_BYTES) {
    le_pr_log_entry* e = &entries[n++];
    memcpy(&e->frame, raw, 8);
    memcpy(&e->cmd.code, raw + 8, 4);
    /* The 16-byte union payload, copied as a block rather than per-arm: every
     * arm is plain 4-byte-aligned int32_t/float/uint32_t fields with no
     * internal padding (see docs/design/performance-event-log-format.md), so
     * this is equivalent to memcpy-ing whichever specific arm the entry's
     * `code` actually uses. */
    memcpy(((unsigned char*)&e->cmd) + 4, raw + 12, 16);
  }
  fclose(f);

  qsort(entries, (size_t)n, sizeof(le_pr_log_entry), le_pr_frame_cmp);
  *out_entries = entries;
  return n;
}

/* ---- per-track segment reconstruction ---- */

typedef struct le_pr_segment {
  uint64_t start_frame;
  uint64_t phase0;   /* loop position (image index) the segment plays from at
                      * start_frame — stems are PHASE-LOCKED to what the
                      * performer heard (#255): a layer image is loop-position-
                      * indexed (buffer index == loop position), and the loop's
                      * phase runs as a continuous counter between the LOGGED
                      * transport facts that reset it (LOOP_LENGTH_LOCKED at a
                      * master finalize), so a segment activating at loop phase
                      * p must keep playing from image[p], not restart at
                      * image[0]. RESIDUAL LIMITATION: a mid-capture transport
                      * hold (nothing playing or recording) pins the live
                      * clock's position to 0 with NOTHING logged
                      * (engine_process.c's all-idle branch), so a phase reset
                      * via all-tracks-idle cannot be reconstructed from this
                      * capture — sibling of the multi-loop sub-cycle
                      * ambiguity noted on PR #260 */
  float* image;      /* owned; NULL = silence */
  int32_t image_len; /* loop period in frames; meaningless if image is NULL */
} le_pr_segment;

typedef struct le_pr_track_build {
  le_pr_segment segments[LE_PR_MAX_SEGMENTS];
  int segment_count;
  int has_content; /* 0 until the first non-silence segment is appended —
                    * gates the "first-ever recording" / disarm-snapshot
                    * lookup so a later RECORD_END on an already-content-
                    * bearing track doesn't re-trigger it (see perf_render.h's
                    * doc: clear-then-re-record within one session is a
                    * documented, deliberately out-of-scope simplification
                    * for this part) */
  int load_failed; /* 1 if a pcmRef/layer file this track's manifest entries
                    * NAME could not actually be read — the per-stem failure
                    * the "partial success" acceptance criterion means. A
                    * genuinely contentless channel (nothing in either
                    * snapshot at all) is NOT a failure — le_pr_collect_
                    * channels never even calls this function for one. */
} le_pr_track_build;

static void le_pr_append_segment(le_pr_track_build* b, uint64_t start_frame,
                                 uint64_t phase0, float* image,
                                 int32_t image_len) {
  if (b->segment_count >= LE_PR_MAX_SEGMENTS) {
    free(image); /* dropped: better a short render than an overflow */
    return;
  }
  /* A later transition can only ever move forward in time; if two events
   * land on the exact same frame, the later one (processed later, since the
   * log is frame-sorted) simply supersedes the earlier by starting at the
   * same instant — le_pr_render_track's lookup (last segment with
   * start_frame <= f) already resolves that correctly without special-casing
   * it here. */
  le_pr_segment* seg = &b->segments[b->segment_count++];
  seg->start_frame = start_frame;
  seg->phase0 = image_len > 0 ? phase0 % (uint64_t)image_len : 0;
  seg->image = image;
  seg->image_len = image_len;
  if (image != NULL) b->has_content = 1;
}

/* The loop phase (image index) the CURRENT last segment would play at
 * `frame` — the loop-position counter a new segment activating at `frame`
 * must inherit to stay phase-locked with live playback (#255). A build whose
 * last segment is silence (baseline, or post-CLEAR) has no phase to carry:
 * the next content supplies its own anchor (the arm image's clockFrame, or a
 * RECORD_END's track epoch — le_pr_record_end_phase below). */
static uint64_t le_pr_build_phase_at(const le_pr_track_build* b,
                                     uint64_t frame) {
  if (b->segment_count == 0) return 0;
  const le_pr_segment* seg = &b->segments[b->segment_count - 1];
  if (seg->image == NULL || seg->image_len <= 0) return 0;
  return (seg->phase0 + (frame - seg->start_frame)) % (uint64_t)seg->image_len;
}

/* The latest LE_PLOG_LOOP_LENGTH_LOCKED at or before `frame` (INCLUSIVE, so
 * a same-frame tie with the finalize that pushed the lock resolves correctly
 * regardless of how qsort ordered it). The lock is pushed at the exact frame
 * the master loop length is (re)established AND the loop clock's position
 * resets to 0 (finalize_master -> le_loop_clock_set_length,
 * engine_process.c); its arg_i carries the locked base length. */
static int le_pr_find_lock(const le_pr_log_entry* log, int log_count,
                           uint64_t frame, uint64_t* out_frame,
                           int32_t* out_base) {
  int found = 0;
  for (int i = 0; i < log_count && log[i].frame <= frame; ++i) {
    if (log[i].cmd.code == LE_PLOG_LOOP_LENGTH_LOCKED) {
      *out_frame = log[i].frame;
      *out_base = log[i].cmd.arg_i;
      found = 1;
    }
  }
  return found;
}

/* This channel's latest LE_PLOG_RECORD_START at or before `end_frame` — the
 * frame its finalized take actually began capturing (engine_process.c logs
 * it at the exact press/trigger frame). Falls back to `end_frame` itself
 * when none is logged (a defensive degenerate: zero-length take epoch). */
static uint64_t le_pr_find_record_start(const le_pr_log_entry* log,
                                        int log_count, int32_t channel,
                                        uint64_t end_frame) {
  uint64_t start = end_frame;
  for (int i = 0; i < log_count && log[i].frame <= end_frame; ++i) {
    if (log[i].cmd.code == LE_PLOG_RECORD_START &&
        log[i].cmd.arg_i == channel) {
      start = log[i].frame;
    }
  }
  return start;
}

/* The loop phase a RECORD_END segment (channel's fresh take finalized at
 * `end_frame`, image length `image_len` frames) starts playing from — the
 * TRACK's epoch, anchored at its own RECORD_START (#255 re-review):
 *
 *   phase0 = (master_pos_at(start_frame) + (end_frame - start_frame))
 *            % image_len
 *
 * A fresh take's buffer is written phase-locked from the master position at
 * the RECORD_START frame (`record_pos` seeds to `clock.position`,
 * engine_process.c) and the write head then runs CONTINUOUSLY to the
 * finalize; live playback likewise indexes ((loop_iteration - start_iter) %
 * k) * base + position with start_iter fixed at the record start. For a
 * multi-loop take (k > 1, image_len == k * base) the track's epoch and the
 * master lock's epoch agree modulo base but diverge in the sub-cycle
 * whenever start_iter % k != 0 — so the master position at the START is
 * computed modulo the locked BASE length (the lock's own arg_i, never
 * image_len), and only the start->end run is reduced modulo image_len.
 *
 * The exception is a take the master lock landed INSIDE of (lock_frame >=
 * start_frame): that take (re)defined the master, and the lock IS the clock
 * reset — finalize_master logs it at the same frame as the RECORD_END
 * (phase 0), and a crossfade-deferred finalize (finalize_master_xfade)
 * resets the clock at the lock frame too, F captured seam frames after the
 * press — so the anchor there is the lock, never the record start. A
 * hand-off lock landing exactly ON this take's RECORD_START yields the same
 * answer either way (the position was 0 right there).
 *
 * With no lock inside the capture at all, the master was locked before arm
 * and armSnapshot.clockFrame/masterLenFrames anchor capture frame 0 instead
 * (see the arm-image comment in le_pr_render_track for that anchor's own
 * staleness caveat, #262). */
static uint64_t le_pr_record_end_phase(const le_pr_manifest* m,
                                       const le_pr_log_entry* log,
                                       int log_count, int32_t channel,
                                       uint64_t end_frame, int32_t image_len) {
  if (image_len <= 0) return 0;
  const uint64_t start_frame =
      le_pr_find_record_start(log, log_count, channel, end_frame);
  uint64_t lock_frame = 0;
  int32_t lock_base = 0;
  const int has_lock =
      le_pr_find_lock(log, log_count, end_frame, &lock_frame, &lock_base);
  if (has_lock && lock_frame >= start_frame) {
    return (end_frame - lock_frame) % (uint64_t)image_len;
  }
  uint64_t start_pos = 0;
  if (has_lock && lock_base > 0) {
    start_pos = (start_frame - lock_frame) % (uint64_t)lock_base;
  } else if (!has_lock && m->arm_master_len > 0) {
    start_pos =
        (m->arm_clock_frame + start_frame) % (uint64_t)m->arm_master_len;
  }
  return (start_pos + (end_frame - start_frame)) % (uint64_t)image_len;
}

/* Renders channel `channel`'s full-length dry stem into a freshly malloc'd
 * buffer of `capture_frames` samples (caller frees), or NULL with
 * `*out_failed` set if a pcmRef/layer file this channel's manifest entries
 * actually name could not be read (the per-stem "partial success" failure
 * this part's acceptance criteria describe) or the stem buffer itself could
 * not be allocated. A channel with no manifest presence at all is never
 * passed here — `le_pr_collect_channels` only returns channels that appear
 * in at least one snapshot. */
static float* le_pr_render_track(const char* dir, const le_pr_manifest* m,
                                 const le_pr_log_entry* log, int log_count,
                                 int32_t channel, int32_t* out_failed) {
  *out_failed = 0;
  le_pr_track_build build = {0};
  /* A baseline silence segment at frame 0 always exists first — even a
   * track absent from armSnapshot entirely (recorded fresh later, or
   * mid-overdub/deferred at arm) needs SOMETHING covering [0, first real
   * transition), or the render loop below would find zero segments whose
   * start_frame <= an early frame and underflow the unsigned frame math.
   * A real arm-time image, when present, simply appends its own segment
   * right after this one at the same frame 0 (superseding it immediately —
   * see le_pr_append_segment's "later transition supersedes" note). */
  le_pr_append_segment(&build, 0, 0, NULL, 0);

  /* An arm-image segment anchors at `armSnapshot.clockFrame` (the master
   * playhead near the arm instant), indexing `(clockFrame + f) % image_len`
   * for a track already playing when the capture armed — fixed alongside the
   * mid-cycle layer-retire rotation (#255; both were the same "segment
   * restarts its image at index 0" root cause). KNOWN RESIDUAL (#262): this
   * anchor is the best the capture records, but it is race-stale —
   * clockFrame is sampled by the control thread BEFORE lane capture and
   * manifest I/O, while capture frame 0 only begins when LE_CMD_PERF_ARM
   * reaches the audio thread, an unbounded I/O gap later — so a mid-loop
   * arm's stems can still be offset by that arm latency. The exact fix
   * needs an engine-side transport fact logged when PERF_ARM actually
   * applies; render-side, this is as good as the data gets. */
  const le_json_value* arm_lane = le_pr_find_lane0(m->arm_tracks, channel);
  if (arm_lane != NULL &&
      le_json_bool(le_json_get(arm_lane, "deferred"), 0) == 0) {
    const le_json_value* pcm_ref_value = le_json_get(arm_lane, "pcmRef");
    char pcm_ref[128];
    if (pcm_ref_value != NULL) {
      if (le_json_string(pcm_ref_value, pcm_ref, sizeof(pcm_ref))) {
        char path[LE_PR_FULL_PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", dir, pcm_ref);
        int32_t frames = 0;
        float* image = le_pr_read_wav_mono(path, &frames);
        if (image != NULL) {
          le_pr_append_segment(&build, 0, m->arm_clock_frame, image, frames);
        } else {
          build.load_failed = 1;
        }
      } else {
        /* A `pcmRef` key exists but couldn't be extracted (e.g. a value
         * longer than this buffer, or a non-string) — a real data-integrity
         * problem, not "no content here": surface it as a per-stem failure
         * rather than silently treating it as absent. */
        build.load_failed = 1;
      }
    }
  }

  for (int i = 0; i < log_count; ++i) {
    const le_pr_log_entry* e = &log[i];
    if (e->cmd.code == LE_PLOG_RECORD_END && e->cmd.arg_i == channel &&
        !build.has_content) {
      const le_json_value* disarm_lane =
          le_pr_find_lane0(m->disarm_tracks, channel);
      if (disarm_lane != NULL) {
        const le_json_value* pcm_ref_value =
            le_json_get(disarm_lane, "pcmRef");
        char pcm_ref[128];
        if (pcm_ref_value != NULL) {
          if (le_json_string(pcm_ref_value, pcm_ref, sizeof(pcm_ref))) {
            char path[LE_PR_FULL_PATH_MAX];
            snprintf(path, sizeof(path), "%s/%s", dir, pcm_ref);
            int32_t frames = 0;
            float* image = le_pr_read_wav_mono(path, &frames);
            if (image != NULL) {
              /* The segment anchors at the TRACK's epoch — the master
               * position at its logged RECORD_START plus the continuous
               * run to this finalize — NOT always 0, and NOT the master
               * lock's epoch mod the image length. Only the DEFINING
               * track's finalize (finalize_master, engine_process.c)
               * resets the loop clock; a track recorded fresh while the
               * master already runs finalizes via finalize_new_track,
               * which never touches the clock, and its buffer was WRITTEN
               * phase-locked from the master position at the record-start
               * press — a multi-loop take (k > 1) additionally cycles
               * relative to its own start iteration, which the RECORD_START
               * anchor captures and a lock-epoch derivation would not.
               * le_pr_record_end_phase (above) holds the full derivation,
               * including the defining-take and pre-arm-lock cases. */
              le_pr_append_segment(
                  &build, e->frame,
                  le_pr_record_end_phase(m, log, log_count, channel, e->frame,
                                         frames),
                  image, frames);
            } else {
              build.load_failed = 1;
            }
          } else {
            build.load_failed = 1; /* present but unreadable, see above */
          }
        }
      }
    } else if (e->cmd.code == LE_PLOG_LAYER_RETIRED &&
              e->cmd.evt.channel == channel) {
      const int layer_n = le_json_length(m->layers);
      for (int li = 0; li < layer_n; ++li) {
        const le_json_value* layer = le_json_at(m->layers, li);
        const int32_t l_channel =
            (int32_t)le_json_number(le_json_get(layer, "channel"), -1);
        const int32_t l_slot =
            (int32_t)le_json_number(le_json_get(layer, "slot"), -1);
        const uint32_t l_gen =
            (uint32_t)le_json_number(le_json_get(layer, "generation"), 0);
        if (l_channel != channel || l_slot != e->cmd.evt.slot ||
            l_gen != e->cmd.evt.generation) {
          continue;
        }
        const int32_t frame_count =
            (int32_t)le_json_number(le_json_get(layer, "frame_count"), 0);
        const int32_t lane_count =
            (int32_t)le_json_number(le_json_get(layer, "lane_count"), 1);
        const le_json_value* filename_value = le_json_get(layer, "filename");
        char filename[64];
        if (filename_value == NULL) {
          break; /* no filename to even attempt: not this part's failure to
                  * report (a manifest entry with no filename is a part-5
                  * writer bug, not a stem-render concern) */
        }
        if (le_json_string(filename_value, filename, sizeof(filename))) {
          char path[LE_PR_FULL_PATH_MAX];
          snprintf(path, sizeof(path), "%s/%s", dir, filename);
          float* image = le_pr_read_layer_lane0(path, frame_count, lane_count);
          if (image != NULL) {
            /* The new image becomes active at the LOGGED retire frame
             * itself, not a derived "punch-in" frame one cycle earlier.
             * Deriving punch-in as `retire_frame - frame_count` is only
             * correct for a pass that retires exactly at its own loop-cycle
             * boundary (le_dub_boundary, engine_process.c) — a punch-out
             * mid-cycle instead retires via an asynchronous, chunked
             * live->shadow drain (le_dub_block_update) that can complete
             * many audio callbacks after the true punch-in, so the retire
             * frame has no fixed offset from it in that (very common) case.
             * By construction the retiring shadow is ALWAYS a complete,
             * correct loop image by the time it retires (the drain fills in
             * every position the live overdub didn't touch from the
             * previous image first) — so using the retire frame directly as
             * the switch point is exact where the data actually is
             * sample-accurate, at the cost of not modeling the sub-cycle
             * moment a live listener would have heard the transition
             * (which isn't logged anywhere and can't be reconstructed from
             * this capture).
             *
             * The segment inherits the loop phase the track had reached at
             * the retire frame (#255): a layer image is loop-position-
             * indexed, and live playback simply kept its position counter
             * running when the shadow swapped in — a retire at loop phase p
             * continued from image[p], so restarting the render at image[0]
             * would rotate the stem by p frames relative to what the
             * performer heard for every mid-cycle punch-out. Boundary
             * retires (p == 0) were already exact. */
            le_pr_append_segment(&build, e->frame,
                                 le_pr_build_phase_at(&build, e->frame), image,
                                 frame_count);
          } else {
            build.load_failed = 1;
          }
        } else {
          build.load_failed = 1; /* filename present but unreadable */
        }
        break;
      }
    } else if (e->cmd.code == LE_CMD_CLEAR && e->cmd.arg_i == channel) {
      le_pr_append_segment(&build, e->frame, 0, NULL, 0);
    }
  }

  if (build.load_failed) {
    *out_failed = 1;
    for (int i = 0; i < build.segment_count; ++i) free(build.segments[i].image);
    return NULL;
  }

  float* stem = (float*)calloc((size_t)m->capture_frames, sizeof(float));
  if (stem == NULL) {
    *out_failed = 1;
    for (int i = 0; i < build.segment_count; ++i) free(build.segments[i].image);
    return NULL;
  }

  int seg_index = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    while (seg_index + 1 < build.segment_count &&
          build.segments[seg_index + 1].start_frame <= f) {
      seg_index++;
    }
    const le_pr_segment* seg = &build.segments[seg_index];
    if (seg->image != NULL && seg->image_len > 0) {
      /* Phase-locked (#255): the segment's image plays from the loop
       * position it was actually at when the segment activated, not from
       * its own index 0 — stems reproduce exactly what the performer
       * heard. */
      const uint64_t pos =
          (seg->phase0 + (f - seg->start_frame)) % (uint64_t)seg->image_len;
      stem[f] = seg->image[pos];
    }
  }

  for (int i = 0; i < build.segment_count; ++i) free(build.segments[i].image);
  return stem;
}

/* ---- wet pass + master reconstruction (part 8) ---- */

/* Reinterprets `bits` as the `float` it was bit-cast from — the same
 * reinterpretation engine_private.h's `bits_to_f32` performs for every
 * atomic float field in this engine, applied here to a plain log payload
 * (LE_PLOG_SET_LANE_FX_PARAM/_MONITOR_FX_PARAM's `fx.type` field carries a
 * param value this way — see perf_log_ring.h). */
static float le_pr_bits_to_f32(uint32_t bits) {
  float f;
  memcpy(&f, &bits, sizeof(f));
  return f;
}

/* One channel's lane-0 effects chain, mirroring `le_lane`'s
 * a_fx_count/a_fx_type/a_fx_param fields closely enough to drive
 * fx_apply_chain directly. */
typedef struct le_pr_fx_chain {
  int32_t count;
  int32_t type[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
} le_pr_fx_chain;

static void le_pr_fx_chain_init_empty(le_pr_fx_chain* c) {
  c->count = 0;
  for (int i = 0; i < LE_FX_MAX; ++i) {
    c->type[i] = LE_FX_NONE;
    for (int p = 0; p < LE_FX_PARAMS; ++p) c->params[i][p] = 0.0f;
  }
}

/* Seeds a chain from a lane's `effects` array (the arm-snapshot's lane-0
 * entry, or NULL for a channel with no arm-time presence — starts empty,
 * exactly like a freshly recorded track's live chain before any FX command
 * has ever touched it). A malformed manifest entry with more than LE_FX_MAX
 * effects is truncated rather than overrunning the fixed arrays. */
static void le_pr_fx_chain_init_from_lane(le_pr_fx_chain* c,
                                          const le_json_value* lane) {
  le_pr_fx_chain_init_empty(c);
  if (lane == NULL) return;
  const le_json_value* effects = le_json_get(lane, "effects");
  const int n = le_json_length(effects);
  c->count = n > LE_FX_MAX ? LE_FX_MAX : n;
  for (int i = 0; i < c->count; ++i) {
    const le_json_value* entry = le_json_at(effects, i);
    c->type[i] =
        (int32_t)le_json_number(le_json_get(entry, "type"), LE_FX_NONE);
    const le_json_value* params = le_json_get(entry, "params");
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      c->params[i][p] = (float)le_json_number(le_json_at(params, p), 0.0);
    }
  }
}

/* Frees a heap-allocated le_fx_state's owned buffers (delay rings + octaver
 * phase-vocoder heap), mirroring engine.c's own per-slot teardown at engine
 * destroy — this render's `fx` is never seen by the live engine, so it owns
 * this teardown itself rather than routing through any live-engine path. */
static void le_pr_fx_state_free(le_fx_state* fx) {
  for (int s = 0; s < LE_FX_MAX; ++s) {
    free(fx->delay[s][0]);
    fx->delay[s][0] = NULL;
    free(fx->delay[s][1]);
    fx->delay[s][1] = NULL;
    le_fx_free_octaver(fx, s);
  }
}

/* Renders channel `channel`'s wet stem into a freshly malloc'd buffer of
 * `capture_frames` samples (caller frees), or NULL with `*out_failed` set on
 * allocation failure. `dry` is that channel's already-reconstructed dry
 * content (le_pr_render_track's output — same content, not recomputed) at
 * unity gain; this replays the SAME per-frame mix order the live engine's
 * mix_tracks_frame uses: lane-0 volume gates the sample (zeroed while
 * muted), THEN the logged FX chain processes it (continuously, every frame,
 * so delay/reverb tails and LFO phase stay continuous exactly as they do
 * live — only whether the result is later summed into the master differs
 * live, and this render has no separate "audible" gate beyond content
 * presence, see the doc note below). A mono source is fed into both L/R
 * (fx_apply_chain always runs stereo per-channel state); since both start
 * and stay equal by construction (symmetric per-channel state, identical
 * input), only L is kept.
 *
 * Scope note: this reconstructs lane-0 volume/mute and the lane-0 FX chain
 * from events.log (LE_CMD_SET_LANE_FX/_FX_COUNT, LE_PLOG_SET_LANE_FX_PARAM,
 * LE_CMD_SET_LANE_VOLUME/_MUTE, and their track-addressed LE_CMD_SET_VOLUME/
 * _MUTE equivalents, which map to lane 0 — engine_process.c). It does NOT
 * reconstruct the full RECORDING/PLAYING/STOPPED transport state machine: a
 * manual stop-then-resume of an already-recorded track mid-performance is
 * out of scope here (matching this part's fixed golden-parity protocol,
 * which already excludes monitor inputs, plugin slots, and pre-arm FX tails
 * BY CONSTRUCTION rather than widening tolerance) — content presence (from
 * `dry`) is this render's only audibility gate beyond mute. */
static float* le_pr_render_wet_track(const le_pr_manifest* m,
                                     const le_pr_log_entry* log, int log_count,
                                     int32_t channel, const float* dry,
                                     int32_t* out_failed) {
  *out_failed = 0;
  const le_json_value* arm_track = le_pr_find_track(m->arm_tracks, channel);
  const le_json_value* arm_lane = le_pr_find_lane0(m->arm_tracks, channel);

  le_pr_fx_chain chain;
  le_pr_fx_chain_init_from_lane(&chain, arm_lane);
  float volume = (float)le_json_number(
      arm_track != NULL ? le_json_get(arm_track, "volume") : NULL, 1.0);
  int muted = le_json_bool(
      arm_track != NULL ? le_json_get(arm_track, "muted") : NULL, 0);

  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) {
    *out_failed = 1;
    return NULL;
  }
  /* A prepare failure (OOM on a delay ring / octaver's phase-vocoder heap)
   * is NOT let through as a silent dry-passthrough degradation: fx_delay/
   * fx_octaver already handle a NULL buffer gracefully at the DSP level
   * (matching the live engine's own OOM posture), but this render treats it
   * as a genuine per-stem failure — the same "partial success, not silent
   * drift" posture load_failed already gives pcmRef/layer read failures
   * below — rather than quietly rendering a track's FX chain as if a slot
   * were bypassed. */
  int prepare_failed = 0;
  for (int s = 0; s < chain.count; ++s) {
    if (chain.type[s] != LE_FX_NONE &&
        le_fx_prepare(fx, s, chain.type[s], m->sample_rate) != LE_OK) {
      prepare_failed = 1;
    }
  }

  float* wet = (float*)calloc((size_t)m->capture_frames, sizeof(float));
  if (wet == NULL) {
    le_pr_fx_state_free(fx);
    free(fx);
    *out_failed = 1;
    return NULL;
  }

  int log_index = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    /* Apply every logged mutation for this channel's lane 0 at or before
     * this frame, in log order (already frame-sorted by le_pr_load_log),
     * before rendering it — mirrors mix_tracks_frame's per-frame (not
     * per-block) re-read of lane volume/mute/FX state. */
    while (log_index < log_count && log[log_index].frame <= f) {
      const le_command* cmd = &log[log_index].cmd;
      switch (cmd->code) {
        case LE_CMD_SET_LANE_FX:
          if (cmd->fx.channel == channel && cmd->fx.lane == 0 &&
              cmd->fx.index >= 0 && cmd->fx.index < LE_FX_MAX) {
            /* Mirrors le_engine_set_lane_fx's control-side behavior
             * (engine_commands.c: le_fx_prepare_entry), not just the
             * audio-thread ring handler: a REAL type change silently reseeds
             * that slot's default params via a direct atomic write, with NO
             * corresponding events.log entry (defaults are seeded before the
             * LE_CMD_SET_LANE_FX ring command is even posted, and only the
             * type change itself is logged) — replaying just the type swap
             * without also reseeding defaults here would leave this render
             * holding stale params the live engine never actually used past
             * this instant. Guarded on an ACTUAL change, matching
             * le_fx_prepare_entry's own `!= type` check (a reorder back to
             * the same type must not wipe a listener's tweaks). */
            if (chain.type[cmd->fx.index] != cmd->fx.type) {
              le_fx_defaults(cmd->fx.type, chain.params[cmd->fx.index]);
            }
            chain.type[cmd->fx.index] = cmd->fx.type;
            le_fx_entry_reset(fx, cmd->fx.index);
            if (cmd->fx.type != LE_FX_NONE &&
                le_fx_prepare(fx, cmd->fx.index, cmd->fx.type,
                             m->sample_rate) != LE_OK) {
              prepare_failed = 1;
            }
          }
          break;
        case LE_CMD_SET_LANE_FX_COUNT:
          if (cmd->fxcount.channel == channel && cmd->fxcount.lane == 0) {
            int32_t count = cmd->fxcount.count;
            if (count < 0) count = 0;
            if (count > LE_FX_MAX) count = LE_FX_MAX;
            chain.count = count;
          }
          break;
        case LE_PLOG_SET_LANE_FX_PARAM:
          if (cmd->fx.channel == channel && cmd->fx.lane == 0) {
            const int32_t index = LE_PLOG_FX_PARAM_INDEX(cmd->fx.index);
            const int32_t param = LE_PLOG_FX_PARAM_PARAM(cmd->fx.index);
            if (index >= 0 && index < LE_FX_MAX && param >= 0 &&
                param < LE_FX_PARAMS) {
              chain.params[index][param] =
                  le_pr_bits_to_f32((uint32_t)cmd->fx.type);
            }
          }
          break;
        case LE_CMD_SET_LANE_VOLUME:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0) {
            volume = cmd->lanef.value;
          }
          break;
        case LE_CMD_SET_VOLUME:
          if (cmd->arg_i == channel) volume = cmd->arg_f;
          break;
        case LE_CMD_SET_LANE_MUTE:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0) {
            muted = cmd->lanef.value != 0.0f;
          }
          break;
        case LE_CMD_SET_MUTE:
          if (cmd->arg_i == channel) muted = cmd->arg_f != 0.0f;
          break;
        default:
          break;
      }
      log_index++;
    }

    const float in = muted ? 0.0f : dry[f] * volume;
    float l = in;
    float r = in;
    fx_apply_chain(fx, m->sample_rate, m->sample_rate, &l, &r, chain.count,
                   chain.type, chain.params);
    wet[f] = l;
  }

  le_pr_fx_state_free(fx);
  free(fx);
  if (prepare_failed) {
    *out_failed = 1;
    free(wet);
    return NULL;
  }
  return wet;
}

/* Replays the master gain + feed-forward limiter over `master` (in place,
 * `capture_frames` samples — already the sum of every channel's wet
 * contribution), mirroring master_bus_frame's mono-channel math exactly
 * (engine_process.c): instant-attack / smooth-release limiter, ~50 ms
 * release toward unity. Uses its own local `lim_gain`, seeded at 1.0 (the
 * golden-parity protocol arms from silence, so the live engine's own
 * lim_gain is 1.0 at that instant too — see engine.c's fresh-state init) —
 * never the live engine's `e->lim_gain`, which the audio thread may still be
 * mutating concurrently after disarm (this render has no live-engine
 * dependency, see the file header). */
static void le_pr_render_master(const le_pr_manifest* m,
                                const le_pr_log_entry* log, int log_count,
                                float* master) {
  float gain = m->arm_master_gain;
  int limiter_on = m->arm_limiter_on;
  float ceiling = m->arm_limiter_ceiling;
  float lim_gain = 1.0f;
  const int sr = m->sample_rate > 0 ? m->sample_rate : 48000;
  float lim_release = 1.0f / (0.05f * (float)sr);
  if (lim_release > 1.0f) lim_release = 1.0f;

  int log_index = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    while (log_index < log_count && log[log_index].frame <= f) {
      const le_command* cmd = &log[log_index].cmd;
      if (cmd->code == LE_CMD_SET_MASTER_GAIN) {
        gain = cmd->arg_f;
      } else if (cmd->code == LE_PLOG_SET_LIMITER) {
        limiter_on = cmd->arg_i != 0;
        ceiling = cmd->arg_f;
      }
      log_index++;
    }

    float s = master[f] * gain;
    if (limiter_on) {
      const float peak = fabsf(s);
      float target = 1.0f;
      if (peak > ceiling && peak > 0.0f) target = ceiling / peak;
      if (target < lim_gain) {
        lim_gain = target;
      } else {
        lim_gain += (target - lim_gain) * lim_release;
      }
      if (lim_gain != 1.0f) s *= lim_gain;
    }
    master[f] = s;
  }
}

/* ---- worker thread ---- */

/* Test-only global: forces the dry-stem write for one specific channel below
 * to fail, deterministically simulating a transient I/O error on that one
 * write without touching the filesystem or affecting the wet-stem write, or
 * any other channel's dry write in the same render (engine_internal.h). -1
 * disables it. Relaxed: a lone value a test flips before/after driving a
 * render, not raced against anything else. */
static _Atomic int32_t g_pr_force_dry_write_failure_channel = -1;

void le_perf_render_force_dry_write_failure_for_test(int32_t channel) {
  atomic_store_explicit(&g_pr_force_dry_write_failure_channel, channel,
                        memory_order_relaxed);
}

static void le_pr_worker_main(void* arg) {
  le_perf_render* r = (le_perf_render*)arg;

  char* text = NULL;
  le_json_value* root = NULL;
  le_json_value* arena_nodes =
      (le_json_value*)malloc((size_t)LE_PR_JSON_ARENA_NODES * sizeof(le_json_value));
  le_json_arena arena = {.nodes = arena_nodes,
                        .capacity = LE_PR_JSON_ARENA_NODES,
                        .used = 0};
  le_pr_manifest manifest = {0};
  int loaded = arena_nodes != NULL &&
              le_pr_load_manifest(r->capture_dir, &text, &arena, &root, &manifest);

  le_pr_log_entry* log = NULL;
  int log_count = loaded ? le_pr_load_log(r->capture_dir, &log) : 0;

  int32_t channels[LE_MAX_TRACKS];
  const int channel_count =
      loaded ? le_pr_collect_channels(&manifest, channels, LE_MAX_TRACKS) : 0;

  /* Master accumulator: the sum of every channel's wet contribution, before
   * the master gain + limiter pass runs over it once, after every channel
   * has been processed (le_pr_render_master, below) — mirrors
   * mix_tracks_frame's additive per-lane sum feeding master_bus_frame. NULL
   * (rather than a zero-length calloc) when there is nothing to render, so
   * the write-out step below can use its presence as the gate. */
  float* master_accum =
      (loaded && channel_count > 0)
          ? (float*)calloc((size_t)manifest.capture_frames, sizeof(float))
          : NULL;

  if (loaded && channel_count > 0) {
    char dry_dir[LE_PR_FULL_PATH_MAX];
    snprintf(dry_dir, sizeof(dry_dir), "%s/stems/dry", r->capture_dir);
    le_pr_mkdir_recursive(dry_dir);
    char wet_dir[LE_PR_FULL_PATH_MAX];
    snprintf(wet_dir, sizeof(wet_dir), "%s/stems/wet", r->capture_dir);
    le_pr_mkdir_recursive(wet_dir);

    for (int i = 0; i < channel_count; ++i) {
      if (!atomic_load_explicit(&r->running, memory_order_acquire)) break;

      const int32_t channel = channels[i];
      int32_t load_failed = 0;
      float* stem = le_pr_render_track(r->capture_dir, &manifest, log, log_count,
                                       channel, &load_failed);
      int ok = 0;
      if (stem != NULL) {
        char dry_path[LE_PR_FULL_PATH_MAX];
        snprintf(dry_path, sizeof(dry_path), "%s/track%d.wav", dry_dir, channel);
        if (atomic_load_explicit(&g_pr_force_dry_write_failure_channel,
                                 memory_order_relaxed) == channel) {
          ok = 0; /* test-only: simulate a dry-write I/O failure on this one
                   * channel without touching the filesystem
                   * (le_perf_render_force_dry_write_failure_for_test,
                   * above). */
        } else {
          ok = le_pr_write_wav_mono(dry_path, stem,
                                    (int32_t)manifest.capture_frames,
                                    manifest.sample_rate);
        }

        int32_t wet_failed = 0;
        float* wet = le_pr_render_wet_track(&manifest, log, log_count, channel,
                                            stem, &wet_failed);
        if (wet != NULL) {
          char wet_path[LE_PR_FULL_PATH_MAX];
          snprintf(wet_path, sizeof(wet_path), "%s/track%d.wav", wet_dir, channel);
          const int wet_ok = le_pr_write_wav_mono(
              wet_path, wet, (int32_t)manifest.capture_frames,
              manifest.sample_rate);
          ok = ok && wet_ok;
          /* Either write failing (dry OR wet) leaves this channel out of the
           * master sum below with no separate flag on master.wav itself —
           * the signal is `ok` above, surfaced via this channel's own
           * `le_perf_render_track_status.succeeded == 0`, the same partial-
           * success contract every other per-stem failure in this file
           * already uses; a consumer checking every track's status before
           * trusting master.wav as complete already has everything it needs.
           * Gating on `ok` (not `wet_ok` alone) matters because a dry-write
           * failure must exclude this channel's wet content from master.wav
           * too, even though the wet write itself succeeded — otherwise
           * master.wav would contain audio for a channel the render already
           * reports as failed. */
          if (ok && master_accum != NULL) {
            for (uint64_t f = 0; f < manifest.capture_frames; ++f) {
              master_accum[f] += wet[f];
            }
          }
          free(wet);
        } else {
          ok = 0;
        }
        free(stem);
      }

      const int index = atomic_load_explicit(&r->track_count, memory_order_relaxed);
      atomic_store_explicit(&r->results[index].channel, channel,
                            memory_order_relaxed);
      atomic_store_explicit(&r->results[index].succeeded, ok ? 1 : 0,
                            memory_order_release);
      atomic_store_explicit(&r->track_count, index + 1, memory_order_release);
      atomic_store_explicit(&r->progress_pct, (int)(((i + 1) * 100) / channel_count),
                            memory_order_relaxed);
    }

    if (master_accum != NULL &&
        atomic_load_explicit(&r->running, memory_order_acquire)) {
      le_pr_render_master(&manifest, log, log_count, master_accum);
      char master_path[LE_PR_FULL_PATH_MAX];
      snprintf(master_path, sizeof(master_path), "%s/master.wav", wet_dir);
      le_pr_write_wav_mono(master_path, master_accum,
                           (int32_t)manifest.capture_frames,
                           manifest.sample_rate);
    }
  }

  free(master_accum);
  free(log);
  free(text);
  free(arena_nodes);

  atomic_store_explicit(&r->progress_pct, 100, memory_order_relaxed);
  atomic_store_explicit(&r->done, 1, memory_order_release);
}

/* ---- public ABI ---- */

int32_t le_perf_render_begin(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return LE_ERR_INVALID;
  }
  if (engine->perf.render != NULL &&
      !atomic_load_explicit(&engine->perf.render->done, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  if (engine->perf.render != NULL) {
    /* A finished-but-unreaped session from a prior render: join and free it
     * before starting a new one (mirrors le_perf_drain's reaping). */
    le_pr_thread_join(engine->perf.render->thread);
    free(engine->perf.render);
    engine->perf.render = NULL;
  }

  le_perf_render* r = (le_perf_render*)calloc(1, sizeof(le_perf_render));
  if (r == NULL) return LE_ERR_DEVICE;
  r->engine = engine;
  snprintf(r->capture_dir, sizeof(r->capture_dir), "%s", capture_dir);
  atomic_store_explicit(&r->running, 1, memory_order_relaxed);
  atomic_store_explicit(&r->done, 0, memory_order_relaxed);
  atomic_store_explicit(&r->progress_pct, 0, memory_order_relaxed);
  atomic_store_explicit(&r->track_count, 0, memory_order_relaxed);

  if (!le_pr_thread_start(&r->thread, r)) {
    free(r);
    return LE_ERR_DEVICE;
  }

  engine->perf.render = r;
  return LE_OK;
}

int32_t le_perf_render_poll(le_engine* engine, int32_t* done,
                            int32_t* progress_pct, int32_t* track_count) {
  if (engine == NULL) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL) {
    if (done != NULL) *done = 1;
    if (progress_pct != NULL) *progress_pct = 100;
    if (track_count != NULL) *track_count = 0;
    return LE_OK;
  }
  if (done != NULL) {
    *done = atomic_load_explicit(&r->done, memory_order_acquire);
  }
  if (progress_pct != NULL) {
    *progress_pct = atomic_load_explicit(&r->progress_pct, memory_order_relaxed);
  }
  if (track_count != NULL) {
    *track_count = atomic_load_explicit(&r->track_count, memory_order_acquire);
  }
  return LE_OK;
}

int32_t le_perf_render_track_status(le_engine* engine, int32_t index,
                                    int32_t* channel, int32_t* succeeded) {
  if (engine == NULL || index < 0) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL || index >= atomic_load_explicit(&r->track_count,
                                                 memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  if (channel != NULL) {
    *channel = atomic_load_explicit(&r->results[index].channel,
                                    memory_order_relaxed);
  }
  if (succeeded != NULL) {
    *succeeded = atomic_load_explicit(&r->results[index].succeeded,
                                      memory_order_acquire);
  }
  return LE_OK;
}

int32_t le_perf_render_cancel(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL) return LE_OK;
  atomic_store_explicit(&r->running, 0, memory_order_release);
  le_pr_thread_join(r->thread);
  free(r);
  engine->perf.render = NULL;
  return LE_OK;
}
