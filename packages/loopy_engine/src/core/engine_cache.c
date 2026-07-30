/*
 * engine_cache.c — the Loop-stage wet cache (FX v3 part 2).
 *
 * When a lane's record-route chain is STABLE, a single background worker [B6]
 * renders the lane's whole loop offline — dry PCM x pre-chain volume through
 * the engine's own fx_apply_chain, verbatim on a heap le_fx_state (the
 * perf_render pattern; no forked DSP) — and the audio thread plays the cached
 * stereo result at zero FX CPU. Any edit falls back to live processing within
 * one buffer. Design rule: when in doubt, play live. The cache is invisible,
 * never destructive, and never allowed to play stale audio.
 *
 * THREAD OWNERSHIP — the [R2] contract, clause by clause:
 *  (a) Dry-PCM handoff is COPY-AT-ENQUEUE: the CONTROL thread (le_cache_tick)
 *      copies pool[a_live] into a worker-owned buffer, only while the track is
 *      not RECORDING/OVERDUBBING and no overdub layer is in flight (the fade
 *      tail and drain both hold a_layer_in_flight), tagged with the
 *      a_audio_rev it copied under and re-checked after the copy (seqlock
 *      shape). A finished render whose revision moved is discarded. In-flight
 *      copies count against the memory cap. The control thread owns all pool
 *      management (alloc/shrink/a_live swaps), so a control-side copy can
 *      never race a pool free.
 *  (b) Wet-buffer publication mirrors the fx->plugin[] discipline
 *      (engine_plugin.c): entries are control-allocated, fully written, then
 *      published as ONE atomic pointer (le_lane.a_wet, release) whose key the
 *      audio thread re-derives and checks once per buffer. Publication and
 *      retraction are CONTROL-THREAD-ONLY (single writer); the worker never
 *      touches a_wet — it only fills its job slot, which the next tick
 *      collects, validates ([B5]: key must still match), and publishes.
 *  (c) Reclamation uses the engine_plugin.c clear-slot pattern's SAFETY RULE
 *      — retract the pointer, then observe two processed-buffer boundaries
 *      via a_frames before freeing — but observes them PASSIVELY: a retracted
 *      entry moves to a graveyard list and the tick frees it once a_frames
 *      has been seen to change twice since retraction (or immediately with no
 *      audio thread). No control-thread sleep, ever — the UI's snapshot poll
 *      must never stall on cache housekeeping. A stalled device callback just
 *      parks the graveyard (bounded); never a use-after-free.
 *  (d) Join-before-free: le_cache_shutdown joins the worker and is called
 *      from le_engine_stop, the top of le_engine_configure, and
 *      le_engine_destroy BEFORE any pool or wet-buffer free.
 *
 * The job queue is a fixed slot array with SPSC state machines (control:
 * EMPTY -> QUEUED and DONE/ABORTED/FAILED -> EMPTY; worker: QUEUED -> RUNNING
 * -> DONE/ABORTED/FAILED), so no mutex exists anywhere in the engine and the
 * audio thread is untouched. The worker polls (bounded 1 ms sleeps), renders
 * the loop TWICE back-to-back and keeps the second pass, so delay/reverb
 * tails that wrap the loop boundary are baked in; it aborts early when it
 * observes an a_audio_rev bump for its lane [B5] or shutdown.
 */
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_cache.h"
#include "engine_core.h"    /* le_lanes_active, le_engine_drain_events */
#include "engine_fx.h"      /* fx_apply_chain, le_fx_prepare, seed/bypass */
#include "engine_private.h" /* le_engine, le_wet_entry, load/store helpers */
#include "loopy_engine_api.h"

/* ---- portable thread shim (mirrors perf_render.c's own; duplicated per
 * translation unit rather than shared, matching this codebase's existing
 * one-file-branch-by-platform convention for background threads). ---- */
#if defined(_WIN32)
#include <windows.h>
typedef HANDLE le_ca_thread_t;
static void le_ca_worker_main(void* arg);
static DWORD WINAPI le_ca_win_trampoline(LPVOID arg) {
  le_ca_worker_main(arg);
  return 0;
}
static int le_ca_thread_start(le_ca_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_ca_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}
static void le_ca_thread_join(le_ca_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}
static void le_ca_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <pthread.h>
#include <time.h>
typedef pthread_t le_ca_thread_t;
static void le_ca_worker_main(void* arg);
static void* le_ca_posix_trampoline(void* arg) {
  le_ca_worker_main(arg);
  return NULL;
}
static int le_ca_thread_start(le_ca_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_ca_posix_trampoline, arg) == 0;
}
static void le_ca_thread_join(le_ca_thread_t th) { pthread_join(th, NULL); }
static void le_ca_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* ---- tuning ---- */
/* (LE_CACHE_SETTLE_MS — the settle debounce window — lives in engine_cache.h
 * so the native tests derive their pump counts from the one definition.) */

/* Job queue slots. Bounded small: one job per lane at most (job_pending), a
 * single worker consumes them, and a full queue just retries next tick —
 * deliberately below LE_MAX_TRACKS so the overflow path is reachable (and
 * tested) instead of dead code. */
#define LE_CACHE_JOB_SLOTS 4

/* Retained entries per lane: the toggled-pair retention [B2] — the current
 * key's entry plus its most recent sibling (e.g. an enabled-bit toggle's
 * other half), so an off/on stomp is cache-hot in both directions. The pair
 * counts twice against the cap. */
#define LE_CACHE_ENTRIES_PER_LANE 2

/* Worker abort-check cadence [B5]: revision/shutdown checked once per this
 * many rendered frames — cheap per block, never per sample. */
#define LE_CACHE_ABORT_CHECK_FRAMES 4096

/* Quiescent reclaim [R2](c): two processed-buffer boundaries (a_frames seen
 * to change twice) prove the audio thread no longer holds a retracted entry
 * pointer — the engine_plugin.c clear-slot number, observed passively here.
 * The graveyard is sized so it can hold EVERY possible entry at once (the
 * retained pairs of every lane plus install-replacement churn), so pushing
 * can never overflow by construction. */
#define LE_CACHE_QUIESCE_BOUNDARIES 2
#define LE_CACHE_GRAVEYARD \
  (LE_MAX_TRACKS * LE_MAX_LANES * LE_CACHE_ENTRIES_PER_LANE + LE_CACHE_JOB_SLOTS)

/* Consecutive render failures (allocation, prepare OOM) before a lane stops
 * retrying and reports gave-up; any key change re-arms it. */
#define LE_CACHE_FAIL_GIVE_UP 3

/* ---- state ---- */

/* SPSC job lifecycle. Control writes EMPTY->QUEUED and *->EMPTY; the worker
 * writes QUEUED->RUNNING->DONE/ABORTED/FAILED. All transitions release; all
 * cross-thread reads acquire. */
enum {
  LE_CACHE_JOB_EMPTY = 0,
  LE_CACHE_JOB_QUEUED = 1,
  LE_CACHE_JOB_RUNNING = 2,
  LE_CACHE_JOB_DONE = 3,
  LE_CACHE_JOB_ABORTED = 4,
  LE_CACHE_JOB_FAILED = 5,
};

/* One render job. `dry` is control-allocated at enqueue and control-freed at
 * collection (the worker only reads it); `wet` is worker-allocated and either
 * handed over on DONE (control takes ownership) or worker-freed on
 * ABORTED/FAILED. The chain snapshot is frozen at enqueue — the fingerprint
 * IS that snapshot's identity, so a chain that moved by publish time simply
 * fails the [B5] key check and the result is discarded. */
typedef struct le_cache_job {
  _Atomic int32_t a_state;
  int32_t channel;
  int32_t lane;
  uint32_t audio_rev;
  uint64_t chain_fp;
  uint32_t vol_bits;
  float vol;
  int32_t len;
  int32_t sample_rate;
  int32_t fx_cap;
  int32_t fx_count;
  int32_t fx_type[LE_FX_MAX];
  float fx_params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t fx_effective[LE_FX_MAX]; /* chain_on && slot enabled (D-EFFBITS) */
  float* dry;
  float* wet;
} le_cache_job;

/* Per-lane control-side bookkeeping (telemetry + debounce + retained pair). */
typedef struct le_lane_cache {
  le_wet_entry* entries[LE_CACHE_ENTRIES_PER_LANE];
  uint64_t last_key_hash;
  uint64_t key_stable_frames; /* a_frames when the key last changed */
  int has_key;
  int job_pending;
  int32_t state;  /* le_cache_state */
  int32_t reason; /* le_cache_reason */
  int32_t renders;
  int32_t fail_count;
} le_lane_cache;

/* One retracted entry awaiting its passive quiescent window [R2](c): freed
 * once a_frames has been observed to change LE_CACHE_QUIESCE_BOUNDARIES times
 * since retraction (each tick samples once), or immediately when no audio
 * thread runs. Its bytes left the cap accounting at retraction, so the real
 * allocation transiently exceeds `used_bytes` by the graveyard's total for a
 * couple of ticks — bounded and deliberate: the alternative is sleeping on
 * the UI-poll drain path. */
typedef struct le_cache_grave {
  le_wet_entry* ent; /* NULL = free slot */
  uint64_t stamp;    /* last sampled a_frames */
  int boundaries;    /* distinct changes observed since retraction */
} le_cache_grave;

struct le_fx_cache {
  le_engine* engine;
  le_lane_cache lanes[LE_MAX_TRACKS][LE_MAX_LANES];
  le_cache_job jobs[LE_CACHE_JOB_SLOTS];
  le_cache_grave graveyard[LE_CACHE_GRAVEYARD];
  int64_t used_bytes;
  uint64_t lru_clock;
  _Atomic int32_t a_shutdown;
  int worker_started;
  le_ca_thread_t worker;
};

/* ---- key / fingerprint helpers (control thread) ---- */

/* le_fx_chain_fingerprint's fold, over an already-snapshotted chain instead of
 * the live atomics (D-FPEMPTY order preserved: chain bit only when non-empty,
 * then per entry type + enabled bit + built-in params), built on the ONE
 * shared byte fold (le_fx_fp_u32, engine_core.h). Folding the SNAPSHOT makes
 * the job's fingerprint the identity of exactly what will render; the
 * scheduler cross-checks it against the canonical atomic read and skips the
 * tick on any mismatch (a concurrent audio-thread type/count publish), so the
 * two folds can never silently disagree about a scheduled render. */
static uint64_t le_ca_snapshot_fp(int32_t count, int32_t chain_on,
                                  const int32_t* types, const int32_t* enabled,
                                  const float params[LE_FX_MAX][LE_FX_PARAMS]) {
  uint64_t h = 0xcbf29ce484222325ULL;
  if (count > 0) h = le_fx_fp_u32(h, chain_on ? 1u : 0u);
  for (int32_t i = 0; i < count; ++i) {
    h = le_fx_fp_u32(h, (uint32_t)types[i]);
    h = le_fx_fp_u32(h, enabled[i] ? 1u : 0u);
    if (types[i] == LE_FX_PLUGIN) continue;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      h = le_fx_fp_u32(h, f32_to_bits(params[i][p]));
    }
  }
  return h;
}

/* Composite change-detection hash over the whole cache key (rev, fp, volume,
 * length). Only drives the settle debounce — entry MATCHING always compares
 * the full tuple, never this hash. */
static uint64_t le_ca_key_hash(uint32_t rev, uint64_t fp, uint32_t vol_bits,
                               int32_t len) {
  uint64_t h = fp;
  h = le_fx_fp_u32(h, rev);
  h = le_fx_fp_u32(h, vol_bits);
  h = le_fx_fp_u32(h, (uint32_t)len);
  return h;
}

/* ---- quiescent reclaim [R2](c) — passive, never sleeps ---- */

static int64_t le_ca_entry_bytes(const le_wet_entry* ent) {
  return 2ll * (int64_t)ent->len * (int64_t)sizeof(float); /* stereo [R5] */
}

/* Frees every graveyard entry whose passive quiescent window has closed: with
 * no audio thread everything is immediately reclaimable; otherwise an entry
 * frees once a_frames has been observed to change twice since retraction (one
 * sample per tick — the engine_plugin.c two-boundary rule without the sleep).
 * `force` (shutdown, where the callers guarantee the audio thread is gone)
 * frees unconditionally. */
static void le_cache_sweep_graveyard(le_engine* e, struct le_fx_cache* c,
                                     int force) {
  const int running = load_i32(&e->a_running);
  const uint64_t now =
      atomic_load_explicit(&e->a_frames, memory_order_acquire);
  for (int g = 0; g < LE_CACHE_GRAVEYARD; ++g) {
    le_cache_grave* gr = &c->graveyard[g];
    if (gr->ent == NULL) continue;
    if (!force && running) {
      if (now != gr->stamp) {
        gr->boundaries++;
        gr->stamp = now;
      }
      if (gr->boundaries < LE_CACHE_QUIESCE_BOUNDARIES) continue;
    }
    free(gr->ent->pcm);
    free(gr->ent);
    gr->ent = NULL;
  }
}

/* Retracts entry [i] of lane (t, l): un-publishes it from the audio thread,
 * removes its bytes from the cap accounting, and parks it in the graveyard
 * for the passive quiescent free above. Non-blocking by design [R2](c) —
 * this runs on the UI-poll drain path. The graveyard is sized to hold every
 * possible entry, so the push cannot fail. */
static void le_cache_drop_entry(le_engine* e, struct le_fx_cache* c, int t,
                                int l, int i) {
  le_wet_entry* ent = c->lanes[t][l].entries[i];
  if (ent == NULL) return;
  le_lane* ln = &e->tracks[t].lanes[l];
  if (atomic_load_explicit(&ln->a_wet, memory_order_relaxed) == ent) {
    atomic_store_explicit(&ln->a_wet, NULL, memory_order_release);
  }
  c->used_bytes -= le_ca_entry_bytes(ent);
  c->lanes[t][l].entries[i] = NULL;
  for (int g = 0; g < LE_CACHE_GRAVEYARD; ++g) {
    if (c->graveyard[g].ent == NULL) {
      c->graveyard[g].ent = ent;
      c->graveyard[g].stamp =
          atomic_load_explicit(&e->a_frames, memory_order_acquire);
      c->graveyard[g].boundaries = 0;
      return;
    }
  }
  /* Unreachable by sizing (see LE_CACHE_GRAVEYARD); never leak regardless. */
  free(ent->pcm);
  free(ent);
}

/* Retracts every entry (the cap-disabled path and shutdown's prelude). */
static void le_cache_free_all_entries(le_engine* e, struct le_fx_cache* c) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(e, c, t, l, i);
      }
    }
  }
}

/* LRU eviction until [needed] more bytes fit under [cap]. An evicted lane
 * simply plays live and may re-render later; eviction may take the entry the
 * audio thread is currently playing (via the retract + quiesce dance — the
 * audible result is the ordinary same-buffer live fallback). Returns 1 when
 * the budget fits. */
static int le_cache_ensure_budget(le_engine* e, struct le_fx_cache* c,
                                  int64_t cap, int64_t needed) {
  /* Feasibility first: only entries are evictable (in-flight job bytes are
   * not), so if evicting EVERYTHING still would not fit, fail without
   * destroying entries that could keep serving — an infeasible render must
   * not thrash the survivors away. */
  int64_t evictable = 0;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        if (c->lanes[t][l].entries[i] != NULL) {
          evictable += le_ca_entry_bytes(c->lanes[t][l].entries[i]);
        }
      }
    }
  }
  if (c->used_bytes - evictable + needed > cap) return 0;
  while (c->used_bytes + needed > cap) {
    int bt = -1, bl = -1, bi = -1;
    uint64_t best = 0;
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      for (int l = 0; l < LE_MAX_LANES; ++l) {
        for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
          le_wet_entry* ent = c->lanes[t][l].entries[i];
          if (ent == NULL) continue;
          if (bt < 0 || ent->last_used < best) {
            best = ent->last_used;
            bt = t;
            bl = l;
            bi = i;
          }
        }
      }
    }
    if (bt < 0) return 0; /* nothing left to evict; budget cannot fit */
    le_cache_drop_entry(e, c, bt, bl, bi);
  }
  return 1;
}

/* ---- publication (control thread, [B5] + [B2]) ---- */

/* Wraps a DONE job's wet buffer in a le_wet_entry and installs it in the
 * lane's retained pair: reuse a same-key slot, else a free slot, else replace
 * the pair's LRU member. The entry is fully written BEFORE the release
 * publish, so the audio thread can never see a partial entry [R2](b). */
static void le_cache_install(le_engine* e, struct le_fx_cache* c,
                             le_cache_job* job) {
  le_lane_cache* lc = &c->lanes[job->channel][job->lane];
  le_lane* ln = &e->tracks[job->channel].lanes[job->lane];

  int slot = -1;
  for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
    le_wet_entry* ent = lc->entries[i];
    if (ent != NULL && ent->audio_rev == job->audio_rev &&
        ent->chain_fp == job->chain_fp && ent->vol_bits == job->vol_bits &&
        ent->len == job->len) {
      slot = i; /* same key rendered twice (races resolve here): replace */
      break;
    }
  }
  if (slot < 0) {
    for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
      if (lc->entries[i] == NULL) {
        slot = i;
        break;
      }
    }
  }
  if (slot < 0) {
    slot = 0; /* replace the pair's LRU member [B2] */
    for (int i = 1; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
      if (lc->entries[i]->last_used < lc->entries[slot]->last_used) slot = i;
    }
  }
  le_cache_drop_entry(e, c, job->channel, job->lane, slot);

  le_wet_entry* ent = (le_wet_entry*)calloc(1, sizeof(le_wet_entry));
  if (ent == NULL) {
    free(job->wet);
    job->wet = NULL;
    return;
  }
  ent->audio_rev = job->audio_rev;
  ent->chain_fp = job->chain_fp;
  ent->vol_bits = job->vol_bits;
  ent->len = job->len;
  ent->pcm = job->wet;
  ent->last_used = c->lru_clock;
  job->wet = NULL; /* ownership moved */
  lc->entries[slot] = ent;
  c->used_bytes += le_ca_entry_bytes(ent);
  atomic_store_explicit(&ln->a_wet, ent, memory_order_release);
}

/* Collects finished jobs: frees the enqueue copy, publishes a DONE render iff
 * its key STILL matches the lane's current key [B5], and returns the slot to
 * EMPTY. Failure/abort bookkeeping feeds the telemetry states. */
static void le_cache_collect(le_engine* e, struct le_fx_cache* c,
                             int64_t cap) {
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    le_cache_job* job = &c->jobs[j];
    const int32_t st =
        atomic_load_explicit(&job->a_state, memory_order_acquire);
    if (st != LE_CACHE_JOB_DONE && st != LE_CACHE_JOB_ABORTED &&
        st != LE_CACHE_JOB_FAILED) {
      continue;
    }
    le_lane_cache* lc = &c->lanes[job->channel][job->lane];
    lc->job_pending = 0;
    /* The enqueue copy and the pre-accounted wet leave the books here; a
     * published wet re-enters as entry bytes in le_cache_install. */
    c->used_bytes -= 3ll * (int64_t)job->len * (int64_t)sizeof(float);
    free(job->dry);
    job->dry = NULL;
    if (st == LE_CACHE_JOB_DONE) {
      lc->renders++;
      lc->fail_count = 0;
      le_track* tr = &e->tracks[job->channel];
      le_lane* ln = &tr->lanes[job->lane];
      const uint32_t rev =
          atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
      const uint64_t fp =
          le_engine_lane_fx_fingerprint(e, job->channel, job->lane);
      const uint32_t vol =
          atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
      const int32_t len = load_i32(&ln->a_len);
      if (cap > 0 && rev == job->audio_rev && fp == job->chain_fp &&
          vol == job->vol_bits && len == job->len) {
        le_cache_install(e, c, job);
      } else {
        free(job->wet); /* the key moved mid-render: discard, never publish */
        job->wet = NULL;
      }
    } else if (st == LE_CACHE_JOB_FAILED) {
      lc->fail_count++;
      if (lc->fail_count >= LE_CACHE_FAIL_GIVE_UP) {
        lc->state = LE_CACHE_GAVE_UP;
        lc->reason = LE_CACHE_REASON_RENDER_FAILED;
      } else {
        lc->state = LE_CACHE_FAILED_RETRYING;
      }
    }
    /* ABORTED: the revision moved; the ordinary schedule path re-renders. */
    atomic_store_explicit(&job->a_state, LE_CACHE_JOB_EMPTY,
                          memory_order_release);
  }
}

/* ---- scheduling (control thread) ---- */

/* One lane's scheduler pass: derive the current key, drive the settle
 * debounce [B2][B3], publish a retained match, or enqueue a render when the
 * gates allow. Every "don't cache" outcome degrades to live — never blocks
 * audio. */
static void le_cache_schedule_lane(le_engine* e, struct le_fx_cache* c,
                                   int64_t cap, int t, int l) {
  le_track* tr = &e->tracks[t];
  le_lane* ln = &tr->lanes[l];
  le_lane_cache* lc = &c->lanes[t][l];

  /* Chain snapshot (atomics -> locals) + its identity. */
  int32_t count = load_i32(&ln->a_fx_count);
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
  int32_t types[LE_FX_MAX];
  int32_t raw_en[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int has_builtin = 0;
  int has_plugin = 0;
  for (int32_t s = 0; s < count; ++s) {
    types[s] = load_i32(&ln->a_fx_type[s]);
    raw_en[s] = load_i32(&ln->a_fx_enabled[s]) ? 1 : 0;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      params[s][p] = load_f32(&ln->a_fx_param[s][p]);
    }
    if (types[s] == LE_FX_PLUGIN) {
      has_plugin = 1;
    } else if (types[s] != LE_FX_NONE) {
      has_builtin = 1;
    }
  }

  /* Plugin-bearing chains are never cached: an offline render would pass the
   * plugin dry. Permanently live with the reason stated — never silent. The
   * retained entries stay (LRU reclaims them; removing the plugin restores
   * the old fingerprint and they become hot again). */
  if (has_plugin) {
    lc->state = LE_CACHE_GAVE_UP;
    lc->reason = LE_CACHE_REASON_PLUGIN;
    return;
  }
  /* lc->reason is deliberately NOT cleared here: a RENDER_FAILED give-up
   * keeps reporting its reason until the key-change re-arm below releases it
   * (the documented "reason meaningful while state == GAVE_UP" contract). */

  const int32_t len = load_i32(&ln->a_len);
  if (len <= 0 || !has_builtin) {
    /* Nothing to cache: no content, or the chain is empty/dry (an empty
     * chain is already zero FX CPU). Content-less lanes free their retained
     * entries eagerly — their revision can never match again. */
    if (len <= 0) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(e, c, t, l, i);
      }
    }
    lc->state = LE_CACHE_LIVE;
    return;
  }

  const uint32_t rev =
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  const uint32_t vol_bits =
      atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
  const uint64_t fp = le_ca_snapshot_fp(count, chain_on, types, raw_en, params);
  /* Cross-check against the canonical atomic fold: a mismatch means the audio
   * thread published a type/count change mid-snapshot — skip this tick rather
   * than schedule a torn chain (the next tick reads it settled). */
  if (fp != le_engine_lane_fx_fingerprint(e, t, l)) return;

  /* Settle debounce [B2][B3]: any key change (content, chain, enabled bits,
   * volume — D-VOL) restarts the window; a change also re-arms a lane that
   * gave up on render failures. */
  const uint64_t now = atomic_load_explicit(&e->a_frames, memory_order_relaxed);
  const uint64_t key_hash = le_ca_key_hash(rev, fp, vol_bits, len);
  if (!lc->has_key || key_hash != lc->last_key_hash) {
    lc->has_key = 1;
    lc->last_key_hash = key_hash;
    lc->key_stable_frames = now;
    lc->fail_count = 0;
    if (lc->state == LE_CACHE_GAVE_UP) lc->state = LE_CACHE_LIVE;
    lc->reason = LE_CACHE_REASON_NONE; /* a changed key re-arms the lane */
  }

  /* A retained entry matching the CURRENT key publishes immediately — the
   * cache-hot path for toggled pairs [B2] (zero re-render on an off/on
   * stomp). */
  for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
    le_wet_entry* ent = lc->entries[i];
    if (ent == NULL) continue;
    if (ent->audio_rev == rev && ent->chain_fp == fp &&
        ent->vol_bits == vol_bits && ent->len == len) {
      ent->last_used = c->lru_clock;
      if (atomic_load_explicit(&ln->a_wet, memory_order_relaxed) != ent) {
        atomic_store_explicit(&ln->a_wet, ent, memory_order_release);
      }
      lc->state = LE_CACHE_CACHED;
      return;
    }
  }

  if (lc->job_pending) {
    lc->state = LE_CACHE_RENDERING;
    return;
  }
  if (lc->state == LE_CACHE_GAVE_UP) return; /* until the key changes */

  /* Enqueue gates [R2](a): stable transport only — never while capturing,
   * and never while an overdub layer is in flight (the punch fade tail and
   * the post-punch drain still write the live buffers under that flag).
   * le_effective_state (engine_core.h) is the same predicate every other
   * control-side decision uses — the unacked-flip window included. */
  const int32_t est = le_effective_state(tr);
  if (est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  if (atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  const float* src = ln->pool[load_i32(&ln->a_live)];
  if (src == NULL) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const uint64_t settle =
      (uint64_t)((int64_t)sr * LE_CACHE_SETTLE_MS / 1000);
  if (now - lc->key_stable_frames < settle) {
    if (lc->state != LE_CACHE_FAILED_RETRYING) lc->state = LE_CACHE_LIVE;
    return;
  }

  /* Memory cap: the whole job footprint (mono enqueue copy + the stereo wet
   * it will produce) is accounted up front; eviction makes room (LRU), and a
   * budget that cannot fit degrades to live and retries later. */
  const int64_t job_bytes = 3ll * (int64_t)len * (int64_t)sizeof(float);
  if (!le_cache_ensure_budget(e, c, cap, job_bytes)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  le_cache_job* job = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    if (atomic_load_explicit(&c->jobs[j].a_state, memory_order_acquire) ==
        LE_CACHE_JOB_EMPTY) {
      job = &c->jobs[j];
      break;
    }
  }
  if (job == NULL) {
    lc->state = LE_CACHE_LIVE; /* queue full; retry next tick */
    return;
  }

  /* Copy-at-enqueue [R2](a), seqlock shape: the revision is re-read after
   * the copy; any content mutation that began mid-copy bumped it first (the
   * bump-site table, engine_private.h), so a torn copy can never proceed —
   * and the [B5] publish re-check would discard it even if it rendered. */
  float* dry = (float*)malloc((size_t)len * sizeof(float));
  if (dry == NULL) {
    lc->fail_count++;
    lc->state = lc->fail_count >= LE_CACHE_FAIL_GIVE_UP
                    ? LE_CACHE_GAVE_UP
                    : LE_CACHE_FAILED_RETRYING;
    if (lc->state == LE_CACHE_GAVE_UP) {
      lc->reason = LE_CACHE_REASON_RENDER_FAILED;
    }
    return;
  }
  memcpy(dry, src, (size_t)len * sizeof(float));
  atomic_thread_fence(memory_order_acquire);
  if (atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) != rev) {
    free(dry); /* content moved mid-copy: torn — drop and retry later */
    lc->state = LE_CACHE_LIVE;
    return;
  }

  job->channel = t;
  job->lane = l;
  job->audio_rev = rev;
  job->chain_fp = fp;
  job->vol_bits = vol_bits;
  job->vol = bits_to_f32(vol_bits);
  job->len = len;
  job->sample_rate = sr;
  job->fx_cap = e->fx_delay_frames;
  job->fx_count = count;
  for (int32_t s = 0; s < count; ++s) {
    job->fx_type[s] = types[s];
    job->fx_effective[s] = chain_on && raw_en[s];
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      job->fx_params[s][p] = params[s][p];
    }
  }
  job->dry = dry;
  job->wet = NULL;
  c->used_bytes += job_bytes;
  lc->job_pending = 1;
  lc->state = LE_CACHE_RENDERING;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_QUEUED,
                        memory_order_release);
}

/* ---- the render worker [B6] ---- */

/* Frees a heap le_fx_state's owned buffers (delay rings + octaver heap) —
 * the perf_render.c teardown, duplicated per TU by that file's own
 * convention. This state is worker-private; no live-engine path ever sees
 * it. */
static void le_ca_fx_state_free(le_fx_state* fx) {
  for (int s = 0; s < LE_FX_MAX; ++s) {
    free(fx->delay[s][0]);
    fx->delay[s][0] = NULL;
    free(fx->delay[s][1]);
    fx->delay[s][1] = NULL;
    le_fx_free_octaver(fx, s);
  }
}

/* Picks the next queued job, playing lanes first [B6]: a lane currently
 * audible always renders before a stopped one. */
static le_cache_job* le_cache_pick(le_engine* e, struct le_fx_cache* c) {
  le_cache_job* fallback = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    le_cache_job* job = &c->jobs[j];
    if (atomic_load_explicit(&job->a_state, memory_order_acquire) !=
        LE_CACHE_JOB_QUEUED) {
      continue;
    }
    const int32_t st = load_i32(&e->tracks[job->channel].a_state);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) return job;
    if (fallback == NULL) fallback = job;
  }
  return fallback;
}

/* Renders one job: dry x volume through the engine's own fx_apply_chain on a
 * worker-owned heap le_fx_state — the perf_render pattern, no forked DSP.
 * RENDER-TWICE-KEEP-SECOND: the loop is processed twice back-to-back and only
 * the second pass is kept, so delay/reverb tails that wrap the loop boundary
 * are baked in (pass 1 is exactly the chain's first live lap, so the kept
 * pass matches a live chain that engaged at the previous loop top). Aborts
 * on an a_audio_rev bump for its lane or on shutdown [B5], checked once per
 * LE_CACHE_ABORT_CHECK_FRAMES block. */
static void le_cache_render(le_engine* e, struct le_fx_cache* c,
                            le_cache_job* job) {
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_RUNNING,
                        memory_order_release);
  le_track* tr = &e->tracks[job->channel];

  float* wet = (float*)malloc(2u * (size_t)job->len * sizeof(float));
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (wet == NULL || fx == NULL) {
    free(wet);
    free(fx);
    atomic_store_explicit(&job->a_state, LE_CACHE_JOB_FAILED,
                          memory_order_release);
    return;
  }
  /* Seed the enable-crossfade runtime per EFFECTIVE bit, mirroring the live
   * chain's settled state exactly: enabled slots settled wet (no fade-in at
   * frame 0), disabled slots settled bypass (no 5 ms fade-out the live chain
   * would not have). */
  for (int s = 0; s < LE_FX_MAX; ++s) {
    if (s < job->fx_count && job->fx_effective[s]) {
      le_fx_enable_seed_settled(fx, s);
    } else {
      le_fx_enable_force_bypass(fx, s);
    }
  }
  int failed = 0;
  for (int32_t s = 0; s < job->fx_count; ++s) {
    /* Match the live chain's slot state exactly: the SET_*_FX ring handler
     * runs le_fx_entry_reset on the audio thread when a type lands, so the
     * render's fresh state must start from that same reset (a raw calloc
     * zero differs — e.g. the octaver's shift smoother seeds at unison 0.5,
     * not 0.0). */
    le_fx_entry_reset(fx, s);
    if (job->fx_type[s] != LE_FX_NONE &&
        le_fx_prepare(fx, s, job->fx_type[s], job->fx_cap) != LE_OK) {
      failed = 1; /* OOM on a ring/octaver heap: a real failure, not a
                   * silent dry-slot degradation (the perf_render posture) */
    }
  }

  int aborted = 0;
  for (int pass = 0; pass < 2 && !failed && !aborted; ++pass) {
    for (int32_t f = 0; f < job->len; ++f) {
      if ((f % LE_CACHE_ABORT_CHECK_FRAMES) == 0) {
        if (atomic_load_explicit(&c->a_shutdown, memory_order_acquire) ||
            atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) !=
                job->audio_rev) {
          aborted = 1;
          break;
        }
      }
      const float in = job->dry[f] * job->vol; /* pre-chain volume (D-VOL) */
      float l = in;
      float r = in;
      fx_apply_chain(fx, job->sample_rate, job->fx_cap, &l, &r, job->fx_count,
                     job->fx_type, job->fx_params, job->fx_effective);
      if (pass == 1) {
        wet[2 * f] = l;
        wet[2 * f + 1] = r;
      }
    }
  }

  le_ca_fx_state_free(fx);
  free(fx);
  if (failed || aborted) {
    free(wet);
    atomic_store_explicit(
        &job->a_state, failed ? LE_CACHE_JOB_FAILED : LE_CACHE_JOB_ABORTED,
        memory_order_release);
    return;
  }
  job->wet = wet;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_DONE,
                        memory_order_release);
}

static void le_ca_worker_main(void* arg) {
  le_engine* e = (le_engine*)arg;
  struct le_fx_cache* c = e->cache; /* stable: shutdown joins before free */
  while (!atomic_load_explicit(&c->a_shutdown, memory_order_acquire)) {
    le_cache_job* job = le_cache_pick(e, c);
    if (job == NULL) {
      le_ca_sleep_ms(1);
      continue;
    }
    le_cache_render(e, c, job);
  }
}

/* ---- lifecycle + tick ---- */

void le_cache_init(le_engine* engine) {
  if (engine == NULL || engine->cache != NULL) return;
  struct le_fx_cache* c =
      (struct le_fx_cache*)calloc(1, sizeof(struct le_fx_cache));
  if (c == NULL) return; /* caching disabled; everything plays live */
  c->engine = engine;
  engine->cache = c;
  if (!le_ca_thread_start(&c->worker, engine)) {
    engine->cache = NULL;
    free(c);
    return;
  }
  c->worker_started = 1;
}

void le_cache_shutdown(le_engine* engine) {
  if (engine == NULL || engine->cache == NULL) return;
  struct le_fx_cache* c = engine->cache;
  /* Join-before-free [R2](d): the worker observes the flag at its next
   * per-block abort check, so a mid-render join is bounded. */
  atomic_store_explicit(&c->a_shutdown, 1, memory_order_release);
  if (c->worker_started) le_ca_thread_join(c->worker);
  /* Every caller guarantees the audio thread is stopped here, so the frees
   * below need no quiescent window — retract everything into the graveyard,
   * then force-sweep it, so a later restart can never observe a dangling
   * entry and nothing leaks. */
  le_cache_free_all_entries(engine, c);
  le_cache_sweep_graveyard(engine, c, 1);
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    free(c->jobs[j].dry);
    free(c->jobs[j].wet);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &engine->tracks[t].lanes[l];
      atomic_store_explicit(&ln->a_wet, NULL, memory_order_release);
      store_i32(&ln->a_cache_active, 0);
    }
  }
  engine->cache = NULL;
  free(c);
}

void le_cache_tick(le_engine* engine) {
  struct le_fx_cache* c = engine->cache;
  if (c == NULL) return;
  const int64_t cap =
      atomic_load_explicit(&engine->a_fx_cache_cap, memory_order_relaxed);
  c->lru_clock++;
  le_cache_sweep_graveyard(engine, c, 0); /* passive quiescent frees [R2](c) */
  le_cache_collect(engine, c, cap);
  if (cap <= 0) {
    /* Caching disabled: free everything; lanes report live. In-flight jobs
     * finish and are discarded by the collect above on later ticks. */
    le_cache_free_all_entries(engine, c);
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      for (int l = 0; l < LE_MAX_LANES; ++l) {
        if (!c->lanes[t][l].job_pending) c->lanes[t][l].state = LE_CACHE_LIVE;
      }
    }
    return;
  }
  for (int t = 0; t < engine->track_count; ++t) {
    const int32_t lanes = le_lanes_active(&engine->tracks[t]);
    for (int l = 0; l < lanes; ++l) {
      le_cache_schedule_lane(engine, c, cap, t, l);
    }
    /* A lane deactivated by a count shrink is never scheduled again — its
     * retained entries would otherwise linger until LRU pressure. Reclaim
     * them here (cheap NULL checks in the steady state). */
    for (int l = lanes; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(engine, c, t, l, i);
      }
    }
  }
  /* The cap may have shrunk since entries were installed. */
  (void)le_cache_ensure_budget(engine, c, cap, 0);
}

/* ---- FFI telemetry (log/test-only in v3 [R27]) ---- */

int32_t le_engine_get_lane_cache(le_engine* engine, int32_t channel,
                                 int32_t lane, le_lane_cache_info* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  /* Polling this drives the cache: drain -> tick (collect/schedule). */
  le_engine_drain_events(engine);
  memset(out, 0, sizeof(*out));
  le_track* tr = &engine->tracks[channel];
  le_lane* ln = &tr->lanes[lane];
  out->audio_rev = atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  out->engaged = load_i32(&ln->a_cache_active); /* relaxed telemetry read */
  le_wet_entry* w = atomic_load_explicit(&ln->a_wet, memory_order_relaxed);
  out->entry_frames = w != NULL ? w->len : 0;
  if (engine->cache != NULL) {
    const le_lane_cache* lc = &engine->cache->lanes[channel][lane];
    out->state = lc->state;
    out->reason = lc->reason;
    out->renders = lc->renders;
  } else {
    out->state = LE_CACHE_LIVE;
  }
  return LE_OK;
}

int32_t le_engine_set_fx_cache_cap(le_engine* engine, int64_t bytes) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (bytes < 0) bytes = 0;
  atomic_store_explicit(&engine->a_fx_cache_cap, bytes, memory_order_relaxed);
  /* Apply immediately (evict down / free all) rather than waiting a poll. */
  le_cache_tick(engine);
  return LE_OK;
}

int64_t le_engine_fx_cache_used_bytes(le_engine* engine) {
  if (engine == NULL || engine->cache == NULL) return 0;
  return engine->cache->used_bytes;
}

uint32_t le_engine_track_audio_rev(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return 0;
  }
  return atomic_load_explicit(&engine->tracks[channel].a_audio_rev,
                              memory_order_acquire);
}
