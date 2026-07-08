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
 * Dry-only (part 7): a per-track stem is reconstructed as unity-gain loop
 * content — volume/mute are NOT baked into the stem's samples. They remain
 * expressed only in the arm/disarm snapshots + events.log, for the `.als`
 * generator (parts 9-10) to turn into mixer/track-activator automation on
 * top of this stem, the same way a real DAW workflow bounces a dry stem once
 * and then automates its fader rather than destructively baking gain changes
 * into the audio. FX (the wet pass) is part 8.
 */
#include "perf_render.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  const le_json_value* arm_tracks;    /* armSnapshot.tracks array, or NULL */
  const le_json_value* disarm_tracks; /* disarmSnapshot.tracks array, or NULL */
  const le_json_value* layers;        /* layers array, or NULL */
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
  out->arm_tracks = arm != NULL ? le_json_get(arm, "tracks") : NULL;
  const le_json_value* disarm = le_json_get(root, "disarmSnapshot");
  out->disarm_tracks = disarm != NULL ? le_json_get(disarm, "tracks") : NULL;
  out->layers = le_json_get(root, "layers");

  *out_text = text;
  *out_root = root;
  return 1;
}

/* Finds channel `channel`'s lane-0 entry within a `tracks` array (either
 * armSnapshot's or disarmSnapshot's), or NULL if the channel is absent or
 * has no lane 0. */
static const le_json_value* le_pr_find_lane0(const le_json_value* tracks,
                                             int32_t channel) {
  if (tracks == NULL) return NULL;
  const int n = le_json_length(tracks);
  for (int i = 0; i < n; ++i) {
    const le_json_value* track = le_json_at(tracks, i);
    if ((int32_t)le_json_number(le_json_get(track, "channel"), -1) != channel) {
      continue;
    }
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
                                 float* image, int32_t image_len) {
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
  seg->image = image;
  seg->image_len = image_len;
  if (image != NULL) b->has_content = 1;
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
  le_pr_append_segment(&build, 0, NULL, 0);

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
          le_pr_append_segment(&build, 0, image, frames);
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
              le_pr_append_segment(&build, e->frame, image, frames);
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
             * this capture). */
            le_pr_append_segment(&build, e->frame, image, frame_count);
          } else {
            build.load_failed = 1;
          }
        } else {
          build.load_failed = 1; /* filename present but unreadable */
        }
        break;
      }
    } else if (e->cmd.code == LE_CMD_CLEAR && e->cmd.arg_i == channel) {
      le_pr_append_segment(&build, e->frame, NULL, 0);
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
      const uint64_t pos = (f - seg->start_frame) % (uint64_t)seg->image_len;
      stem[f] = seg->image[pos];
    }
  }

  for (int i = 0; i < build.segment_count; ++i) free(build.segments[i].image);
  return stem;
}

/* ---- worker thread ---- */

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

  if (loaded && channel_count > 0) {
    char stems_dir[LE_PR_FULL_PATH_MAX];
    snprintf(stems_dir, sizeof(stems_dir), "%s/stems/dry", r->capture_dir);
    le_pr_mkdir_recursive(stems_dir);

    for (int i = 0; i < channel_count; ++i) {
      if (!atomic_load_explicit(&r->running, memory_order_acquire)) break;

      const int32_t channel = channels[i];
      int32_t load_failed = 0;
      float* stem = le_pr_render_track(r->capture_dir, &manifest, log, log_count,
                                       channel, &load_failed);
      int ok = 0;
      if (stem != NULL) {
        char path[LE_PR_FULL_PATH_MAX];
        snprintf(path, sizeof(path), "%s/track%d.wav", stems_dir, channel);
        ok = le_pr_write_wav_mono(path, stem, (int32_t)manifest.capture_frames,
                                  manifest.sample_rate);
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
  }

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
