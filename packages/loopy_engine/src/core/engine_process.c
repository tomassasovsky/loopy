/*
 * engine_process.c — THE AUDIO-THREAD TU.
 *
 * Everything the device callback runs lives here and nowhere else: the real-time
 * contract holds for this whole file — no malloc/free, no locks, no syscalls, no
 * unbounded loops. le_engine_process is the block processor the miniaudio / ASIO
 * data callback pumps; it drains the SPSC command ring (apply_command), advances
 * the transport state machine (the finalize_* / handle_* helpers), records /
 * overdubs / mixes, runs the per-lane effect chains (fx_apply_chain), resolves the
 * loopback latency harness, and publishes metering + visualization atomics.
 *
 * Split verbatim out of engine.c (S1) behind the unchanged ABI. The transport
 * handlers live here rather than in a separate engine_transport.c because they run
 * ON the audio thread (invoked only by apply_command and le_engine_process); the
 * control-thread record/undo entry points (le_engine_record etc.) are in
 * engine_commands.c. Shared low-level helpers (valid_channel, le_track_set_len,
 * comp_pos, le_lanes_active) come from engine_core.h; the chain runner from
 * engine_fx.h.
 */
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "audio_ring.h"      /* le_audio_ring_push_frame (performance capture) */
#include "engine_core.h"     /* valid_channel, le_track_set_len, le_mask_to_channel */
#include "engine_fx.h"       /* fx_apply_chain, le_fx_entry_reset */
#include "engine_internal.h" /* le_engine_process prototype */
#include "engine_private.h"  /* le_engine + the published atomics */
#include "lockfree_ring.h"   /* le_command, le_ring_pop */
#include "loop_clock.h"      /* le_loop_clock_* */
#include "loopy_engine_api.h"
#include "perf_log_ring.h" /* le_perf_log_ring_push, le_perf_log_code (perf event log) */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
#include <pmmintrin.h> /* _MM_SET_DENORMALS_ZERO_MODE (DAZ) */
#include <xmmintrin.h> /* _MM_SET_FLUSH_ZERO_MODE (FTZ) */
#endif

/* Flush denormals to zero on the audio thread. Decaying FX tails (reverb/delay/
 * phase-vocoder) trend toward ~1e-30, and denormal arithmetic can be orders of
 * magnitude slower — a CPU spike that shows up as a buffer underrun (dropout /
 * click), not as wrong audio. FTZ+DAZ make the FPU treat those as zero. Per
 * thread, so we set it each callback (negligible cost). No-op where unsupported;
 * the inaudible denormals simply remain. */
static inline void le_flush_denormals(void) {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#elif defined(__aarch64__)
  uint64_t fpcr;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
  fpcr |= (1ull << 24); /* FZ: flush-to-zero */
  __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr));
#endif
}

/* The loopback-latency-harness and auto-record tuning constants (LE_LATENCY_* /
 * LE_AUTO_RECORD_THRESHOLD) live in engine_core.h — shared with le_engine_configure
 * (engine.c), which sizes the latency capture buffer from LE_LATENCY_CAPTURE_DIV. */

/* ---- command handlers (audio thread) ---- */

/* Defined with the per-pass capture machinery below; every path that moves a
 * track into OVERDUBBING calls it so the layer capture is armed. */
static void le_dub_session_start(le_engine* e, le_track* t);

/* Performance event log (part 3, docs/design/performance-event-log-format.md):
 * pushes one entry into perf.log_ring, tagged with `frame` — the capture
 * frame it occurred at, same epoch as a_perf_frames/the PCM taps below. No-op
 * when not armed; a full ring drops the entry and bumps a dedicated overrun
 * atomic (tracked apart from a_perf_overruns, the PCM-tap counter — a dropped
 * log entry and a dropped audio sample are different failure modes). RT-safe:
 * no allocation, no blocking, mirrors the audio-tap discipline below. */
static inline void le_plog_push(le_engine* e, uint64_t frame, le_command cmd) {
  if (!e->perf.armed) return;
  const le_perf_log_entry entry = {.frame = frame, .cmd = cmd};
  if (!le_perf_log_ring_push(&e->perf.log_ring, entry)) {
    atomic_fetch_add_explicit(&e->a_perf_log_overruns, 1u,
                              memory_order_relaxed);
  }
}

static void finalize_master(le_engine* e, le_track* t, int32_t end_state,
                            uint64_t frame) {
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  /* The master loop length is established (or re-established, on a hand-off
   * finalize) right here — this is the live-record-path call site for the
   * LE_PLOG_LOOP_LENGTH_LOCKED transport fact (the other is LE_CMD_COMMIT_
   * SESSION, for session import). */
  le_plog_push(e, frame,
              (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED, .arg_i = len});
  le_loop_clock_set_length(&e->clock, len);
  e->loop_iteration = 0; /* the base loop just (re)started */
  store_i32(&e->a_master_len, len);
  le_track_set_len(t, len);
  store_i32(&t->a_multiple, 1); /* the defining track is one base loop */
  store_i32(&t->a_state, end_state);
  t->start_iter = 0;
  /* This track leaves RECORDING here regardless of end_state — even the
   * OVERDUBBING case is a record-to-overdub toggle, not a continuation of the
   * same recording. */
  le_plog_push(e, frame,
              (le_command){.code = LE_PLOG_RECORD_END,
                           .arg_i = (int32_t)(t - e->tracks)});
  if (end_state == LE_TRACK_OVERDUBBING) le_dub_session_start(e, t);
}

/* Seam-crossfade overlap length (~10 ms): the frames captured past the loop
 * point and folded into the head. Also the minimum half-loop the master must
 * span to be eligible (it needs head + tail room plus steady audio between). */
static int32_t seam_xfade_frames(const le_engine* e) {
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  return sr / 100;
}

/* Requests finalize of the *defining master* at its current length. When the
 * loop is long enough and the buffer has room, this defers the finalize: the
 * track keeps RECORDING F more frames so the seam can be crossfaded (see
 * finalize_master_xfade), preserving the recorded length exactly. Otherwise
 * (short loop, no room, or a finalize already in flight) it finalizes now. */
static void request_master_finalize(le_engine* e, le_track* t,
                                    int32_t end_state, uint64_t frame) {
  if (t->xfade_capture > 0) return; /* already deferring — ignore re-entry */
  const int32_t F = seam_xfade_frames(e);
  const int32_t len = t->record_pos;
  if (F > 0 && len >= 2 * F && len + F <= e->max_loop_frames) {
    t->xfade_len = len;
    t->xfade_end_state = end_state;
    t->xfade_capture = F; /* stay RECORDING; the per-frame advance counts down */
  } else {
    finalize_master(e, t, end_state, frame);
  }
}

/* Finalizes a non-defining track that recorded freely across one or more base
 * loops: rounds its length UP to the nearest whole base loop (the locked #4
 * behaviour), publishes the multiple, and moves it to `end_state`. A track that
 * captured nothing (never reached the loop top) returns to EMPTY. Length policy
 * comes from le_effective_multiple (engine_private.h — shared with the control
 * thread's first-wrap pre-arm gate, which predicts this finalize). */
static void finalize_new_track(le_engine* e, le_track* t, int32_t end_state,
                               uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t base = e->clock.length > 0 ? e->clock.length : 1;
  if (t->record_pos <= 0) { /* nothing captured */
    store_i32(&t->a_state, LE_TRACK_EMPTY);
    le_track_set_len(t, 0);
    store_i32(&t->a_multiple, 1);
    t->record_pos = 0;
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_RECORD_END, .arg_i = ch});
    return;
  }
  /* A forced multiple fixes the length to exactly K base loops; 0 (auto) rounds
   * up to whole base loops based on how much was recorded. */
  const int32_t forced = le_effective_multiple(e, ch);
  int32_t k = forced > 0 ? forced : (t->record_pos + base - 1) / base;
  const int32_t maxk = e->max_loop_frames / base;
  if (k < 1) k = 1;
  if (maxk >= 1 && k > maxk) k = maxk;
  store_i32(&t->a_multiple, k);
  le_track_set_len(t, k * base);
  store_i32(&t->a_state, end_state);
  t->record_pos = 0;
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_RECORD_END, .arg_i = ch});
  if (end_state == LE_TRACK_OVERDUBBING) le_dub_session_start(e, t);
}
/* ---- per-pass undo layer capture (audio thread) ----
 *
 * While a track overdubs, every in-place write first saves the pre-value into
 * the armed shadow slot (same slot index on every lane, lockstep). The write
 * trajectory visits each of the track's dub_len positions exactly once per
 * dub_len frames, so dub_count == dub_len means the shadow holds a complete
 * pre-pass image; it is then retired through the evt_ring (the control thread
 * stacks it as one undo layer) and the pre-posted spare takes over. A punch-out
 * mid-pass leaves live authoritative (writes were in place); once the punch
 * envelope has decayed the uncovered remainder is bulk-copied live -> shadow in
 * bounded chunks (le_dub_block_update) and the completed layer retires. */

/* Begins (or continues) a dub capture session when a track enters OVERDUBBING.
 * A session already in flight (re-punch-in during the fade tail or the drain)
 * keeps its capture state untouched — the coverage stays coherent and the
 * passes merge into one layer; a fresh session latches the pass length and the
 * record offset (a mid-dub offset change would tear the trajectory) and arms
 * the spare. dub_count = -1 defers the start-point latch to the first write,
 * so no entry path (press, quantize fire, rec/dub or auto finalize) needs
 * position math here. */
static void le_dub_session_start(le_engine* e, le_track* t) {
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if (len <= 0) return;
  if (load_i32(&t->a_layer_in_flight)) {
    /* A re-punch while the previous layer is still in flight. Two cases:
     *  - Fade-tail continuation (od_gain > 0): writes never stopped, so the
     *    shadow's coverage is still contiguous — keep capturing into it; the
     *    passes merge into one coherent layer.
     *  - Gap / drain re-punch (od_gain == 0 with a partial shadow): writes
     *    stopped and the transport moved on, so resuming the old coverage
     *    would leave holes — and a drain running underneath would copy the
     *    NEW dub's audio into the OLD layer's uncovered remainder (a torn
     *    snapshot). Discard the partial coverage and restart the capture on
     *    the same slot: the new session's first pass re-covers it fully. The
     *    interrupted partial pass simply stops being separately undoable —
     *    every undo boundary still restores a state that actually existed. */
    if (t->od_gain <= 0.0f && t->dub_slot >= 0 &&
        (t->dub_draining ||
         (t->dub_count > 0 && t->dub_count < t->dub_len))) {
      t->dub_draining = 0;
      t->dub_count = -1;
      t->dub_phase = 0;
    }
    return;
  }
  t->dub_len = len;
  t->dub_offset = load_i32(&e->a_record_offset);
  t->dub_phase = 0;
  if (t->dub_slot < 0 && t->dub_spare >= 0) {
    t->dub_slot = t->dub_spare;
    t->dub_spare = -1;
  }
  t->dub_count = -1;
  atomic_store_explicit(&t->a_layer_in_flight, 1, memory_order_release);
}

/* Tries to push a parked retired layer into the evt_ring (audio thread).
 * Wait-free: on a full ring the slot simply stays parked for the next block —
 * never blocked, never dropped. */
static void le_dub_try_retire(le_engine* e, le_track* t, uint64_t frame) {
  if (t->dub_retire_slot < 0) return;
  const le_command evt = {.code = LE_EVT_LAYER_RETIRED,
                          .evt = {(int32_t)(t - e->tracks), t->dub_retire_slot,
                                  t->dub_gen_audio}};
  if (le_ring_push(&e->evt_ring, evt)) {
    t->dub_retire_slot = -1;
    /* Same payload shape as the evt_ring push above (LE_EVT_LAYER_RETIRED's
     * `evt` arm), just tagged with the capture frame and a distinct code
     * (LE_PLOG_LAYER_RETIRED) for the perf log — the two rings serve
     * different consumers (control-thread undo stacking vs. the drain
     * thread's events.log) and must not be confused. */
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_LAYER_RETIRED, .evt = evt.evt});
  }
}

/* Drops the track's armed shadow slots (audio thread) — a fresh capture or a
 * redo-from-empty may change the loop length, and a leftover slot could be
 * sized for the OLD length (undo layers are loop-length-quantized). The
 * control side reclaimed `outstanding` when it posted the triggering command,
 * so the slots return to the pool cleanly; correctly-sized replacements arrive
 * via the poll-driven replenish once a dub session runs. */
static void le_dub_drop_armed(le_track* t) {
  t->dub_slot = -1;
  t->dub_spare = -1;
  t->dub_retire_slot = -1;
  t->dub_count = -1;
  t->dub_phase = 0;
  t->dub_draining = 0;
}

/* Pass boundary (dub_phase wrapped): hand a complete shadow to the retire
 * queue and arm the pre-posted spare for the next pass. With the retire queue
 * still occupied (evt ring full) the complete shadow stays frozen — writes
 * continue un-backed and the passes merge coherently into one layer. With no
 * spare on hand the boundary is skipped the same way. */
static void le_dub_boundary(le_engine* e, le_track* t, uint64_t frame) {
  if (t->dub_draining) return; /* the armed shadow belongs to the old session */
  if (t->dub_slot >= 0 && t->dub_count >= t->dub_len) {
    if (t->dub_retire_slot >= 0) return; /* frozen: retire is stuck */
    t->dub_retire_slot = t->dub_slot;
    t->dub_slot = -1;
    le_dub_try_retire(e, t, frame);
  }
  if (t->dub_slot < 0 && t->dub_spare >= 0) {
    t->dub_slot = t->dub_spare;
    t->dub_spare = -1;
    t->dub_count = -1; /* first write of the new pass latches the start */
  }
}

/* Once-per-block dub maintenance for every track (audio thread; also runs for
 * frames == 0 calls so the host tests' drain(e) pump advances it): retries
 * parked retires, and — once a punched-out session's fade tail has decayed —
 * drains the uncovered remainder of the in-flight layer live -> shadow in
 * LE_DRAIN_CHUNK-bounded runs, retires it, and clears the flight flag. The
 * retire event is pushed BEFORE the flag clears (the release pairs with the
 * control thread's acquire), so a control thread that sees flag == 0 after
 * draining the evt_ring is guaranteed to hold every layer. */
static void le_dub_block_update(le_engine* e, uint64_t frame) {
  const int32_t base = e->clock.length;
  for (int32_t ti = 0; ti < e->track_count; ++ti) {
    le_track* t = &e->tracks[ti];
    le_dub_try_retire(e, t, frame);
    if (!load_i32(&t->a_layer_in_flight)) continue;
    const int32_t st = load_i32(&t->a_state);
    if (st == LE_TRACK_OVERDUBBING || t->od_gain > 0.0f) continue; /* writing */

    /* Punch-out complete. A partially covered shadow drains: the un-backed
     * positions were never written this pass, so live still holds their
     * pre-pass values and any copy order works — the trajectory walk just
     * enumerates exactly the uncovered set. */
    if (t->dub_slot >= 0 && t->dub_count > 0 && t->dub_count < t->dub_len &&
        !t->dub_draining && base > 0) {
      t->dub_draining = 1;
      const int32_t k0 = load_i32(&t->a_multiple) > 0
                             ? load_i32(&t->a_multiple)
                             : 1;
      const int64_t ahead = (int64_t)t->dub_start_vpos + t->dub_count;
      t->dub_vpos = (int32_t)(ahead % base);
      t->dub_vseg = (int32_t)((t->dub_start_vseg + ahead / base) % k0);
    }
    if (t->dub_draining && base > 0) {
      const int32_t k = load_i32(&t->a_multiple) > 0 ? load_i32(&t->a_multiple)
                                                     : 1;
      const int32_t off = t->dub_offset > 0 ? t->dub_offset % base : 0;
      const int32_t lanes = le_lanes_active(t);
      /* The copy runs per lane, so the RT budget is frames x lanes — scale the
       * chunk down so a multi-lane track drains the same bytes per block as a
       * mono one (LE_DRAIN_CHUNK samples per track per callback). */
      int32_t budget = LE_DRAIN_CHUNK / lanes;
      if (budget < 1) budget = 1;
      while (budget > 0 && t->dub_count < t->dub_len) {
        /* Contiguous w run: until the segment ends (vpos wraps) or the
         * compensated position wraps (vpos == off). */
        int32_t run = base - t->dub_vpos;
        if (t->dub_vpos < off && off - t->dub_vpos < run) {
          run = off - t->dub_vpos;
        }
        if (run > budget) run = budget;
        if (run > t->dub_len - t->dub_count) run = t->dub_len - t->dub_count;
        const int32_t w0 =
            t->dub_vseg * base + comp_pos(t->dub_vpos, off, base);
        for (int32_t l = 0; l < lanes; ++l) {
          le_lane* ln = &t->lanes[l];
          float* lb = ln->pool[load_i32(&ln->a_live)];
          float* sb = ln->pool[t->dub_slot];
          if (lb != NULL && sb != NULL) {
            memcpy(sb + w0, lb + w0, (size_t)run * sizeof(float));
          }
        }
        t->dub_count += run;
        budget -= run;
        t->dub_vpos += run;
        if (t->dub_vpos >= base) {
          t->dub_vpos = 0;
          t->dub_vseg = (t->dub_vseg + 1) % k;
        }
      }
      if (t->dub_count >= t->dub_len) t->dub_draining = 0;
    }
    if (t->dub_draining) continue; /* more chunks next block */

    /* Retire a complete shadow (drained, or frozen at punch-out). */
    if (t->dub_slot >= 0 && t->dub_count >= t->dub_len &&
        t->dub_retire_slot < 0) {
      t->dub_retire_slot = t->dub_slot;
      t->dub_slot = -1;
      le_dub_try_retire(e, t, frame);
    }
    /* Session fully wound down: every layer retired and collected-able. */
    if (t->dub_retire_slot < 0 && (t->dub_slot < 0 || t->dub_count <= 0)) {
      atomic_store_explicit(&t->a_layer_in_flight, 0, memory_order_release);
    }
  }
}

/* There is a single input stream, so only one track may capture at a time.
 * Closes any track (other than `except_ch`) that is currently RECORDING or
 * OVERDUBBING, finalizing the master loop if the closed track was the defining
 * recording. Called before starting a new capture. */
static void close_active_capture(le_engine* e, int32_t except_ch,
                                 uint64_t frame) {
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (t == except_ch) continue;
    le_track* tr = &e->tracks[t];
    const int32_t st = load_i32(&tr->a_state);
    if (st == LE_TRACK_RECORDING) {
      if (e->clock.length == 0) {
        /* Hand-off is immediate (one capturer): if this master was mid seam-
         * crossfade deferral, lock its intended length and finalize now without
         * the crossfade rather than keep it recording alongside the new track. */
        if (tr->xfade_capture > 0) {
          tr->record_pos = tr->xfade_len;
          tr->xfade_capture = 0;
        }
        finalize_master(e, tr, LE_TRACK_PLAYING, frame); /* defines the master loop */
      } else {
        finalize_new_track(e, tr, LE_TRACK_PLAYING, frame); /* round up to whole loops */
      }
    } else if (st == LE_TRACK_OVERDUBBING) {
      store_i32(&tr->a_state, LE_TRACK_PLAYING);
    }
  }
}

/* Acts on a record/overdub press: finalizes any other capture (one-capturer
 * hand-off), then advances this track's state machine. */
static void handle_record(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  close_active_capture(e, ch, frame);
  le_track* t = &e->tracks[ch];
  switch (load_i32(&t->a_state)) {
    case LE_TRACK_EMPTY:
      /* A fresh capture may define a new loop length: leftover armed shadow
       * slots (sized for the previous loop) are dropped; control reclaimed
       * them when it posted this command/arm. */
      le_dub_drop_armed(t);
      /* First record overall (no master yet) defines the master loop; otherwise
       * the new track records freely from the loop top. Both are RECORDING,
       * distinguished by clock.length. */
      if (e->clock.length == 0) {
        t->record_pos = 0;
        t->record_start = 0;
        le_loop_clock_reset(&e->clock);
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      } else {
        /* New track over an existing master: begin capturing immediately at the
         * current loop phase — no waiting for the loop top. record_pos seeds to
         * the master position and start_iter to the current iteration, so it
         * stays equal to (loop_iteration - start_iter)*base + position; buffer
         * writes are therefore phase-locked to the master. Spans one or more
         * base loops, rounded up on stop — or exactly K with a fixed multiple
         * (auto-finalized), where the write head wraps into K*base so a
         * mid-loop take keeps the audio played past the loop top. The slice
         * before the press stays silent (zeroed on the control thread) until
         * a fixed-multiple take wraps around and fills it. */
        t->record_pos = e->clock.position;
        t->record_start = t->record_pos;
        t->start_iter = e->loop_iteration;
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      }
      /* The transport fact: this track actually began recording THIS frame —
       * whether from an immediate press (frame == the buffer-start tag from
       * apply_command) or a deferred quantized/sound-triggered fire (frame ==
       * the exact sample index from inside the per-frame loop). */
      le_plog_push(e, frame,
                  (le_command){.code = LE_PLOG_RECORD_START, .arg_i = ch});
      break;
    case LE_TRACK_RECORDING: {
      /* Second press finalizes. In rec/dub mode it continues into overdub
       * instead of playback; the shadow slot pre-armed during RECORDING (see
       * le_engine_record / le_engine_drain_events) lets this first wrap's pass
       * back up on write and retire as its own undo layer, unless the loop was
       * too short for that post to land (then it merges — see le_dub_boundary).
       * A stop press ends in playback/stopped (handle_stop), never overdub. */
      const int32_t end = e->rec_dub ? LE_TRACK_OVERDUBBING : LE_TRACK_PLAYING;
      if (e->clock.length == 0) {
        request_master_finalize(e, t, end, frame); /* defers for the seam crossfade */
      } else {
        finalize_new_track(e, t, end, frame);
      }
      break;
    }
    case LE_TRACK_PLAYING:
    case LE_TRACK_STOPPED:
      /* Punch-in: arm the per-pass layer capture (the shadow slots were posted
       * by le_engine_record before this command). */
      store_i32(&t->a_state, LE_TRACK_OVERDUBBING);
      le_dub_session_start(e, t);
      break;
    case LE_TRACK_OVERDUBBING:
      store_i32(&t->a_state, LE_TRACK_PLAYING);
      break;
    default:
      break;
  }
}

static void handle_stop(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  const int32_t st = load_i32(&t->a_state);
  if (st == LE_TRACK_RECORDING) {
    if (e->clock.length == 0) {
      request_master_finalize(e, t, LE_TRACK_STOPPED, frame); /* defers for crossfade */
    } else {
      finalize_new_track(e, t, LE_TRACK_STOPPED, frame); /* round up to whole loops */
    }
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) {
    store_i32(&t->a_state, LE_TRACK_STOPPED);
  }
}

static void handle_play(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  if (load_i32(&t->a_state) == LE_TRACK_STOPPED) {
    store_i32(&t->a_state, LE_TRACK_PLAYING);
  }
}

static void handle_clear(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  t->record_pos = 0;
  t->start_iter = 0;
  t->pending_record = 0;
  t->od_gain = 0.0f;
  t->xfade_capture = 0; /* cancel any in-flight seam-crossfade deferral */
  store_i32(&t->a_pending, 0);
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  /* Drop the per-pass capture wholesale: the control thread reclaimed every
   * posted shadow slot when it pushed this clear and bumped the generation (we
   * mirror the bump), so an already-pushed retire event from before the clear
   * reads as stale and is never re-stacked. */
  t->dub_slot = -1;
  t->dub_spare = -1;
  t->dub_retire_slot = -1;
  t->dub_count = -1;
  t->dub_phase = 0;
  t->dub_draining = 0;
  t->dub_gen_audio++;
  atomic_store_explicit(&t->a_layer_in_flight, 0, memory_order_release);
  /* A cleared track comes back unmuted: the next recording is always audible
   * rather than silently muted by a leftover Stop. */
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    store_i32(&t->lanes[l].a_muted, 0);
  }
  atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
  /* Undo/redo stacks and each lane's a_live are reset by le_engine_clear on the
   * control thread; the audio thread only resets the state/transport here. */

  /* If every track is now empty, reset the master so a new loop can be defined.
   * Buffers are not zeroed here (RT-unsafe); a re-record overwrites a full loop
   * before the track is heard, so stale data never plays. */
  for (int32_t k = 0; k < e->track_count; ++k) {
    if (load_i32(&e->tracks[k].a_state) != LE_TRACK_EMPTY) return;
  }
  le_loop_clock_reset(&e->clock);
  e->loop_iteration = 0;
  store_i32(&e->a_master_len, 0);
  store_i32(&e->a_master_pos, 0);
  /* Clear the loop waveform so a re-record starts from silence. */
  e->loop_viz_bucket = -1;
  for (int i = 0; i < LE_VIZ_POINTS; ++i) {
    store_f32(&e->a_loop_viz[i], 0.0f);
    for (int t = 0; t < e->track_count; ++t) {
      store_f32(&e->a_track_viz[t][i], 0.0f);
    }
  }
}

/* Per-lane / per-monitor effects DSP (the effect kernels, the phase-vocoder /
 * PSOLA octaver, the Freeverb reverb, and the chain runner) moved to engine_fx.c
 * (S1). The cross-TU surface and the PV/PSOLA tuning constants live in
 * engine_fx.h. LE_PI stays here for finalize_master_xfade below. */

#ifndef LE_PI
#define LE_PI 3.14159265358979323846f
#endif

/* Completes a deferred crossfade-finalize of the defining master (set up by
 * request_master_finalize once xfade_capture frames of overlap are captured).
 * Equal-power crossfade of the captured continuation [len, len+F) into the loop
 * head [0, F): each head sample morphs from the continuation (which follows
 * len-1 naturally) into the original head, so the wrap len-1 -> 0 is continuous
 * and no power dips. The loop is then finalized at exactly `len`. */
static void finalize_master_xfade(le_engine* e, le_track* t, uint64_t frame) {
  const int32_t len = t->xfade_len;
  const int32_t F = seam_xfade_frames(e);
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    float* b = t->lanes[l].pool[load_i32(&t->lanes[l].a_live)];
    if (b == NULL) continue;
    for (int32_t i = 0; i < F; ++i) {
      const float x = (float)i / (float)F;        /* 0..1 across the fade */
      const float w_in = sinf(0.5f * LE_PI * x);  /* original head fades in */
      const float w_out = cosf(0.5f * LE_PI * x); /* continuation fades out */
      b[i] = b[len + i] * w_out + b[i] * w_in;
    }
  }
  t->record_pos = len; /* finalize at the intended length, not len+F */
  t->xfade_capture = 0;
  finalize_master(e, t, t->xfade_end_state, frame);
}

/* Sums a lane/monitor's processed (l, r) pair into the masked output channels:
 * the left on the first masked channel and the right on the second; any further
 * masked channels — and the lone channel when only one is masked — get the
 * (l + r)/2 sum, so no routed output is ever dropped. A mono source has l == r,
 * so a single masked channel gets l, two get (l, r) == (l, l), and extras get the
 * mid == l: identical to plain mono routing. */
static void le_fx_route(float* out, int f, int ch_out, uint32_t mask, float l,
                        float r) {
  float* o = out + (size_t)f * (size_t)ch_out;
  const float mid = 0.5f * (l + r);
  int n = 0;
  for (int c = 0; c < ch_out; ++c) {
    if (mask & (1u << c)) n++;
  }
  if (n == 0) return;
  int idx = 0;
  for (int c = 0; c < ch_out; ++c) {
    if (!(mask & (1u << c))) continue;
    o[c] += (n == 1) ? mid : (idx == 0) ? l : (idx == 1) ? r : mid;
    idx++;
  }
}

/* Performance event log emission (part 3): the audited subset of LE_CMD_* that
 * affects audibility gets logged verbatim (same code, same union arm) at
 * `frame` — the elapsed-frames-since-arm value at the START of the buffer
 * currently being processed (apply_command runs once per le_engine_process
 * call, before the per-frame loop, so this is as fine-grained as a
 * ring-applied command can be tagged; see docs/design/performance-event-log-
 * format.md for why finer isn't meaningful here). Excluded, with the audit
 * rationale: LE_CMD_MEASURE_LATENCY (a device-calibration workflow, not a
 * performance action); LE_CMD_SET_RECORD_OFFSET (a calibration/config value,
 * not something changed mid-performance); LE_CMD_ARM/LE_CMD_DISARM (scheduling
 * intent only — the eventual fire is what's logged, as LE_PLOG_RECORD_START,
 * sample-accurately from inside the per-frame loop below); LE_CMD_DUB_SHADOW
 * (internal shadow-pool bookkeeping, not itself an audible change);
 * LE_CMD_PERF_ARM/LE_CMD_PERF_DISARM (meta — arming/disarming the capture
 * session isn't part of what the session captures). A command that changes
 * output but isn't logged here is a standing review-checklist item (the
 * umbrella plan). */
static void apply_command(le_engine* e, const le_command* cmd, uint64_t frame) {
  switch (cmd->code) {
    case LE_CMD_MEASURE_LATENCY: {
      const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
      e->lat_active = 1;
      /* Emit for ~10 ms so the pulse survives D/A → cable → A/D. */
      e->lat_emit_remaining = sr / LE_LATENCY_PULSE_DIV;
      e->lat_buf_pos = 0; /* start a fresh capture window */
      store_i32(&e->a_latency_state, LE_LATENCY_MEASURING);
      /* A loopback measurement requires a physical out->in cable, which forms a
       * feedback loop with input monitoring (out -> cable -> in -> monitor ->
       * out). No explicit monitor suppression is needed — and we must NOT touch
       * m->a_enabled here: while measuring, the pulse path takes over the output
       * and `continue`s each frame (see le_engine_process), bypassing
       * mix_monitors_frame entirely, so no monitored input ever reaches the
       * output during the pulse. Snapshotting + zeroing a_enabled here (and
       * restoring it at completion) used to revert a saved-monitor enable that
       * the launch restore applies asynchronously mid-measurement, leaving that
       * input silent until a manual toggle. lat_active alone is the gate. */
      break;
    }
    case LE_CMD_RECORD:
      le_plog_push(e, frame, *cmd);
      if (valid_channel(e, cmd->arg_i)) {
        e->tracks[cmd->arg_i].pending_record = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
      handle_record(e, cmd->arg_i, frame);
      break;
    case LE_CMD_ARM:
      if (valid_channel(e, cmd->arg_i)) {
        /* arg_f carries the trigger: 0 = loop-top (quantize), 1 = input level
         * (sound-activated auto-record). */
        e->tracks[cmd->arg_i].pending_record = 1;
        e->tracks[cmd->arg_i].pending_trigger = cmd->arg_f != 0.0f ? 1 : 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 1);
      }
      break;
    case LE_CMD_DISARM:
      if (valid_channel(e, cmd->arg_i)) {
        e->tracks[cmd->arg_i].pending_record = 0;
        e->tracks[cmd->arg_i].pending_trigger = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
      break;
    case LE_CMD_STOP:
      le_plog_push(e, frame, *cmd);
      handle_stop(e, cmd->arg_i, frame);
      break;
    case LE_CMD_PLAY:
      le_plog_push(e, frame, *cmd);
      handle_play(e, cmd->arg_i);
      break;
    case LE_CMD_CLEAR:
      le_plog_push(e, frame, *cmd);
      handle_clear(e, cmd->arg_i);
      break;
    case LE_CMD_DUB_SHADOW: {
      /* A shadow slot for per-pass layer capture (buffers already allocated by
       * the control thread; visible via the ring's release/acquire). Arm it
       * directly when no pass is mid-flight; otherwise park it as the spare a
       * boundary rotation will pick up — arming mid-pass would tear coverage. */
      const int32_t ch = cmd->lanei.channel;
      const int32_t slot = cmd->lanei.value;
      if (!valid_channel(e, ch) || slot < 0 || slot >= LE_POOL_SLOTS) break;
      le_track* t = &e->tracks[ch];
      const int mid_pass =
          (load_i32(&t->a_state) == LE_TRACK_OVERDUBBING ||
           t->od_gain > 0.0f) &&
          t->dub_phase > 0;
      if (t->dub_slot < 0 && !mid_pass && !t->dub_draining) {
        t->dub_slot = slot;
        t->dub_count = -1;
      } else if (t->dub_spare < 0) {
        t->dub_spare = slot;
      }
      break;
    }
    case LE_CMD_UNDO_TO_EMPTY: {
      /* Undo past the base layer: the track reads as content-less (the control
       * thread keeps its live slot on the redo stack for resurrection) while
       * the master grid deliberately survives — redo needs it; a full reset
       * stays Clear's job (handle_clear's all-empty check). */
      if (!valid_channel(e, cmd->arg_i)) break;
      le_track* t = &e->tracks[cmd->arg_i];
      t->record_pos = 0;
      t->start_iter = 0;
      t->pending_record = 0;
      t->od_gain = 0.0f;
      t->xfade_capture = 0;
      store_i32(&t->a_pending, 0);
      store_i32(&t->a_state, LE_TRACK_EMPTY);
      le_track_set_len(t, 0);
      store_i32(&t->a_multiple, 1);
      /* The to-EMPTY edge case of undo (LE_PLOG_UNDO, not a raw copy of this
       * command — every undo path, common in-track swap or this one, logs
       * the same semantic code so a downstream consumer never needs to know
       * which internal path fired). */
      le_plog_push(e, frame,
                  (le_command){.code = LE_PLOG_UNDO, .arg_i = cmd->arg_i});
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_REDO_FROM_EMPTY: {
      /* Reinstate an undone-to-empty track: the control thread already swapped
       * a_live back to the base content; restore length/multiple/state here.
       * start_iter = 0 keeps the COMMIT_SESSION segment convention. */
      const int32_t ch = cmd->lanei.channel;
      const int32_t len = cmd->lanei.value;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      if (load_i32(&t->a_state) == LE_TRACK_EMPTY && len > 0) {
        /* The restored loop may differ in length from whatever the leftover
         * armed shadows were sized for — drop them (control reclaimed). */
        le_dub_drop_armed(t);
        const int32_t base = e->clock.length > 0 ? e->clock.length : len;
        int32_t k = len / base;
        if (k < 1) k = 1;
        le_track_set_len(t, len);
        store_i32(&t->a_multiple, k);
        t->start_iter = 0;
        store_i32(&t->a_state, LE_TRACK_PLAYING);
        /* The from-EMPTY edge case of redo (LE_PLOG_REDO — see the UNDO_TO_
         * EMPTY case above for why every redo path logs the same code). */
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_REDO, .arg_i = ch});
      }
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    /* Undo/redo swaps are handled on the control thread (le_engine_undo/redo),
     * not via the command ring; only the state flips above ride it. */
    case LE_CMD_SET_VOLUME: {
      if (!valid_channel(e, cmd->arg_i)) break;
      le_plog_push(e, frame, *cmd);
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      /* Track-addressed volume maps to lane 0 (backward compatibility). */
      store_f32(&e->tracks[cmd->arg_i].lanes[0].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MUTE:
      if (valid_channel(e, cmd->arg_i)) {
        le_plog_push(e, frame, *cmd);
        store_i32(&e->tracks[cmd->arg_i].lanes[0].a_muted,
                  cmd->arg_f != 0.0f ? 1 : 0);
      }
      break;
    case LE_CMD_SET_MASTER_GAIN: {
      le_plog_push(e, frame, *cmd);
      float g = cmd->arg_f;
      if (g < 0.0f) g = 0.0f;
      if (g > 1.0f) g = 1.0f;
      store_f32(&e->a_master_gain_bits, g);
      break;
    }
    case LE_CMD_SET_RECORD_OFFSET: {
      const int32_t frames = cmd->arg_i > 0 ? cmd->arg_i : 0;
      store_i32(&e->a_record_offset, frames);
      /* An explicitly set offset (a restored measurement, or a manual override)
       * is a known round-trip, so publish it as a completed measurement — the
       * UI then shows the loaded latency instead of "not measured". */
      if (frames > 0) {
        const int32_t osr = e->sample_rate > 0 ? e->sample_rate : 48000;
        atomic_store_explicit(
            &e->a_latency_ms_bits,
            f64_to_bits((double)frames * 1000.0 / (double)osr),
            memory_order_relaxed);
        store_i32(&e->a_latency_state, LE_LATENCY_DONE);
      }
      break;
    }
    /* Track + 32-bit mask, carried in the typed `trackmask` union arm. */
    case LE_CMD_SET_INPUT_MASK: {
      const int32_t ch = cmd->trackmask.channel;
      if (!valid_channel(e, ch)) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->in_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->in_channels) - 1u);
      /* A lane can never record from a loopback-excluded channel. The legacy
       * track input mask collapses to lane 0's single input channel: the lowest
       * valid, non-excluded bit (or -1 when none remain). */
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      const uint32_t m = cmd->trackmask.mask & valid & ~excluded;
      store_i32(&e->tracks[ch].lanes[0].a_input_channel, le_mask_to_channel(m));
      break;
    }
    case LE_CMD_SET_OUTPUT_MASK: {
      const int32_t ch = cmd->trackmask.channel;
      if (!valid_channel(e, ch)) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[0].a_output_mask,
                            cmd->trackmask.mask & valid, memory_order_relaxed);
      break;
    }
    /* FX type / count, addressed by (channel, lane) in the typed `fx` / `fxcount`
     * union arms. */
    case LE_CMD_SET_LANE_FX: {
      const int32_t ch = cmd->fx.channel;
      const int32_t lane = cmd->fx.lane;
      const int32_t index = cmd->fx.index;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES ||
          index < 0 || index >= LE_FX_MAX) {
        break;
      }
      le_plog_push(e, frame, *cmd);
      le_lane* ln = &e->tracks[ch].lanes[lane];
      store_i32(&ln->a_fx_type[index], cmd->fx.type);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      le_fx_entry_reset(&ln->fx, index);
      break;
    }
    case LE_CMD_SET_LANE_FX_COUNT: {
      const int32_t ch = cmd->fxcount.channel;
      const int32_t lane = cmd->fxcount.lane;
      int32_t count = cmd->fxcount.count;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->tracks[ch].lanes[lane].a_fx_count, count);
      break;
    }
    /* ---- multi-lane routing commands ----
     * Each addresses its lane by (channel, lane): SET_LANE_INPUT/OUTPUT carry an
     * int payload (input channel / 32-bit mask) in the `lanei` arm;
     * SET_LANE_VOLUME/MUTE carry a float in the `lanef` arm. */
    case LE_CMD_SET_LANE_INPUT: {
      const int32_t ch = cmd->lanei.channel;
      const int32_t lane = cmd->lanei.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      int32_t in_ch = cmd->lanei.value;
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* Reject an out-of-range or loopback-excluded channel by recording
       * nothing, so a lane never captures our own output. */
      if (in_ch < 0 || in_ch >= e->in_channels ||
          (excluded & (1u << in_ch))) {
        in_ch = -1;
      }
      store_i32(&e->tracks[ch].lanes[lane].a_input_channel, in_ch);
      break;
    }
    case LE_CMD_SET_LANE_OUTPUT: {
      const int32_t ch = cmd->lanei.channel;
      const int32_t lane = cmd->lanei.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[lane].a_output_mask,
                            (uint32_t)cmd->lanei.value & valid,
                            memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_LANE_VOLUME: {
      const int32_t ch = cmd->lanef.channel;
      const int32_t lane = cmd->lanef.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      float v = cmd->lanef.value;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      store_f32(&e->tracks[ch].lanes[lane].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_LANE_MUTE: {
      const int32_t ch = cmd->lanef.channel;
      const int32_t lane = cmd->lanef.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->tracks[ch].lanes[lane].a_muted,
                cmd->lanef.value != 0.0f ? 1 : 0);
      break;
    }
    /* ---- per-input live monitor ----
     * SET_MONITOR_INPUT carries the input index + enabled bit in the generic
     * { arg_i, arg_f } arm (input-level gate only). The per-lane monitor commands
     * mirror the track lane commands and reuse the same typed arms (fx / fxcount /
     * lanei / lanef); their `channel` field holds the input index. */
    case LE_CMD_SET_MONITOR_INPUT: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* A loopback-excluded input is never monitored (it carries our output). */
      const int on = (excluded & (1u << input)) ? 0 : (cmd->arg_f != 0.0f);
      store_i32(&e->monitors[input].a_enabled, on);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX: {
      const int32_t input = cmd->fx.channel; /* `channel` holds the input index */
      const int32_t index = cmd->fx.index;
      if (input < 0 || input >= LE_MAX_INPUTS || index < 0 ||
          index >= LE_FX_MAX) {
        break;
      }
      le_plog_push(e, frame, *cmd);
      le_monitor_input* m = &e->monitors[input];
      store_i32(&m->a_fx_type[index], cmd->fx.type);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      le_fx_entry_reset(&m->fx, index);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX_COUNT: {
      const int32_t input = cmd->fxcount.channel;
      int32_t count = cmd->fxcount.count;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->monitors[input].a_fx_count, count);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_OUTPUT: {
      const int32_t input = cmd->trackmask.channel;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->monitors[input].a_output_mask,
                            cmd->trackmask.mask & valid, memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_VOLUME: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      store_f32(&e->monitors[input].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_MUTE: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->monitors[input].a_muted, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    }
    case LE_CMD_SET_OUTPUT_ENABLED: {
      const int32_t output = cmd->arg_i;
      if (output < 0 || output >= LE_MAX_CHANNELS) break;
      le_plog_push(e, frame, *cmd);
      /* Structural gate: set/clear the output's bit. Stored masks are untouched
       * (D6), so re-enabling restores the routing. A bit for an output beyond the
       * device channel count is stored but never sounded (the mix iterates only
       * [0, ch_out)). */
      uint32_t mask = atomic_load_explicit(&e->a_output_enabled_mask,
                                           memory_order_relaxed);
      if (cmd->arg_f != 0.0f) {
        mask |= (1u << output);
      } else {
        mask &= ~(1u << output);
      }
      atomic_store_explicit(&e->a_output_enabled_mask, mask,
                            memory_order_relaxed);
      break;
    }
    /* Performance-recording capture: zero-payload — the control thread already
     * published the ring set + frozen config directly into e->perf (see
     * loopy_engine_api.h's LE_CMD_PERF_ARM doc) before pushing this command,
     * so applying it is just flipping the audio-thread-local mirror plus the
     * atomic the snapshot reads. */
    case LE_CMD_PERF_ARM:
      e->perf.armed = 1;
      atomic_store_explicit(&e->a_perf_armed, 1, memory_order_release);
      break;
    case LE_CMD_PERF_DISARM:
      /* Stop touching the rings for good before le_perf_disarm's quiescent
       * wait starts counting buffer boundaries. */
      e->perf.armed = 0;
      atomic_store_explicit(&e->a_perf_armed, 0, memory_order_release);
      break;
    case LE_CMD_COMMIT_SESSION: {
      const int32_t base = cmd->arg_i;
      if (base <= 0) break;
      /* Establish the master loop and start every imported track (EMPTY with a
       * loaded length) at its whole-loop multiple. The PCM and per-track length
       * were written by le_engine_import_track before this command was posted,
       * so they are visible here (the ring publishes them release/acquire).
       * This IS the "loop length locked" transport fact for the import path
       * (the other call site is finalize_master, for the live-record path) —
       * logged as that semantic fact, not a redundant raw copy of this
       * command, so a downstream consumer never needs to know which path
       * established the length. */
      le_plog_push(
          e, frame,
          (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED, .arg_i = base});
      le_loop_clock_set_length(&e->clock, base);
      e->loop_iteration = 0;
      store_i32(&e->a_master_len, base);
      for (int32_t t = 0; t < e->track_count; ++t) {
        le_track* tr = &e->tracks[t];
        if (load_i32(&tr->a_state) != LE_TRACK_EMPTY) continue;
        const int32_t len = load_i32(&tr->lanes[0].a_len);
        if (len <= 0) continue;
        int32_t k = len / base;
        if (k < 1) k = 1;
        store_i32(&tr->a_multiple, k);
        tr->start_iter = 0;
        store_i32(&tr->a_state, LE_TRACK_PLAYING);
      }
      break;
    }
    default:
      break;
  }
}

/* Resolves a captured latency measurement: cross-correlates the input-magnitude
 * envelope (lat_buf) with the emitted pulse — a length-M boxcar — via a sliding
 * sum, and publishes the peak lag as the round-trip record offset. Integrating
 * over the whole pulse locks onto the sustained echo and rejects the brief
 * crosstalk/noise a first-over-threshold test mis-locked onto. Audio-thread,
 * one-shot at end of capture; bounded (<= lat_buf_cap iterations). */
static void le_latency_resolve(le_engine* e, int sr) {
  const int32_t m = sr / LE_LATENCY_PULSE_DIV; /* pulse length in frames */
  const int32_t n = e->lat_buf_pos;            /* frames captured */
  if (e->lat_buf == NULL || n <= m) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  double window = 0.0;
  for (int32_t i = 0; i < m; ++i) window += e->lat_buf[i];
  double best = window;
  double total = window;
  int32_t best_lag = 0;
  int32_t count = 1;
  for (int32_t lag = 1; lag + m <= n; ++lag) {
    window += e->lat_buf[lag + m - 1] - e->lat_buf[lag - 1];
    total += window;
    ++count;
    if (window > best) {
      best = window;
      best_lag = lag;
    }
  }
  const double avg = total / (double)count;
  /* The echo's correlation peak must stand clearly above the baseline — a
   * level-independent test that works for weak loopback levels; the tiny
   * absolute floor rejects pure silence. */
  if (best < (double)LE_LATENCY_PEAK_RATIO * avg || best / (double)m < 1e-4) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  store_i32(&e->a_record_offset, best_lag);
  atomic_store_explicit(&e->a_latency_ms_bits,
                        f64_to_bits((double)best_lag * 1000.0 / (double)sr),
                        memory_order_relaxed);
  store_i32(&e->a_latency_state, LE_LATENCY_DONE);
}

/* ---- per-frame steps of le_engine_process ----
 *
 * Each is `static inline` so the compiler folds it back into the per-frame loop
 * with no call overhead — the decomposition is for readability and unit-testing
 * (engine_internal.h can expose thin wrappers), not a structural change to the
 * hot path. They run in the order called in le_engine_process: the additive mix
 * is already in `out[f*ch_out + c]` when master_bus_frame runs. */

/* Master bus for one output frame: global gain, then the feed-forward peak
 * limiter (instant attack / smooth release, bit-transparent below the ceiling),
 * then output metering. Accumulates *out_sumsq and tracks *frame_out_peak (both
 * start at the caller's per-block / per-frame seed). */
static inline void master_bus_frame(le_engine* e, float* out, uint32_t f,
                                    int ch_out, float master_gain, int limiter_on,
                                    float limiter_ceiling, float lim_release,
                                    float* out_sumsq, float* frame_out_peak) {
  /* Apply the global master gain post-mix, before metering and the loop-viz
   * tap, so meters and the waveform reflect what the listener actually hears.
   * The latency-calibration pulse path bypasses this (it `continue`s the frame),
   * keeping the measurement tone at its fixed amplitude. */
  if (master_gain != 1.0f) {
    for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] *= master_gain;
  }

  /* Master peak limiter (feed-forward, no lookahead): find this frame's peak,
   * compute the gain that would pin it to the ceiling, and apply it. Instant
   * attack — if the needed gain is below the current one, clamp down this very
   * frame so nothing exceeds the ceiling (no overshoot); smooth release back
   * toward unity. Below the ceiling the gain rests at 1.0, so the path is
   * bit-transparent when nothing is clipping. */
  if (limiter_on) {
    float peak = 0.0f;
    for (int c = 0; c < ch_out; ++c) {
      const float a = fabsf(out[f * ch_out + c]);
      if (a > peak) peak = a;
    }
    float target = 1.0f;
    if (peak > limiter_ceiling && peak > 0.0f) target = limiter_ceiling / peak;
    if (target < e->lim_gain) {
      e->lim_gain = target; /* instant attack: no sample over the ceiling */
    } else {
      e->lim_gain += (target - e->lim_gain) * lim_release;
    }
    if (e->lim_gain != 1.0f) {
      for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] *= e->lim_gain;
    }
  }

  /* Output metering for this frame. */
  for (int c = 0; c < ch_out; ++c) {
    const float sample = out[f * ch_out + c];
    *out_sumsq += sample * sample;
    const float sa = fabsf(sample);
    if (sa > *frame_out_peak) *frame_out_peak = sa;
  }
}

/* Performance-recording capture taps (le_perf_arm/disarm, loopy_engine_api.h):
 * copy the post-limiter master output and each captured monitor input's
 * post-FX signal into their pre-published rings. Both are no-ops when not
 * armed (`e->perf.armed`, the audio-thread-local mirror of a_perf_armed);
 * neither ever blocks or allocates — a full ring just drops the frame and
 * bumps the shared overrun atomic. */

/* Tap for the master bus: [master_out_ch] selects the first enabled output
 * pair frozen at arm (mono when only one channel was captured). */
static inline void perf_tap_master_frame(le_engine* e, const float* out,
                                         uint32_t f, int ch_out) {
  if (!e->perf.armed) return;
  float s[2];
  const int32_t ch0 = e->perf.master_out_ch[0];
  s[0] = (ch0 >= 0 && ch0 < ch_out) ? out[f * (uint32_t)ch_out + (uint32_t)ch0]
                                    : 0.0f;
  if (e->perf.master_channels == 2) {
    const int32_t ch1 = e->perf.master_out_ch[1];
    s[1] = (ch1 >= 0 && ch1 < ch_out)
               ? out[f * (uint32_t)ch_out + (uint32_t)ch1]
               : 0.0f;
  }
  if (!le_audio_ring_push_frame(&e->perf.master_ring, s,
                                (size_t)e->perf.master_channels)) {
    atomic_fetch_add_explicit(&e->a_perf_overruns, 1u, memory_order_relaxed);
  }
}

/* Tap for one captured monitor input: always one push per frame while armed
 * and captured — including a silent (0, 0) frame when the input is currently
 * off/muted — so the ring stays frame-aligned with the master ring (the
 * eventual DAW export needs every captured track on the same timeline, not a
 * sparse packing of only-when-audible samples). */
static inline void perf_tap_monitor_frame(le_engine* e, int input, float l,
                                          float r) {
  const float s[2] = {l, r};
  if (!le_audio_ring_push_frame(&e->perf.monitor_ring[input], s, 2)) {
    atomic_fetch_add_explicit(&e->a_perf_overruns, 1u, memory_order_relaxed);
  }
}

/* Loop visualization tap for one frame: bucket the output (and per-track) peaks
 * by loop position. When the playhead crosses into a new bucket, publish the
 * peaks accumulated for the bucket it left, then start the new one — so each
 * bucket holds the most recent pass over that slice of the loop. RT-safe
 * (atomics only). Only meaningful once a master loop exists. */
static inline void viz_tap_frame(le_engine* e, int tc, int32_t pos,
                                 float frame_out_peak,
                                 const float* frame_trk_peak) {
  if (e->clock.length > 0) {
    int32_t bucket = (int32_t)((int64_t)pos * LE_VIZ_POINTS / e->clock.length);
    if (bucket >= LE_VIZ_POINTS) bucket = LE_VIZ_POINTS - 1;
    if (bucket != e->loop_viz_bucket) {
      const int32_t prev = e->loop_viz_bucket;
      if (prev >= 0 && prev < LE_VIZ_POINTS) {
        store_f32(&e->a_loop_viz[prev], e->loop_viz_accum);
        for (int t = 0; t < tc; ++t) {
          store_f32(&e->a_track_viz[t][prev], e->track_viz_accum[t]);
        }
      }
      e->loop_viz_bucket = bucket;
      e->loop_viz_accum = 0.0f;
      for (int t = 0; t < tc; ++t) e->track_viz_accum[t] = 0.0f;
    }
    if (frame_out_peak > e->loop_viz_accum) e->loop_viz_accum = frame_out_peak;
    for (int t = 0; t < tc; ++t) {
      if (frame_trk_peak[t] > e->track_viz_accum[t]) {
        e->track_viz_accum[t] = frame_trk_peak[t];
      }
    }
  }
}

/* Advances the record heads and then the master transport for one frame. An
 * auto-multiple track grows freely (rounded up only on stop); a fixed-multiple
 * track auto-finalizes after exactly K base loops, and a track recorded over an
 * existing master continues into overdub when it auto-finalizes. When the loop
 * crosses its top, fires the loop-top (quantize) pending records on the grid;
 * with nothing active, holds the transport at the top. [st] is the frame's
 * per-track state snapshot. */
static inline void advance_transport_frame(le_engine* e, int tc,
                                           const int32_t* st, uint64_t frame) {
  for (int t = 0; t < tc; ++t) {
    if (st[t] != LE_TRACK_RECORDING) continue;
    le_track* tr = &e->tracks[t];
    if (e->clock.length == 0) {
      tr->record_pos++;
      if (tr->xfade_capture > 0) {
        /* Deferred seam crossfade: keep capturing the overlap past the loop
         * point, then fold it into the head and finalize at the intended
         * length. The buffer room was checked when the deferral was armed. */
        if (--tr->xfade_capture == 0) finalize_master_xfade(e, tr, frame);
      } else if (tr->record_pos >= e->max_loop_frames) {
        finalize_master(e, tr, LE_TRACK_PLAYING, frame);
      }
    } else {
      tr->record_pos++;
      const int32_t eff = le_effective_multiple(e, t);
      const int32_t base = e->clock.length;
      if (eff >= 1 && tr->record_pos - tr->record_start >= eff * base) {
        finalize_new_track(e, tr, LE_TRACK_OVERDUBBING, frame);
      } else if (tr->record_pos >= e->max_loop_frames) {
        finalize_new_track(e, tr, LE_TRACK_OVERDUBBING, frame);
      }
    }
  }
  if (e->clock.length > 0) {
    int any_active = 0;
    for (int t = 0; t < tc; ++t) {
      if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_RECORDING ||
          st[t] == LE_TRACK_OVERDUBBING) {
        any_active = 1;
        break;
      }
    }
    if (any_active) {
      if (le_loop_clock_tick(&e->clock)) {
        e->loop_iteration++;
        /* The loop just crossed its top (position == 0). Fire loop-top
         * (quantize) pending records here so a deferred start/finalize/overdub
         * lands exactly on the grid. Signal-triggered arms fire above, not
         * here. handle_record enforces one-capturer hand-off. */
        for (int qt = 0; qt < tc; ++qt) {
          if (e->tracks[qt].pending_record &&
              e->tracks[qt].pending_trigger == 0) {
            e->tracks[qt].pending_record = 0;
            store_i32(&e->tracks[qt].a_pending, 0);
            handle_record(e, qt, frame);
          }
        }
      }
    } else {
      /* Nothing is playing or recording: hold the transport at the top so the
       * next play starts from the beginning rather than looping in silence.
       * Resetting each track's start_iter keeps multi-loop tracks aligned to
       * their first segment on the next play. */
      e->clock.position = 0;
      e->loop_iteration = 0;
      for (int t = 0; t < tc; ++t) e->tracks[t].start_iter = 0;
    }
  }
}

/* ---- per-block setup snapshots ----
 *
 * The per-lane / per-monitor effect chains are snapshotted ONCE per buffer: the
 * control thread applies fx edits at buffer granularity, so the audio thread
 * reads each lane's published type/count/params once here and works off the
 * stack copy for the whole block (no per-frame atomic re-reads). has_fx gates the
 * chain so a lane with no effects skips it. `static inline` so these fold into
 * le_engine_process; out-params are the caller's stack arrays. */

/* Snapshots every active track lane's effect chain into the caller's arrays. */
static inline void snapshot_track_fx(
    le_engine* e, int tc, const int32_t* lane_n,
    int32_t fx_count[][LE_MAX_LANES], int32_t fx_type[][LE_MAX_LANES][LE_FX_MAX],
    float fx_params[][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS],
    int has_fx[][LE_MAX_LANES]) {
  for (int t = 0; t < tc; ++t) {
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      has_fx[t][l] = 0;
      int32_t n = load_i32(&ln->a_fx_count);
      if (n < 0) n = 0;
      if (n > LE_FX_MAX) n = LE_FX_MAX;
      fx_count[t][l] = n;
      for (int s = 0; s < n; ++s) {
        const int32_t ty = load_i32(&ln->a_fx_type[s]);
        fx_type[t][l][s] = ty;
        if (ty != LE_FX_NONE) has_fx[t][l] = 1;
        for (int p = 0; p < LE_FX_PARAMS; ++p) {
          fx_params[t][l][s][p] = load_f32(&ln->a_fx_param[s][p]);
        }
      }
    }
  }
}

/* Snapshots each hardware input's single live-monitor chain: the input-level
 * enable (gated by loopback exclusion) plus the chain's output mask / volume /
 * mute / effects — the monitor mirror of snapshot_track_fx, one chain per input. */
static inline void snapshot_monitor_fx(
    le_engine* e, int ch_in, uint32_t excluded, int* mon_on, uint32_t* mon_out,
    float* mon_vol, int* mon_mut, int32_t* mon_fx_count,
    int32_t mon_fx_type[][LE_FX_MAX],
    float mon_fx_params[][LE_FX_MAX][LE_FX_PARAMS], int* mon_has_fx) {
  for (int c = 0; c < ch_in && c < LE_MAX_INPUTS; ++c) {
    le_monitor_input* m = &e->monitors[c];
    mon_on[c] = load_i32(&m->a_enabled) && !(excluded & (1u << c));
    mon_out[c] = atomic_load_explicit(&m->a_output_mask, memory_order_relaxed);
    mon_vol[c] = load_f32(&m->a_vol_bits);
    mon_mut[c] = load_i32(&m->a_muted);
    mon_has_fx[c] = 0;
    int32_t n = load_i32(&m->a_fx_count);
    if (n < 0) n = 0;
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    mon_fx_count[c] = n;
    for (int s = 0; s < n; ++s) {
      const int32_t ty = load_i32(&m->a_fx_type[s]);
      mon_fx_type[c][s] = ty;
      if (ty != LE_FX_NONE) mon_has_fx[c] = 1;
      for (int p = 0; p < LE_FX_PARAMS; ++p) {
        mon_fx_params[c][s][p] = load_f32(&m->a_fx_param[s][p]);
      }
    }
  }
}

/* ---- per-frame core steps ----
 *
 * The fused heart of the per-frame loop, lifted into named steps. Each is
 * `static inline` and takes the per-block snapshot arrays (filled by the setup
 * steps above) plus the per-frame index, so the moved code is byte-identical to
 * the pre-S2 inline body — only the surrounding declarations became parameters. */

/* Per-frame input stage: input metering, sound-activated (input-level) record
 * firing, and the loopback latency harness. Returns 1 when the latency harness
 * owns this frame (it has written `out`; the caller must skip the rest of the
 * frame), else 0. */
static inline int process_input_frame(le_engine* e, const float* in, float* out,
                                      uint32_t f, int ch_in, int ch_out, int tc,
                                      int sr, uint32_t excluded, float* in_sumsq,
                                      float* in_peak, float* out_sumsq,
                                      uint64_t perf_frame_base) {
  float frame_mag = 0.0f; /* max |input| over real (non-loopback) channels */
  float loop_mag = 0.0f;  /* max |input| over loopback channels (latency tap) */
  for (int c = 0; c < ch_in; ++c) {
    const float s = in ? in[f * ch_in + c] : 0.0f;
    const float a = fabsf(s);
    if (excluded & (1u << c)) {
      /* Loopback channels carry our own output back; not recorded/monitored/
       * metered, but they are the round-trip path the latency harness times. */
      if (a > loop_mag) loop_mag = a;
      continue;
    }
    if (a > frame_mag) frame_mag = a;
    *in_sumsq += s * s;
  }
  if (frame_mag > *in_peak) *in_peak = frame_mag;

  /* Sound-activated recording: a track armed for the input-level trigger starts
   * the moment the input crosses the threshold. Fired here — after the input
   * magnitude is known but before st[] is sampled — so this very frame is
   * captured. */
  for (int qt = 0; qt < tc; ++qt) {
    if (e->tracks[qt].pending_record && e->tracks[qt].pending_trigger == 1 &&
        frame_mag > LE_AUTO_RECORD_THRESHOLD) {
      e->tracks[qt].pending_record = 0;
      e->tracks[qt].pending_trigger = 0;
      store_i32(&e->tracks[qt].a_pending, 0);
      handle_record(e, qt, perf_frame_base + f);
    }
  }

  /* The latency pulse returns on the loopback channels when the interface has
   * them (e.g. a Scarlett's "Loop 1/2"); otherwise (a physical cable, or a
   * routed loopback capture device) it returns on the normal inputs. */
  const float lat_mag = excluded != 0u ? loop_mag : frame_mag;

  /* Latency harness takes over the output entirely while measuring. It emits a
   * quiet ~10 ms pulse at the start of a fixed capture window, records the
   * input-magnitude envelope across that window, then cross-correlates it with
   * the pulse to find the round-trip by the correlation peak (le_latency_resolve).
   * The peak — integrated over the whole pulse — locks onto the real echo and
   * ignores the brief direct/crosstalk bleed a first-over-threshold test
   * mis-reported (especially on low-latency JACK graphs). */
  if (e->lat_active) {
    float broadcast = 0.0f;
    if (e->lat_emit_remaining > 0) {
      /* A tone burst (not a DC level): AC-coupled interface inputs high-pass a
       * constant pulse down to edge transients, leaving nothing to correlate.
       * A 1 kHz burst returns as a sustained AC signal. */
      const int32_t emitted =
          (sr / LE_LATENCY_PULSE_DIV) - e->lat_emit_remaining;
      const float phase = 2.0f * 3.14159265f * LE_LATENCY_TONE_HZ *
                          (float)emitted / (float)sr;
      broadcast = LE_LATENCY_PULSE_AMP * sinf(phase);
      e->lat_emit_remaining--;
    }
    if (e->lat_buf != NULL && e->lat_buf_pos < e->lat_buf_cap) {
      e->lat_buf[e->lat_buf_pos++] = lat_mag;
    }
    /* Resolve on the same frame the window fills (not the next): the two
     * conditions overlap on the fill frame, so this is intentionally not an
     * `else`. */
    if (e->lat_buf == NULL || e->lat_buf_pos >= e->lat_buf_cap) {
      le_latency_resolve(e, sr);
      e->lat_active = 0;
      /* No monitor enable state to restore: the measurement never touched
       * a_enabled (see the LE_CMD_MEASURE_LATENCY comment). Monitoring resumes
       * on its own now that lat_active is clear and the per-frame mix — which
       * the pulse path bypassed — runs again. */
    }
    for (int c = 0; c < ch_out; ++c) {
      out[f * ch_out + c] = broadcast;
      *out_sumsq += broadcast * broadcast;
    }
    return 1;
  }
  return 0;
}

/* Per-frame live monitoring: each enabled hardware input runs its clean live
 * sample through its single (stageless) effect chain at its volume and sums into
 * the outputs its mask selects — an empty chain routes the clean sample (the dry
 * path), an FX chain its processed signal (stereo-aware: a reverb spreads across
 * the first two masked outputs). [out_enabled] is the structural output gate,
 * intersected with the mask so a disabled output is never a target. Live and
 * independent of every track; never recorded. Effects run every frame so delay
 * tails / LFO phase stay continuous. */
static inline void mix_monitors_frame(
    le_engine* e, const float* in, float* out, uint32_t f, int ch_in, int ch_out,
    int sr, int fx_cap, uint32_t out_enabled, const int* mon_on,
    const int* mon_mut, const int* mon_has_fx, const int32_t* mon_fx_count,
    int32_t mon_fx_type[][LE_FX_MAX],
    float mon_fx_params[][LE_FX_MAX][LE_FX_PARAMS], const float* mon_vol,
    const uint32_t* mon_out) {
  if (in) {
    for (int c = 0; c < ch_in && c < LE_MAX_INPUTS; ++c) {
      const int captured =
          e->perf.armed && (e->perf.input_mask & (1u << c)) != 0;
      if (!mon_on[c] || mon_mut[c]) {
        if (captured) perf_tap_monitor_frame(e, c, 0.0f, 0.0f);
        continue;
      }
      const float clean = in[f * ch_in + c];
      float ml = clean;
      float mr = clean;
      if (mon_has_fx[c]) {
        fx_apply_chain(&e->monitors[c].fx, sr, fx_cap, &ml, &mr, mon_fx_count[c],
                       mon_fx_type[c], mon_fx_params[c]);
      }
      const float g = mon_vol[c];
      if (captured) perf_tap_monitor_frame(e, c, ml * g, mr * g);
      le_fx_route(out, f, ch_out, mon_out[c] & out_enabled, ml * g, mr * g);
    }
  }
}

/* Per-frame capture + additive playback mix: snapshots each track's per-lane
 * playback state, records / overdubs the live input into the lane buffers at the
 * latency-compensated write head, and sums every audible lane (through its
 * effect chain) into `out`. Fills [st] (the per-track state snapshot the
 * transport advance reads) and accumulates [frame_trk_peak] (per-track) and the
 * [lane_sumsq] / [lane_peak] metering. [pos] is the playhead (read by the caller
 * before the transport advances). */
static inline void mix_tracks_frame(
    le_engine* e, const float* in, float* out, uint32_t f, int ch_in,
    int ch_out, int tc, int sr, int fx_cap, uint32_t excluded,
    uint32_t out_enabled, float overdub_fb,
    float od_step, int32_t od_fade_frames, int32_t pos, const int32_t* lane_n,
    int has_fx[][LE_MAX_LANES], int32_t fx_count[][LE_MAX_LANES],
    int32_t fx_type[][LE_MAX_LANES][LE_FX_MAX],
    float fx_params[][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS],
    float lane_sumsq[][LE_MAX_LANES], float lane_peak[][LE_MAX_LANES],
    int32_t* st, float* frame_trk_peak, uint64_t perf_frame_base) {
  /* Snapshot per-lane playback state once per frame. The track state can flip
   * only between blocks; re-reading per frame is cheap and keeps undo's
   * control-thread a_live swap visible at frame granularity. */
  float* buf[LE_MAX_TRACKS][LE_MAX_LANES];
  float vol[LE_MAX_TRACKS][LE_MAX_LANES];
  int mut[LE_MAX_TRACKS][LE_MAX_LANES];
  int32_t lane_in[LE_MAX_TRACKS][LE_MAX_LANES];
  uint32_t out_mask[LE_MAX_TRACKS][LE_MAX_LANES];
  for (int t = 0; t < tc; ++t) {
    st[t] = load_i32(&e->tracks[t].a_state);
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      buf[t][l] = ln->pool[load_i32(&ln->a_live)];
      vol[t][l] = load_f32(&ln->a_vol_bits);
      mut[t][l] = load_i32(&ln->a_muted);
      lane_in[t][l] = load_i32(&ln->a_input_channel);
      out_mask[t][l] =
          atomic_load_explicit(&ln->a_output_mask, memory_order_relaxed);
    }
  }
  /* Latency compensation: captured input is recorded this many frames earlier so
   * it aligns with what the player heard. Monitoring stays live (it is no longer
   * folded into the loop buffer at the playhead). */
  const int32_t offset = load_i32(&e->a_record_offset);

  /* Per-track read base for this frame: a track of multiple k plays its k-th
   * base-loop segment, cycling relative to where its recording began. k == 1
   * (the common case) collapses to the master position. */
  int32_t seg_base[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    if (e->clock.length > 0) {
      int32_t k = load_i32(&e->tracks[t].a_multiple);
      if (k < 1) k = 1;
      const uint64_t seg =
          (e->loop_iteration - e->tracks[t].start_iter) % (uint64_t)k;
      seg_base[t] = (int32_t)seg * e->clock.length;
    } else {
      seg_base[t] = 0;
    }
  }

  /* The looper mix is additive: clear this output frame, then sum every active
   * lane's mono contribution into the output channels its mask selects. */
  for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] = 0.0f;

  /* The punch fade only engages once the loop is long enough to host a full
   * fade-in plus fade-out tail with steady audio between them; shorter loops
   * (sub-20 ms — not musically a loop) snap straight to the target, preserving
   * the exact unfaded write the deterministic tests rely on. */
  const int od_fade_on = e->clock.length >= 2 * od_fade_frames;
  for (int t = 0; t < tc; ++t) {
    /* Advance this track's overdub punch envelope once per frame (shared by
     * every lane): ramp toward 1 while OVERDUBBING, toward 0 otherwise. When a
     * punch-out flips the state to PLAYING the envelope is still > 0, so the
     * write below keeps layering a tapering tail until it reaches 0 — a
     * click-free punch-out (the player's still-live input fades out, rather than
     * the loop cutting at the punch point). */
    const float od_target = (st[t] == LE_TRACK_OVERDUBBING) ? 1.0f : 0.0f;
    float od_gain = e->tracks[t].od_gain;
    if (!od_fade_on) {
      od_gain = od_target;
    } else if (od_gain < od_target) {
      od_gain += od_step;
      if (od_gain > od_target) od_gain = od_target;
    } else if (od_gain > od_target) {
      od_gain -= od_step;
      if (od_gain < od_target) od_gain = od_target;
    }
    e->tracks[t].od_gain = od_gain;

    /* Per-pass layer capture for this frame, shared by every lane: the write
     * position uses the session-latched offset (a mid-dub offset change must
     * not tear the trajectory), and `backing` says whether the armed shadow is
     * still collecting pre-values (it stops once complete — frozen — or while
     * an old pass drains). The first backed-up write latches the pass's start
     * point for the drain walk. */
    le_track* tr = &e->tracks[t];

    /* Recording write head for this frame, shared by every lane (or -1 when
     * nothing may be written). The defining track writes linearly. A new
     * track over the master is phase-locked (record_pos == segment*base +
     * position) and latency-compensated by dropping the first `offset`
     * frames so it aligns with what the player heard. With a fixed multiple
     * the final length (K*base) is already known, so the head wraps into it:
     * audio captured past the loop top lands at its heard phase instead of
     * beyond the final length, where finalize would silently orphan it (a
     * mid-loop take used to lose everything recorded after the top). Auto
     * (K == 0) stays linear — finalize rounds the length up instead, so
     * nothing is dropped. A negative head (capture inside the latency window
     * of a press near the top) stays dropped: the pre-press slice is silent
     * by design. */
    int32_t rec_w = -1;
    if (st[t] == LE_TRACK_RECORDING) {
      if (e->clock.length == 0) {
        rec_w = tr->record_pos;
      } else {
        rec_w = tr->record_pos - offset;
        const int32_t k = le_effective_multiple(e, t);
        const int32_t known_len = k >= 1 ? k * e->clock.length : 0;
        if (known_len > 0 && rec_w >= known_len) rec_w %= known_len;
      }
      if (rec_w >= e->max_loop_frames) rec_w = -1;
    }

    const int dub_writes =
        (st[t] == LE_TRACK_OVERDUBBING || st[t] == LE_TRACK_PLAYING) &&
        od_gain > 0.0f && e->clock.length > 0;
    int32_t wdub = 0;
    int backing = 0;
    if (dub_writes) {
      wdub = seg_base[t] + comp_pos(pos, tr->dub_offset, e->clock.length);
      backing = tr->dub_slot >= 0 && !tr->dub_draining && tr->dub_len > 0 &&
                tr->dub_count < tr->dub_len;
      if (backing && tr->dub_count < 0) {
        tr->dub_count = 0;
        tr->dub_start_vpos = pos;
        tr->dub_start_vseg = seg_base[t] / e->clock.length;
      }
    }

    for (int l = 0; l < lane_n[t]; ++l) {
      /* Clean single-input capture: a lane records exactly its assigned hardware
       * input — never an average of several — or silence when it has no input,
       * an out-of-range/loopback-excluded channel, or no allocated buffer.
       * Sibling lanes are never merged. */
      const int32_t ic = lane_in[t][l];
      float insample = 0.0f;
      if (in && ic >= 0 && ic < ch_in && !(excluded & (1u << ic))) {
        insample = in[f * ch_in + ic];
      }

      /* Real-time null-guard: a lane whose buffer is not yet allocated (the
       * lazy-alloc window, or a count/alloc mismatch) records and plays nothing
       * rather than dereferencing a NULL pool. */
      float* lbuf = buf[t][l];
      if (lbuf == NULL) continue;

      float loopsample = 0.0f;
      if (st[t] == LE_TRACK_RECORDING) {
        if (rec_w >= 0) lbuf[rec_w] = insample;
      } else if (st[t] == LE_TRACK_OVERDUBBING || st[t] == LE_TRACK_PLAYING) {
        /* Mix the existing loop (read before write). Layer the live input at the
         * compensated position, scaled by the punch envelope so it ramps in on
         * punch-in and out on punch-out (od_gain keeps the write alive for the
         * fade-out tail after the state has already returned to PLAYING).
         * od_gain == 0 in steady playback, so this is a plain read. */
        loopsample = lbuf[seg_base[t] + pos];
        if (od_gain > 0.0f) {
          /* Backup-on-write: save the pre-value into the armed shadow first —
           * the incremental per-pass undo snapshot (same slot on every lane,
           * lockstep). Live stays authoritative; the shadow becomes one undo
           * layer when the pass completes (or drains after punch-out). */
          if (backing) {
            float* sb = e->tracks[t].lanes[l].pool[tr->dub_slot];
            if (sb != NULL) sb[wdub] = lbuf[wdub];
          }
          /* Feedback scales the existing content at the write head before the new
           * layer is summed in, bounding runaway buildup. fb == 1.0 (the default)
           * is the classic additive `+= insample`. */
          lbuf[wdub] = lbuf[wdub] * overdub_fb + insample * od_gain;
        }
      }

      /* The lane's mono output: its dry loop content at the lane's playback
       * volume while it sounds, silence otherwise, run through the lane's whole
       * (stageless) effects chain on its `fx` state. Effects run every frame the
       * lane has them (even on silence) so delay tails and LFO phase stay
       * continuous; the wet result is routed only while the lane is audible. */
      const int audible =
          (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
          !mut[t][l];
      float wl = audible ? loopsample * vol[t][l] : 0.0f;
      float wr = wl;
      le_lane* ln = &e->tracks[t].lanes[l];
      if (has_fx[t][l]) {
        fx_apply_chain(&ln->fx, sr, fx_cap, &wl, &wr, fx_count[t][l],
                       fx_type[t][l], fx_params[t][l]);
      }
      if (audible) {
        le_fx_route(out, f, ch_out, out_mask[t][l] & out_enabled, wl, wr);
      }

      const float la = fabsf(loopsample);
      if (la > lane_peak[t][l]) lane_peak[t][l] = la;
      if (la > frame_trk_peak[t]) frame_trk_peak[t] = la;
      lane_sumsq[t][l] += loopsample * loopsample;
    }

    /* Advance the per-pass capture once per written frame (all lanes share the
     * one write head): count tracks the shadow's coverage, phase the pass
     * boundary — where a complete shadow retires and the spare takes over. */
    if (dub_writes && tr->dub_len > 0) {
      if (backing) tr->dub_count++;
      tr->dub_phase++;
      if (tr->dub_phase >= tr->dub_len) {
        tr->dub_phase = 0;
        le_dub_boundary(e, tr, perf_frame_base + f);
      }
    }
  }
}

/* Test seam: drive one output frame through master_bus_frame (master gain ->
 * feed-forward limiter -> metering) with explicit params, so the limiter dynamics
 * (transparent below the ceiling, instant-attack clamp above, smooth release) can
 * be exercised in isolation. Mirrors what le_engine_process calls per frame. Not
 * part of the FFI surface. */
void le_engine_master_bus_frame_for_test(le_engine* e, float* out, uint32_t f,
                                         int ch_out, float master_gain,
                                         int limiter_on, float limiter_ceiling,
                                         float lim_release, float* out_sumsq,
                                         float* frame_out_peak) {
  master_bus_frame(e, out, f, ch_out, master_gain, limiter_on, limiter_ceiling,
                   lim_release, out_sumsq, frame_out_peak);
}

/* ---- the real-time DSP core ---- */

void le_engine_process(le_engine* e, float* output, const float* input,
                       uint32_t frames) {
  le_flush_denormals(); /* per-thread; cheap to reassert every callback */

  const int ch_in = e->in_channels > 0 ? e->in_channels : 1;
  const int ch_out = e->out_channels > 0 ? e->out_channels : 1;
  const int tc = e->track_count;
  float* out = output;
  const float* in = input;

  /* Snapshot the perf-log frame base once, before this buffer's frame count
   * is added to a_perf_frames below (see the end of this function) — every
   * command drained this call applies at the top of THIS buffer, so they all
   * share this one frame tag. Reading a_perf_frames here is safe with no
   * ordering ceremony: only this thread ever writes it. */
  const uint64_t perf_frame_base =
      atomic_load_explicit(&e->a_perf_frames, memory_order_relaxed);

  le_command cmd;
  while (le_ring_pop(&e->ring, &cmd)) apply_command(e, &cmd, perf_frame_base);

  /* Per-pass undo layer maintenance: retry parked retires and advance the
   * post-punch-out drain. Runs every call — including frames == 0 pumps (the
   * host tests' drain helper) — so a completed layer always retires. */
  le_dub_block_update(e, perf_frame_base);

  /* Global master output gain, read once per block after draining the ring so a
   * mid-block change applies from the next block (no per-frame atomic load). */
  const float master_gain = load_f32(&e->a_master_gain_bits);

  /* Master limiter + overdub feedback, read once per block (same rationale). */
  const int limiter_on = load_i32(&e->a_limiter_enabled) != 0;
  const float limiter_ceiling = load_f32(&e->a_limiter_ceiling_bits);
  const float overdub_fb = load_f32(&e->a_overdub_fb_bits);
  /* ~50 ms release toward unity once the signal drops below the ceiling. */
  float lim_release = 1.0f / (0.05f * (float)(e->sample_rate > 0
                                                  ? e->sample_rate
                                                  : 48000));
  if (lim_release > 1.0f) lim_release = 1.0f;

  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  /* Overdub punch declick: ramp the layered input in/out over ~10 ms so a punch
   * (in or out, including the instant rec/dub auto-dub) never bakes a step into
   * the loop buffer. One linear step per frame, settling in od_fade_frames. */
  int32_t od_fade_frames = sr / 100;
  if (od_fade_frames < 1) od_fade_frames = 1;
  const float od_step = 1.0f / (float)od_fade_frames;
  /* Loopback-labelled input channels are never recorded, monitored, or
   * metered (they carry our own output and would otherwise inflate the meter). */
  const uint32_t excluded =
      atomic_load_explicit(&e->a_excluded_input_mask, memory_order_relaxed);
  int active_in = 0;
  for (int c = 0; c < ch_in; ++c) {
    if (!(excluded & (1u << c))) ++active_in;
  }

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;
  /* Per-lane metering accumulators (each track's snapshot mirrors lane 0). */
  float lane_sumsq[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};
  float lane_peak[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};

  /* Active lane count per track (control-thread plain int; clamped once). */
  int32_t lane_n[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) lane_n[t] = le_lanes_active(&e->tracks[t]);

  /* Per-lane effect chains, snapshotted once per buffer (see snapshot_track_fx).
   * has_fx gates the playback pass so lanes with no effects skip the chain. */
  int32_t fx_count[LE_MAX_TRACKS][LE_MAX_LANES];
  int32_t fx_type[LE_MAX_TRACKS][LE_MAX_LANES][LE_FX_MAX];
  float fx_params[LE_MAX_TRACKS][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS];
  int has_fx[LE_MAX_TRACKS][LE_MAX_LANES];
  snapshot_track_fx(e, tc, lane_n, fx_count, fx_type, fx_params, has_fx);

  /* Per-input live monitor chain, snapshotted once per buffer (see
   * snapshot_monitor_fx). mon_on gates the whole input (loopback exclusion +
   * enable); mute/volume/output/chain drive the single chain. */
  int mon_on[LE_MAX_INPUTS] = {0};
  uint32_t mon_out[LE_MAX_INPUTS];
  float mon_vol[LE_MAX_INPUTS];
  int mon_mut[LE_MAX_INPUTS];
  int32_t mon_fx_count[LE_MAX_INPUTS];
  int32_t mon_fx_type[LE_MAX_INPUTS][LE_FX_MAX];
  float mon_fx_params[LE_MAX_INPUTS][LE_FX_MAX][LE_FX_PARAMS];
  int mon_has_fx[LE_MAX_INPUTS];
  snapshot_monitor_fx(e, ch_in, excluded, mon_on, mon_out, mon_vol, mon_mut,
                      mon_fx_count, mon_fx_type, mon_fx_params, mon_has_fx);

  /* Structural output gate, read once per block (a mid-block toggle applies from
   * the next block — RT-safe, no mid-buffer artifact). Intersected into every
   * routing mask so a disabled output is never summed into, while the stored
   * lane/monitor masks stay untouched (re-enabling restores them). */
  const uint32_t out_enabled =
      atomic_load_explicit(&e->a_output_enabled_mask, memory_order_relaxed);

  const int fx_cap = e->fx_delay_frames;

  for (uint32_t f = 0; f < frames; ++f) {
    /* Input metering + sound-activated record + latency harness. When the harness
     * owns the frame it has already written `out`, so skip the rest. */
    if (process_input_frame(e, in, out, f, ch_in, ch_out, tc, sr, excluded,
                            &in_sumsq, &in_peak, &out_sumsq, perf_frame_base)) {
      continue;
    }

    /* The playhead, read before the transport advances below; also feeds the viz
     * tap. Per-frame outputs of the mix step: st[] (states, for the transport)
     * and the per-track / per-output peaks (for the viz tap — frame_out_peak is
     * filled later by master_bus_frame). */
    const int32_t pos = e->clock.position;
    int32_t st[LE_MAX_TRACKS];
    float frame_out_peak = 0.0f;
    float frame_trk_peak[LE_MAX_TRACKS] = {0};

    /* Per-lane capture + additive playback mix (see mix_tracks_frame). */
    mix_tracks_frame(e, in, out, f, ch_in, ch_out, tc, sr, fx_cap, excluded,
                     out_enabled, overdub_fb, od_step, od_fade_frames, pos,
                     lane_n, has_fx, fx_count, fx_type, fx_params, lane_sumsq,
                     lane_peak, st, frame_trk_peak, perf_frame_base);

    /* Per-input live monitoring (see mix_monitors_frame). */
    mix_monitors_frame(e, in, out, f, ch_in, ch_out, sr, fx_cap, out_enabled,
                       mon_on, mon_mut, mon_has_fx, mon_fx_count, mon_fx_type,
                       mon_fx_params, mon_vol, mon_out);

    /* Master bus (gain + limiter + output metering), then the loop-viz tap, then
     * advance the record heads and master transport — see the static-inline step
     * definitions above le_engine_process. The latency-calibration pulse path
     * bypassed all of this via `continue` above. */
    master_bus_frame(e, out, f, ch_out, master_gain, limiter_on, limiter_ceiling,
                     lim_release, &out_sumsq, &frame_out_peak);
    perf_tap_master_frame(e, out, f, ch_out);
    viz_tap_frame(e, tc, pos, frame_out_peak, frame_trk_peak);
    advance_transport_frame(e, tc, st, perf_frame_base + f);
  }

  /* Input RMS is normalised by the active (non-loopback) channel count only. */
  const uint32_t total_in = frames * (uint32_t)active_in;
  const uint32_t total_out = frames * (uint32_t)ch_out;
  store_f32(&e->a_in_rms_bits,
            total_in ? sqrtf(in_sumsq / (float)total_in) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  store_f32(&e->a_out_rms_bits,
            total_out ? sqrtf(out_sumsq / (float)total_out) : 0.0f);
  for (int t = 0; t < tc; ++t) {
    /* Lane buffers are mono: one loop sample accumulated per frame. The shared
     * write head publishes the same growing length onto every active lane. */
    const int recording =
        load_i32(&e->tracks[t].a_state) == LE_TRACK_RECORDING;
    const int32_t rp = e->tracks[t].record_pos;
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      store_f32(&ln->a_rms_bits,
                frames ? sqrtf(lane_sumsq[t][l] / (float)frames) : 0.0f);
      store_f32(&ln->a_peak_bits, lane_peak[t][l]);
      if (recording) store_i32(&ln->a_len, rp > 0 ? rp : 0);
    }
  }
  store_i32(&e->a_master_pos, e->clock.position);
  atomic_fetch_add_explicit(&e->a_frames, (uint64_t)frames,
                            memory_order_relaxed);
  /* Elapsed-frames-since-arm, batched once per block like a_frames above
   * (armed is fixed for the whole call — commands drain before the frame
   * loop starts) rather than a per-frame atomic add. Counts every frame this
   * call processed, including ones the latency harness diverted, so it reads
   * as wall-clock frames since arm, not samples the master tap actually
   * captured. */
  if (e->perf.armed) {
    atomic_fetch_add_explicit(&e->a_perf_frames, (uint64_t)frames,
                              memory_order_relaxed);
  }
}
