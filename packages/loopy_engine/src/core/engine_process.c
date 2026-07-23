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
#include "le_midi_clock.h"   /* le_midi_clock_advance (C1 24-PPQN clock-send) */
#include "lockfree_ring.h"   /* le_command, le_ring_pop, le_ring_push */
#include "loop_clock.h"      /* le_loop_clock_* */
#include "loopy_engine_api.h"
#include "perf_log_ring.h" /* le_perf_log_ring_push, le_perf_log_code (perf event log) */
#include "tempo_grid.h"    /* le_grid_* (pure tempo/bar/subdivision math) */

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

/* Defined below; handle_record's count-in cancel-race grace window (code-
 * review fix) reuses this full "return a track to EMPTY, and if the whole
 * rig is now empty, reset the master/grid too" reset rather than hand-
 * rolling a partial one. */
static void handle_clear(le_engine* e, int32_t ch);

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

/* Whether the transport is HELD: no track is playing, recording, or
 * overdubbing, so the loop clock sits at the top (advance_transport_frame's
 * idle branch). The audio-thread twin of le_transport_active on the control
 * side — the unpark rule below fires only from this state. */
static int le_transport_held(le_engine* e) {
  for (int32_t c = 0; c < e->track_count; ++c) {
    const int32_t st = load_i32(&e->tracks[c].a_state);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_RECORDING ||
        st == LE_TRACK_OVERDUBBING) {
      return 0;
    }
  }
  return 1;
}

/* The unpark rule: starting to record or play ANYTHING while the transport is
 * held resumes the entire loop — every stopped content track returns to
 * PLAYING with its mute preserved (mute silences, park freezes; unparking
 * un-freezes). Callers latch le_transport_held BEFORE mutating state and call
 * this after the start lands. Each resume logs a synthetic LE_CMD_PLAY so a
 * performance-log replay reproduces the resumes a live listener heard. */
static void le_unpark_stopped(le_engine* e, uint64_t frame) {
  for (int32_t c = 0; c < e->track_count; ++c) {
    le_track* t = &e->tracks[c];
    if (load_i32(&t->a_state) != LE_TRACK_STOPPED) continue;
    if (load_i32(&t->lanes[0].a_len) <= 0) continue;
    store_i32(&t->a_state, LE_TRACK_PLAYING);
    le_plog_push(e, frame, (le_command){.code = LE_CMD_PLAY, .arg_i = c});
  }
}

/* The auto-unmute rule, at the one point every capture start funnels through
 * (immediate presses, quantized fires, sound-activated triggers): a muted
 * track unmutes the moment it starts recording — a capture is never silent.
 * Clears any pending mute too (the capture start supersedes it). Lanes that
 * actually flip log a synthetic unmute so a perf-log replay matches. */
static void le_capture_start_unmute(le_engine* e, le_track* t,
                                    uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    t->lanes[l].pending_mute = 0;
    if (load_i32(&t->lanes[l].a_muted) == 0) continue;
    store_i32(&t->lanes[l].a_muted, 0);
    le_plog_push(e, frame,
                 (le_command){.code = LE_CMD_SET_LANE_MUTE,
                              .lanef = {ch, l, 0.0f}});
  }
}

/* Lands the mutes deferred during a capture (LE_CMD_SET_LANE_MUTE's capturing
 * branch) now that the capture is ending. Returns the (possibly overridden)
 * end state: a pending mute forces OVERDUBBING down to PLAYING — the user
 * asked for silence mid-take, so the capture must not continue into a rec/dub
 * auto-overdub over it. `apply` = 0 drops the pendings without muting (the
 * nothing-captured -> EMPTY path: a mute on no content is meaningless, and an
 * empty track always comes back unmuted). Applied lanes log the mute at the
 * landing frame, keeping the perf-log replay faithful. */
static int32_t le_consume_pending_mutes(le_engine* e, le_track* t,
                                        int32_t end_state, int apply,
                                        uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  int any = 0;
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    if (!t->lanes[l].pending_mute) continue;
    t->lanes[l].pending_mute = 0;
    any = 1;
    if (!apply) continue;
    store_i32(&t->lanes[l].a_muted, 1);
    le_plog_push(e, frame,
                 (le_command){.code = LE_CMD_SET_LANE_MUTE,
                              .lanef = {ch, l, 1.0f}});
  }
  if (any && apply && end_state == LE_TRACK_OVERDUBBING) {
    return LE_TRACK_PLAYING;
  }
  return end_state;
}

/* ---- tempo grid + click + count-in (audio thread) ----
 *
 * Grid state + locks (A1) and the click voice + count-in built on them (A2);
 * the musical arm machinery is a later part. Everything here is dormant with
 * the grid-off/click-off defaults — the pure math lives in tempo_grid.c;
 * these helpers wire it to engine state. None of these commands is
 * perf-logged: the tempo commands change no audible output in this part, and
 * the click commands shape a source that is EXCLUDED from performance capture
 * by construction (summed after perf_tap_master_frame, D5) — a replay of the
 * captured performance never contains the click, so logging its configuration
 * would be noise the renderer must ignore. */

/* Click voice constants (recovered 2f0513a values): a 30 ms linearly decaying
 * sine burst at 0.25 amplitude — 1000 Hz on beats, 1500 Hz on the bar
 * downbeat. */
#define LE_CLICK_AMP 0.25f
#define LE_CLICK_MS 30
#define LE_CLICK_FREQ_BEAT 1000.0f
#define LE_CLICK_FREQ_DOWNBEAT 1500.0f
#define LE_CLICK_TWO_PI 6.28318530717958647692f

/* (Re)starts the click burst for a beat that begins this frame. */
static void trigger_click(le_engine* e, int downbeat) {
  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  e->click_len = sr * LE_CLICK_MS / 1000;
  if (e->click_len < 1) e->click_len = 1;
  e->click_remaining = e->click_len;
  e->click_phase = 0.0f;
  e->click_freq = downbeat ? LE_CLICK_FREQ_DOWNBEAT : LE_CLICK_FREQ_BEAT;
}

/* Drops an in-progress count-in back to idle (cancel and commit both funnel
 * through here). The current click burst, if any, decays out naturally — only
 * future beats stop. */
static void le_count_in_reset(le_engine* e) {
  e->count_in_total = 0;
  e->count_in_elapsed = 0;
  e->count_in_beats = 0;
  e->count_in_beat = 0;
  store_i32(&e->a_counting_in, 0);
  store_i32(&e->a_count_in_beats_left, 0);
}

/* Starts a count-in for the DEFINING record press on `ch` (D9; the caller —
 * handle_record's EMPTY branch — has verified no master exists, count-in is
 * enabled, and a tempo is set). Beat boundaries render from their index
 * against the frozen nominal frames-per-beat, so the recording starts exactly
 * bars * ts_num * fpb frames after the press — the bar-1 downbeat. Returns 1
 * when counting began, 0 on a degenerate grid (caller records immediately). */
static int le_count_in_begin(le_engine* e, int32_t ch, int32_t bars) {
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  const double fpb = le_grid_frames_per_beat_unit(&g);
  if (fpb <= 0.0) return 0; /* degenerate: nothing to click against */
  const int32_t beats = bars * num;
  e->count_in_fpb = fpb;
  e->count_in_beats = beats;
  e->count_in_total = (int32_t)llround((double)beats * fpb);
  if (e->count_in_total < 1) e->count_in_total = 1;
  e->count_in_elapsed = 0;
  e->count_in_beat = 0;
  e->count_in_channel = ch;
  store_i32(&e->a_counting_in, 1);
  store_i32(&e->a_count_in_beats_left, beats);
  return 1;
}

/* The D6 tempo lock: manual tempo / signature changes (and taps) are ignored
 * while any track has content AND a grid exists (loop_bars > 0 or
 * tempo_source != none). Only clearing every track releases it — a paused or
 * stopped track still holds the lock, and a derived tempo's source loop being
 * cleared does not (the surviving grid keeps the lock while siblings play).
 * Deliberate: content recorded free-form (sync off) with a manually-set
 * tempo also locks — the tempo was audible context for the take, and
 * pre-stretch there is no way to honor a change (D6's safe reading; matches
 * the Sheeran, which locks tempo after any recording).
 * The loop_bars half of the disjunct is defensive redundancy today: every
 * path that sets loop_bars > 0 also leaves tempo_source != none (sync
 * derivation marks DERIVED; the round-to-bars path requires a source), so no
 * reachable state distinguishes it. It stays per the plan's literal predicate
 * as a belt against future states that might break that invariant.
 *
 * EXTENSION (code-review fix, A2): also locked while a count-in is running
 * (count_in_total > 0), even though the defining track is still EMPTY at
 * that point (it only becomes RECORDING at le_count_in_commit) — the
 * "any_content" test above would otherwise miss this window entirely. The
 * count-in's click schedule (count_in_fpb/count_in_beats/count_in_total) is
 * already frozen from the CURRENT tempo the instant it begins
 * (le_count_in_begin); letting a tempo/signature change through mid-count
 * would leave the audible click counting the OLD rate while
 * sync_grid_to_loop later built the finalized loop's beat grid from the NEW
 * one — a silent mismatch between what was heard and what was recorded.
 * This is D6's same "tempo is locked once it's audibly committed to" spirit,
 * just extended one edge earlier: the count-in IS the commitment moment, not
 * the first captured sample. */
static int le_tempo_locked(le_engine* e) {
  if (e->count_in_total > 0) return 1;
  int any_content = 0;
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (load_i32(&e->tracks[t].a_state) != LE_TRACK_EMPTY) {
      any_content = 1;
      break;
    }
  }
  if (!any_content) return 0;
  return load_i32(&e->a_loop_bars) > 0 ||
         load_i32(&e->a_tempo_source) != LE_TEMPO_SOURCE_NONE;
}

/* The D4 looper-mode lock: a mode switch (LE_CMD_SET_LOOPER_MODE) is ignored
 * while ANY track has content (state != EMPTY) — deliberately a simpler
 * predicate than le_tempo_locked above: no grid check (loop_bars /
 * tempo_source), no count-in extension. Content on ANY track locks it, not
 * just a "selected" or track-0 one — the mode is a session-level choice, not
 * a per-track one. Only clearing every track releases the lock. */
static int le_looper_mode_locked(le_engine* e) {
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (load_i32(&e->tracks[t].a_state) != LE_TRACK_EMPTY) return 1;
  }
  return 0;
}

/* MIDI clock send gate (C1, D15): whether le_midi_clock_advance may emit
 * ANYTHING this block. Manual-verified (docs/plan/2026-07-22-song-mode-
 * spec.md, "MIDI clock" section): send is active only in Multi/Sync/Band —
 * Song and Free stay completely silent regardless of clock_mode. Unlike
 * le_looper_mode_locked above (a content check gating whether a MODE SWITCH
 * is accepted), this reads the CURRENT mode every block to gate whether
 * clock OUTPUT fires — the two are deliberately different predicates over
 * the same a_looper_mode field. */
static int le_clock_send_gate_open(le_engine* e) {
  if (load_i32(&e->a_clock_mode) != LE_CLOCK_SEND) return 0;
  const int32_t mode = load_i32(&e->a_looper_mode);
  return mode == LE_LOOPER_MODE_MULTI || mode == LE_LOOPER_MODE_SYNC ||
        mode == LE_LOOPER_MODE_BAND;
}

/* Two-tap tempo (modernized from 2f0513a): the interval between this tap and
 * the previous one, in frames of e->frame_clock (block-granular — taps arrive
 * via the ring, which drains at block start, so finer resolution would be
 * fiction). Intervals outside the 30..300 BPM window are ignored, so a stale
 * first tap never produces an absurd tempo. The lock is checked by the caller
 * (a locked tap is ignored WHOLESALE — not even recorded, so unlocking does
 * not inherit half of a stale tap pair). */
static void handle_tap(le_engine* e) {
  const uint64_t now = e->frame_clock;
  if (e->has_tap) {
    const uint64_t interval = now - e->last_tap_frame;
    const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
    if (interval > 0) {
      const double bpm = 60.0 * (double)sr / (double)interval;
      if (bpm >= (double)LE_GRID_TEMPO_MIN &&
          bpm <= (double)LE_GRID_TEMPO_MAX) {
        store_f32(&e->a_tempo_bpm_bits, (float)bpm);
        store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_TAPPED);
      }
    }
  }
  e->last_tap_frame = now;
  e->has_tap = 1;
}

/* Establishes the loop<->grid relationship for a freshly defined master loop
 * (modernized from 2f0513a's sync_tempo_to_loop, generic over signatures and
 * following D7's precedence — the loop's AUDIO length is never altered):
 *   - sync off: no grid (loop_bars 0, tempo untouched) — free-form.
 *   - sync on, tempo already set (manual/tapped/derived): round the loop to a
 *     whole-bar COUNT of the existing grid; the tempo is NOT re-derived and
 *     NOT snapped (deliberate change from the old stack, which snapped the
 *     displayed tempo to the loop).
 *   - sync on, no tempo (source none): derive the tempo from the loop (whole
 *     bars in the current signature, BPM in 30..300 nearest 120) and mark the
 *     source derived.
 * The beat grid then divides the loop exactly (grid_total_beats over len),
 * whatever the nominal BPM says — the loop is the truth once it exists. */
static void sync_grid_to_loop(le_engine* e, int32_t len) {
  e->grid_prev_beat = -1; /* re-arm beat publication at the next frame */
  if (!load_i32(&e->a_sync_tempo) || len <= 0) {
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  int32_t bars = 0;
  if (load_i32(&e->a_tempo_source) == LE_TEMPO_SOURCE_NONE) {
    const float bpm = le_grid_derive_bpm(len, num, sr, &bars);
    if (bpm <= 0.0f || bars < 1) { /* degenerate input: stay grid-free */
      e->grid_total_beats = 0;
      store_i32(&e->a_loop_bars, 0);
      return;
    }
    store_f32(&e->a_tempo_bpm_bits, bpm);
    store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_DERIVED);
  } else {
    const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                             load_i32(&e->a_ts_den), sr};
    bars = le_grid_bars_for_loop(&g, len);
    if (bars < 1) bars = 1;
  }
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
}

/* ---- track length presets (A6, D17; song-mode-spec.md §1) ----
 *
 * A per-track preset on the DEFINING (first/master) recording, orthogonal to
 * le_effective_multiple (which fixes a NON-defining track's length once a
 * master already exists — engine_private.h). Two hooks implement the full
 * preset x click-mode matrix with no change to the AUTO path:
 *   - le_arm_length_preset_target, called once when a defining recording
 *     actually begins (handle_record's EMPTY branch and le_count_in_commit),
 *     latches this take's auto-finalize target in frames, or 0 when none
 *     applies.
 *   - The target (if any) is consumed in advance_transport_frame (auto-
 *     finalizes into overdub at exactly N bars) or at finalize_master (an
 *     unarmed take with an N-bars preset derives tempo from length / N).
 * See le_engine_set_track_length_preset's header doc for the matrix itself. */

/* Arms (or clears) track [t]'s auto-finalize target for the CURRENT defining
 * take. Only armed — target_frames > 0 — when ALL of: an N-bars preset is set,
 * loop<->grid sync is on (a preset is dormant without a grid, matching a
 * plain grid-off recording), the click is audible during recording (any mode
 * but off), and a tempo is already established (source != none) — the auto-
 * finalize frame count requires a known frames-per-bar, which requires a
 * tempo. Reads click_mode / tempo ONCE here, at record-start commitment (like
 * le_count_in_begin's frozen schedule): a later mid-take change never moves
 * this take's target. Left at 0 (no auto-finalize) covers AUTO, N-bars with
 * click off, and N-bars with click on but no tempo yet — all three finalize
 * through the length-preset-derive-tempo path in finalize_master instead
 * (the A6 fallback for the no-tempo edge case, documented on the header). */
static void le_arm_length_preset_target(le_engine* e, le_track* t) {
  t->length_preset_target_frames = 0;
  const int32_t bars = load_i32(&t->a_length_preset_bars);
  if (bars <= 0) return; /* AUTO: no target, ever */
  if (!load_i32(&e->a_sync_tempo)) return; /* grid disabled: preset dormant */
  if (load_i32(&e->a_click_mode) == LE_CLICK_OFF) return;
  if (load_i32(&e->a_tempo_source) == LE_TEMPO_SOURCE_NONE) return;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  const double fpbar = le_grid_frames_per_bar(&g);
  if (!(fpbar > 0.0)) return;
  const double target = (double)bars * fpbar;
  if (!(target >= 1.0)) return;
  /* Re-validate against capacity with the LIVE grid (code-review fix): the
   * D17 allocation guard in le_engine_set_track_length_preset only checked
   * the signature at SET time, worst-case 30 BPM. Nothing stops a signature
   * (or tempo) change between setting the preset and actually recording — no
   * track has content yet, so D6's lock does not apply — and this take's
   * live grid can need far more frames than the guard ever saw. Using the
   * ACTUAL live-computed target here (not another worst-case estimate) is
   * the precise, correct check: this is exactly the frame count the auto-
   * finalize would need to reach. If it can't fit, leave the target unarmed
   * so the take degrades cleanly to the click-off derive-from-length path at
   * finalize (the same fallback already used for the no-tempo edge case)
   * instead of arming a target that can never fire — which would otherwise
   * leave a stale length_preset_target_frames for finalize_master to trip
   * over silently (the bug this guard fixes). */
  if (target > (double)e->max_loop_frames) return;
  t->length_preset_target_frames = (int32_t)llround(target);
}

/* The N-bars length-preset finalize override, used by finalize_master in
 * place of sync_grid_to_loop whenever a defining take with an N-bars preset
 * finalizes WITHOUT having reached its auto-finalize target (click was off,
 * so no target was ever armed; or click was on but no tempo existed yet at
 * record start — the A6 fallback). Per the manual's explicit rule for this
 * preset, tempo is derived from the ACTUAL recorded length divided by `bars`
 * UNCONDITIONALLY — even over an existing manual/tapped tempo, unlike AUTO's
 * D7 "never re-derive an existing tempo" precedence. The loop's AUDIO length
 * is never altered; only bars/tempo are set to describe it. Mirrors
 * sync_grid_to_loop's guard shape (sync off / degenerate input -> grid-free)
 * so the two stay easy to compare. */
static void le_apply_length_preset_tempo(le_engine* e, int32_t len,
                                         int32_t bars) {
  e->grid_prev_beat = -1; /* re-arm beat publication at the next frame */
  if (!load_i32(&e->a_sync_tempo) || len <= 0 || bars <= 0) {
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const float bpm = le_grid_bpm_for_length(len, bars, num, sr);
  if (bpm <= 0.0f) { /* degenerate input: stay grid-free, like sync_grid_to_loop */
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  store_f32(&e->a_tempo_bpm_bits, bpm);
  store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_DERIVED);
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
}

/* Per-frame beat publication, loop-driven: once a grid exists the beat index
 * derives from the master position so beats divide the loop exactly (the
 * 2f0513a loop-synced branch; the free-running branch lives in click_frame).
 * Dormant-grid cost is the single grid_total_beats compare. Note: with the
 * default sync-on, a grid derives at the first defining finalize, so the
 * per-frame divide runs from then on — the same cost profile as the old
 * stack's loop-synced metronome.
 *
 * A2: this is also the loop-locked click scheduler. `click_on` is the frame's
 * click audibility gate; a beat transition while it holds retriggers the
 * click voice (downbeat pitch on beat 0 of the bar). grid_prev_beat/
 * a_current_beat are tracked EVERY frame a grid+loop exist, regardless of
 * click_on — only the trigger_click call below is gated — so grid_prev_beat
 * always holds the TRUE current beat, click on or off.
 *
 * A RISE of the gate (click_on flips 0->1) re-arms grid_prev_beat to -1, but
 * ONLY when `pos == 0` — the loop top, which is the one case where a rising
 * gate should click immediately: the held-transport resume (le_transport_
 * held parks the clock at 0 the whole time it's held, so grid_prev_beat is
 * already sitting at 0 from the continuous tracking above and would
 * otherwise suppress the resume's downbeat — the -1 re-arm forces it back
 * out). Any OTHER gate rise — most notably a punch-in overdub starting
 * mid-loop under LE_CLICK_REC (handle_record's PLAYING/STOPPED branch begins
 * capturing at the CURRENT transport position, not a beat boundary) — must
 * NOT get this treatment: firing immediately there would click at whatever
 * arbitrary phase the punch landed on, not a real beat (confirmed bug:
 * 300 BPM, punch mid-beat fired a click ~112 ms after the true beat onset).
 * Leaving grid_prev_beat alone on those rises is exactly right, because it
 * is already the CURRENT beat (continuous tracking, above) — so `beat !=
 * grid_prev_beat` below stays false and no spurious click fires; the click
 * naturally picks up at the next REAL boundary once the beat actually
 * changes. */
static inline void grid_beat_frame(le_engine* e, int32_t pos, int click_on) {
  if (e->grid_total_beats <= 0 || e->clock.length <= 0) return;
  if (click_on != e->click_grid_gate) {
    if (click_on && pos == 0) e->grid_prev_beat = -1;
    e->click_grid_gate = click_on;
  }
  const int32_t beat =
      le_grid_beat_at(pos, e->clock.length, e->grid_total_beats);
  if (beat != e->grid_prev_beat) {
    e->grid_prev_beat = beat;
    const int32_t num = load_i32(&e->a_ts_num);
    const int32_t bar_beat = num > 0 ? beat % num : 0;
    store_i32(&e->a_current_beat, bar_beat);
    if (click_on) trigger_click(e, bar_beat == 0);
  }
}

/* Loads the loop-locked subdivision ratio for the CURRENT quantize division
 * (A3), or returns 0 when subdivision arming is inactive — division off, no
 * loop-locked grid (grid_total_beats == 0: sync off / free-form loop), or no
 * loop. Inactive means the boolean loop-top machinery stands alone, exactly
 * the pre-A3 behavior. Reads the LIVE a_quantize_div on purpose: a granularity
 * change while an arm is pending re-evaluates on the very next check (D8), and
 * a change to OFF reverts the pending fire to the loop top with no extra
 * bookkeeping. */
static int le_live_subdiv_ratio(le_engine* e, int64_t* num, int64_t* den) {
  const int32_t div = load_i32(&e->a_quantize_div);
  if (div == LE_GRID_DIV_OFF || e->grid_total_beats <= 0 ||
      e->clock.length <= 0) {
    return 0;
  }
  return le_grid_loop_subdiv_ratio(e->grid_total_beats,
                                   load_i32(&e->a_ts_num),
                                   load_i32(&e->a_ts_den), div, num, den);
}

/* An unlocked tempo/signature change can land over a SURVIVING grid (all
 * tracks empty but the master kept for redo — the undo-to-empty edge, or a
 * whole-rig clear that was undone). Recompute the bar count and beat grid
 * against the surviving master so the published grid stays coherent with the
 * new value. Deliberately bypasses sync_grid_to_loop: the sync toggle only
 * governs future finalizes and must never destroy a live grid. */
static void regrid_surviving_master(le_engine* e) {
  if (e->clock.length <= 0 || load_i32(&e->a_loop_bars) <= 0) return;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  int32_t bars = le_grid_bars_for_loop(&g, e->clock.length);
  if (bars < 1) bars = 1;
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
  e->grid_prev_beat = -1;
}

static void finalize_master(le_engine* e, le_track* t, int32_t end_state,
                            uint64_t frame) {
  /* A mute deferred during the take lands with the finalize (and blocks a
   * rec/dub continuation into OVERDUBBING — see le_consume_pending_mutes). */
  end_state = le_consume_pending_mutes(e, t, end_state, 1, frame);
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  /* The master loop length is established (or re-established, on a hand-off
   * finalize) right here — this is the live-record-path call site for the
   * LE_PLOG_LOOP_LENGTH_LOCKED transport fact (the other is LE_CMD_COMMIT_
   * SESSION, for session import). */
  le_plog_push(e, frame,
              (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED, .arg_i = len});
  /* Free/Song mode (B2b + B4, index Architecture §4): this track's OWN
   * clock, not the shared master. Neither mode has a single shared loop
   * (song-mode-spec §1: Free is "four un-synced, independently playing"
   * tracks; Song is "four looper tracks that can vary in length and be
   * played back independently" — §2's engine-consequences note calls Song's
   * transport "structurally identical" to Free's) — up to 8 independent
   * lengths, each established by that track's own defining recording, so
   * e->clock / a_master_len / loop_iteration must stay untouched here
   * (dormant at whatever they already are — 0 in practice: D4 only allows
   * switching INTO Free/Song with every track empty, and le_engine_configure
   * / handle_clear reset the master alongside every track whenever the rig
   * goes fully empty, so no Multi-mode residue can reach a Free/Song-mode
   * finalize). sync_grid_to_loop / le_apply_length_preset_tempo are Multi
   * mode's "this ONE loop derives/rounds THE session tempo" logic (D7) —
   * with several independent lengths there is no single loop to derive a
   * session-wide tempo from, so neither runs for a Free/Song-mode finalize:
   * BPM/signature stay exactly what the session already has (D7: session-
   * wide, set manually/tapped, never derived from one of several independent
   * per-track lengths — song-mode-spec §2 Q6 confirms Song, like Free, has
   * no per-section tempo). This does NOT disable quantize/length presets in
   * Free/Song mode — le_arm_length_preset_target's auto-finalize target
   * (consumed above this function, in advance_transport_frame) is a pure
   * function of the GLOBAL tempo grid (tempo_grid.h takes bpm/signature/
   * sample_rate as parameters, never track-bound state) and already
   * composes per-track unmodified; only the POST-hoc "derive/round the
   * session tempo from THIS take's length" step below is Multi-mode-only. */
  const int32_t mode = load_i32(&e->a_looper_mode);
  const int free_mode = mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  if (free_mode) {
    le_loop_clock_set_length(&t->free_clock, len);
    t->free_iteration = 0; /* this track's own loop just (re)started */
    /* Re-arm this track's own viz bucket cursor (mirrors the loop_viz_bucket
     * re-arm master finalizes get for free by always being preceded by an
     * all-empty reset — see le_engine_configure / handle_clear doc). */
    e->track_viz_bucket[(int32_t)(t - e->tracks)] = -1;
  } else {
    le_loop_clock_set_length(&e->clock, len);
    e->loop_iteration = 0; /* the base loop just (re)started */
    store_i32(&e->a_master_len, len);
  }
  le_track_set_len(t, len);
  store_i32(&t->a_multiple, 1); /* the defining track is one base loop */
  store_i32(&t->a_sync_divisor, 0); /* a defining track is never a division */
  store_i32(&t->a_state, end_state);
  t->start_iter = 0;
  /* This track leaves RECORDING here regardless of end_state — even the
   * OVERDUBBING case is a record-to-overdub toggle, not a continuation of the
   * same recording. */
  le_plog_push(e, frame,
              (le_command){.code = LE_PLOG_RECORD_END,
                           .arg_i = (int32_t)(t - e->tracks)});
  /* A6/D17: an N-bars length preset that finalizes WITHOUT its auto-finalize
   * target having been armed (click was off, or click was on but no tempo
   * existed at record start — le_arm_length_preset_target) derives tempo from
   * the actual length / N instead of the normal AUTO path. An armed target
   * (target reached on time, OR an early press that disarms it — D17) takes
   * the normal path unchanged: on-time, the existing tempo already makes len
   * round back to bars == N; early, the shorter take rounds to whatever bars
   * it actually spans, exactly the "early press disarms the preset" rule.
   * Free mode (see above): skipped outright — no session-tempo derivation
   * from a single independent length. */
  const int32_t preset_bars = load_i32(&t->a_length_preset_bars);
  if (!free_mode) {
    if (preset_bars > 0 && t->length_preset_target_frames == 0) {
      le_apply_length_preset_tempo(e, len, preset_bars);
    } else {
      sync_grid_to_loop(e, len);
    }
  }
  t->length_preset_target_frames = 0; /* consumed; the next take re-arms */
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

/* Sync/Band quantize decision (B3, D16): the nearest valid ratio to how much
 * [len] was actually captured relative to the primary's [base] length,
 * returned as a power-of-two exponent p in [-2,2] over the supported set
 * {1/4, 1/2, 1, 2, 4} — p >= 0 means a multiple (k = 1<<p); p < 0 means a
 * division (n = 1<<-p). Log2-nearest, not linear-nearest: the ratio set is
 * geometric (equally spaced in log2), so this is genuinely the "closest"
 * match — and, deliberately unlike Multi's AUTO round-up-only rule, it can
 * round DOWN a take that ran long, truncating rather than padding with
 * silence. This matches the manual's "every later [Sync/Band] track is AUTO
 * (Bars)" (song-mode-spec.md §1): it snaps to the nearest grid point, not
 * always the next one up. A take far outside the set (near-zero or many
 * loops long) still clamps to the nearest END of the range rather than
 * being rejected. */
static int32_t le_sync_ratio_pow(int32_t len, int32_t base) {
  if (len <= 0 || base <= 0) return 0;
  const double p = log2((double)len / (double)base);
  int32_t pi = (int32_t)llround(p);
  if (pi < -2) pi = -2;
  if (pi > 2) pi = 2;
  return pi;
}

/* Sync/Band quantize decision (B3, D16), adversarial-review BUG 1 + BUG 2
 * fix: chooses BOTH the multiple/divisor AND validates it fits, so no
 * caller can apply an unsafe result. Writes *out_k (>= 1) and
 * *out_divisor (0 = ordinary multiple of *out_k base loops; 2 or 4 = a
 * division, *out_k inertly 1) for a track that captured [len] frames
 * against the primary's [base]-frame length, with the buffer physically
 * capped at [max_loop_frames] (a lane's pool is allocated ONCE at that
 * size in le_engine_configure — le_track_set_len only ever publishes the
 * logical length, it never grows the buffer).
 *
 * BUG 1 (memory safety): the multiple leg (p >= 0, k = 1/2/4) used to call
 * le_track_set_len(t, k * base) with NO clamp against max_loop_frames,
 * unlike the ordinary (non-Sync) path a few lines below in
 * finalize_new_track, which already has `maxk = max_loop_frames / base;
 * if (k > maxk) k = maxk;`. Without it, a large primary (e.g. any base
 * over max_loop_frames/4) let a non-primary track's nearest-ratio match
 * publish a_len larger than the lane's actual allocated capacity —
 * mix_tracks_frame's `lbuf[seg_base[t] + trk_pos[t]]` then reads out of
 * bounds on the audio thread. Fixed here with the IDENTICAL clamp the
 * ordinary path already trusts.
 *
 * BUG 2 (audio correctness): the division leg used to accept ANY p < 0
 * candidate and compute div_len = llround(base / n) independently at
 * write time (here) and read time (sync_division_positions_frame) with
 * nothing forcing n * div_len == base. Whenever the primary's length isn't
 * evenly divisible by n — the ORDINARY case for a freely-recorded primary,
 * not a rare edge case (e.g. base=17, n=4 -> div_len=llround(4.25)=4, but
 * 4*4=16=/=17) — the fixed-length `pos % div_len` read repeats or skips
 * exactly one buffer index every single primary cycle: a permanent,
 * audible stutter for the life of the track. Fixed by only ever OFFERING a
 * division that tiles EXACTLY: step the requested divisor down (4 -> 2)
 * and, if the primary's length is odd (no divisor in {2,4} can ever tile
 * it exactly), fall all the way back to an ordinary 1x multiple instead of
 * publishing an inexact division. This is the "reject and fall back"
 * option (vs. a remainder-distributing read mapping in the spirit of
 * le_grid_beat_at/tempo_grid.c) — simpler, and every division this
 * function ever hands back is now PROVABLY exact (base % divisor == 0),
 * not just "close", so sync_division_positions_frame's read needs no
 * rounding at all (see its updated doc). */
static void le_sync_choose_ratio(int32_t len, int32_t base,
                                 int32_t max_loop_frames, int32_t* out_k,
                                 int32_t* out_divisor) {
  const int32_t p = le_sync_ratio_pow(len, base);
  if (p >= 0) {
    int32_t k = 1 << p; /* 1, 2, or 4 base loops */
    const int32_t maxk = max_loop_frames / base;
    if (maxk >= 1 && k > maxk) k = maxk; /* BUG 1: identical to the below */
    if (k < 1) k = 1;
    *out_k = k;
    *out_divisor = 0;
    return;
  }
  for (int32_t n = 1 << (-p); n >= 2; n /= 2) {
    if (base % n == 0) { /* BUG 2: only ever offer an EXACT division */
      *out_k = 1;
      *out_divisor = n;
      return;
    }
  }
  *out_k = 1; /* base doesn't divide evenly by 2 (let alone 4): no valid
               * division exists — fall back to an ordinary 1x multiple,
               * always exact and always within capacity (base itself is
               * already <= max_loop_frames, the invariant every defining
               * take's own auto-finalize already enforces). */
  *out_divisor = 0;
}

/* Recomputes a_multiple / a_sync_divisor for a track whose length is being
 * REINSTATED directly (LE_CMD_REDO_FROM_EMPTY / LE_CMD_RESTORE_CLEAR)
 * rather than freshly finalized — these paths restore a previously-decided
 * length; they don't re-run finalize_new_track's decision. Mirrors the
 * codebase's existing "recompute from len/base rather than store it
 * redundantly" choice for `multiple` (le_hist_entry.multiple is likewise
 * write-only, never read back). k = len/base >= 1 is the ordinary multiple
 * path, byte-identical to before B3. len < base (k rounds to 0) means the
 * restored track was a B3 Sync/Band DIVISION: since le_sync_choose_ratio
 * (post-BUG-2-fix) only ever creates a division where base % divisor == 0
 * EXACTLY, the divisor is recovered exactly too (len == base/4 tests
 * first; anything else that got here — len < base — can only be base/2,
 * the sole remaining possibility the write side could have produced), not
 * guessed by a fuzzy log2 threshold. */
static void le_restore_multiple_or_divisor(le_track* t, int32_t base,
                                           int32_t len) {
  if (base <= 0) base = len > 0 ? len : 1;
  const int32_t k = len / base;
  if (k >= 1) {
    store_i32(&t->a_multiple, k);
    store_i32(&t->a_sync_divisor, 0);
    return;
  }
  const int32_t n = (len > 0 && base % 4 == 0 && len * 4 == base) ? 4 : 2;
  store_i32(&t->a_sync_divisor, n);
  store_i32(&t->a_multiple, 1); /* inert alongside a nonzero divisor */
}

/* Adversarial-review BUG 4 fix: whether channel [ch] IS the crowned primary
 * in Sync/Band mode — regardless of whether it is currently "established"
 * (le_sync_quantize_active deliberately excludes ch == primary from its
 * own gate). Used by finalize_new_track to force the primary's OWN
 * re-record to exactly one base loop instead of the ordinary auto-round-up
 * whenever it lands here (e->clock.length > 0 already — i.e. this is NOT
 * the primary's first-ever defining take, which goes through
 * finalize_master instead and is untouched by this).
 *
 * Concretely: clearing the primary while a dependent Sync track survives
 * keeps e->clock alive (handle_clear only resets it when EVERY track is
 * empty) — a_primary_track itself also survives, per D18. Re-recording the
 * primary then hits finalize_new_track (e->clock.length is nonzero), and
 * without this check it would auto-round like any other track — landing
 * a_multiple at 2 or 4 if the new take doesn't match the old base exactly,
 * silently "un-establishing" the primary (le_sync_quantize_active's
 * a_multiple == 1 check would start failing) for every FUTURE Sync/Band
 * recording, with zero user-visible signal. D18: the primary is a
 * deliberate, persistent designation — its re-record must always
 * re-establish as exactly one base loop. e->clock.length itself is
 * deliberately left UNTOUCHED (unlike a true fresh defining recording,
 * finalize_master): a sibling may already be phase-locked to it, so this
 * truncates any overflow past one base loop (the same "can round DOWN"
 * behavior le_sync_choose_ratio already has for ordinary non-primary
 * tracks) rather than ever changing the shared base a sibling depends on.
 * A useful side effect: this also closes the "someone else recorded
 * first, defining e->clock, before the primary's own first take"
 * mis-ordering le_sync_quantize_active's doc used to flag as a documented
 * limitation — the primary now always lands at multiple == 1 there too. */
static inline int le_is_reestablishing_primary(le_engine* e, int32_t ch) {
  const int32_t mode = load_i32(&e->a_looper_mode);
  if (mode != LE_LOOPER_MODE_SYNC && mode != LE_LOOPER_MODE_BAND) return 0;
  return load_i32(&e->a_primary_track) == ch;
}

/* Finalizes a non-defining track that recorded freely across one or more base
 * loops. A track that captured nothing (never reached the loop top) returns
 * to EMPTY. Three length policies, mutually exclusive:
 *   - Sync/Band with an established primary (le_sync_quantize_active, D16):
 *     snaps to the nearest valid multiple-or-division of the PRIMARY's
 *     length, chosen AND capacity/exactness-validated in one call
 *     (le_sync_choose_ratio — le_effective_multiple is bypassed entirely,
 *     "every later track is AUTO", song-mode-spec.md §1). A division
 *     publishes a_sync_divisor and sizes the track's OWN buffer to exactly
 *     that (exact, by construction) fraction — see
 *     sync_division_positions_frame for how it plays back phase-locked to
 *     the primary's top.
 *   - Sync/Band, but [t] IS the crowned primary re-recording into an
 *     e->clock a sibling keeps alive (le_is_reestablishing_primary, BUG 4):
 *     forced to exactly one base loop — see that predicate's doc.
 *   - Otherwise (today's behavior, unchanged): rounds the length UP to the
 *     nearest whole base loop (the locked #4 behaviour), per
 *     le_effective_multiple (engine_private.h — shared with the control
 *     thread's first-wrap pre-arm gate, which predicts this finalize). */
static void finalize_new_track(le_engine* e, le_track* t, int32_t end_state,
                               uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t base = e->clock.length > 0 ? e->clock.length : 1;
  if (t->record_pos <= 0) { /* nothing captured */
    /* Drop (not apply) any mute deferred during the void take: an EMPTY
     * track always comes back unmuted. */
    le_consume_pending_mutes(e, t, end_state, 0, frame);
    store_i32(&t->a_state, LE_TRACK_EMPTY);
    le_track_set_len(t, 0);
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_sync_divisor, 0);
    t->record_pos = 0;
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_RECORD_END, .arg_i = ch});
    return;
  }
  /* A mute deferred during the take lands with the finalize (and blocks a
   * rec/dub continuation into OVERDUBBING — see le_consume_pending_mutes). */
  end_state = le_consume_pending_mutes(e, t, end_state, 1, frame);
  if (le_sync_quantize_active(e, ch)) {
    /* le_sync_quantize_active guarantees the primary's OWN recorded length
     * is exactly one base loop, so `base` (e->clock.length) IS the
     * primary's length here — no separate lookup needed. */
    int32_t k, divisor;
    le_sync_choose_ratio(t->record_pos, base, e->max_loop_frames, &k,
                        &divisor);
    if (divisor > 0) {
      store_i32(&t->a_sync_divisor, divisor);
      store_i32(&t->a_multiple, 1); /* inert alongside a nonzero divisor */
      le_track_set_len(t, base / divisor); /* exact: base % divisor == 0 */
    } else {
      store_i32(&t->a_sync_divisor, 0);
      store_i32(&t->a_multiple, k);
      le_track_set_len(t, k * base);
    }
  } else if (le_is_reestablishing_primary(e, ch)) {
    /* BUG 4: the primary re-recording over a master a sibling kept alive —
     * always exactly one base loop, e->clock.length untouched. */
    store_i32(&t->a_sync_divisor, 0);
    store_i32(&t->a_multiple, 1);
    le_track_set_len(t, base);
  } else {
    /* A forced multiple fixes the length to exactly K base loops; 0 (auto)
     * rounds up to whole base loops based on how much was recorded. */
    const int32_t forced = le_effective_multiple(e, ch);
    int32_t k = forced > 0 ? forced : (t->record_pos + base - 1) / base;
    const int32_t maxk = e->max_loop_frames / base;
    if (k < 1) k = 1;
    if (maxk >= 1 && k > maxk) k = maxk;
    store_i32(&t->a_sync_divisor, 0);
    store_i32(&t->a_multiple, k);
    le_track_set_len(t, k * base);
  }
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
  /* Free/Song mode (B2b, adversarial-review BUG 1 fix; broadened to SONG by
   * B4): `base` moved INSIDE the loop and computed per-track (mirroring
   * mix_tracks_frame's trk_len[t]) instead of being read once from
   * e->clock.length. e->clock stays permanently dormant (length 0) in
   * Free/Song mode, so a single outer `base` meant every guard below that
   * gates on `base > 0` could never pass for a Free/Song-mode track —
   * regardless of that track's own established free_clock.length — leaving
   * a partially-covered overdub shadow's drain permanently un-armed:
   * dub_draining never sets, the shadow never retires, a_layer_in_flight
   * never clears, and the shadow's pool slot never returns to the shared
   * bounded pool. A real-time-thread resource leak, proven empirically (a
   * throwaway repro: Free-mode track, punch in, overdub < 1 lap, punch out,
   * settle — layer_in_flight stuck at 1 forever). Pinned by
   * test_free_mode_dub_layer_retires_not_stuck (and its Song-mode twin,
   * test_song_mode_dub_layer_retires_not_stuck). */
  const int32_t mode = load_i32(&e->a_looper_mode);
  const int free_mode = mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  for (int32_t ti = 0; ti < e->track_count; ++ti) {
    le_track* t = &e->tracks[ti];
    le_dub_try_retire(e, t, frame);
    if (!load_i32(&t->a_layer_in_flight)) continue;
    const int32_t st = load_i32(&t->a_state);
    if (st == LE_TRACK_OVERDUBBING || t->od_gain > 0.0f) continue; /* writing */
    const int32_t base = free_mode ? t->free_clock.length : e->clock.length;

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
    if (st != LE_TRACK_RECORDING && st != LE_TRACK_OVERDUBBING) continue;
    /* The hand-off supersedes any armed (quantized) end on the closed track:
     * the finalize it was waiting for happens right here, so a stale pending
     * would re-fire at the next boundary on the now-PLAYING track and start a
     * spurious overdub — the same reasoning as le_apply_mute_cmd's punch-out
     * clear. */
    tr->pending_record = 0;
    tr->pending_trigger = 0;
    store_i32(&tr->a_pending, 0);
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
  /* A record press during a count-in CANCELS it outright — back to idle, no
   * recording (D9). Any track's press cancels: the count-in is global
   * transport state, not a per-track arm. */
  if (e->count_in_total > 0) {
    le_count_in_reset(e);
    return;
  }
  /* Cancel-vs-auto-commit race grace window (code-review fix; engine_private.h
   * / le_count_in_commit have the full rationale). A press that lands here
   * with count_in_grace_channel == ch arrived one block too late to see
   * count_in_total > 0 above: the count-in's own sample-accurate auto-commit
   * already landed mid the PREVIOUS block and flipped this track to
   * RECORDING. Without this check the press would fall through to the
   * LE_TRACK_RECORDING case below and finalize a near-zero-length defining
   * loop — not what a press racing the commit meant. Treat it as the
   * original cancel-intent instead: abort the just-started take back to
   * EMPTY (handle_clear — the whole rig, since the defining take is the
   * only content that can exist at this point) rather than finalizing it.
   * This is indistinguishable, within one block, from a genuine "count in,
   * then immediately finalize a near-zero loop" double-press; the
   * deliberate choice is cancel-wins, since a press was already in flight
   * before the commit landed. Consumed unconditionally (one-shot) whether
   * or not the state still matches what the commit left. */
  if (e->count_in_grace_channel == ch) {
    e->count_in_grace_channel = -1;
    if (load_i32(&e->tracks[ch].a_state) == LE_TRACK_RECORDING &&
        e->clock.length == 0) {
      handle_clear(e, ch);
      return;
    }
  }
  /* Latched BEFORE any state mutation: a capture start from a held transport
   * unparks the whole loop (le_unpark_stopped) after it lands. */
  const int was_held = le_transport_held(e);
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
        /* The DEFINING press is where a count-in fires (D9: idle transport,
         * no master — with a master this branch isn't taken, and count-in
         * never applies once anything plays). It needs a tempo to click
         * against; with none set, recording starts immediately as always.
         * No RECORD_START / unmute here — the commit at the count-in's
         * downbeat does both when the capture actually begins. */
        {
          const int32_t ci_bars = load_i32(&e->a_count_in_bars);
          if (ci_bars > 0 && load_f32(&e->a_tempo_bpm_bits) > 0.0f &&
              le_count_in_begin(e, ch, ci_bars)) {
            break;
          }
        }
        t->record_pos = 0;
        t->record_start = 0;
        le_loop_clock_reset(&e->clock);
        store_i32(&t->a_state, LE_TRACK_RECORDING);
        le_arm_length_preset_target(e, t); /* A6: may arm an N-bars target */
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
      /* Auto-unmute + unpark: a capture never starts silent, and starting one
       * from a held transport resumes the whole loop. */
      le_capture_start_unmute(e, t, frame);
      if (was_held) le_unpark_stopped(e, frame);
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
       * by le_engine_record before this command). Auto-unmute first — an
       * overdub over a Stop-muted (or parked-muted) track must be audible —
       * and unpark the loop when this start is what wakes a held transport. */
      le_capture_start_unmute(e, t, frame);
      store_i32(&t->a_state, LE_TRACK_OVERDUBBING);
      le_dub_session_start(e, t);
      if (was_held) le_unpark_stopped(e, frame);
      break;
    case LE_TRACK_OVERDUBBING:
      store_i32(&t->a_state, LE_TRACK_PLAYING);
      /* Punch-out is a capture end: land any mute deferred during the dub. */
      le_consume_pending_mutes(e, t, LE_TRACK_PLAYING, 1, frame);
      break;
    default:
      break;
  }
}

static void handle_stop(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  /* A stop press during a count-in cancels it (D9). The stop then proceeds
   * normally — a no-op on the idle transport a count-in requires. */
  if (e->count_in_total > 0) le_count_in_reset(e);
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
    /* Stopping an overdub ends its capture: land any deferred mute. */
    le_consume_pending_mutes(e, t, LE_TRACK_STOPPED, 1, frame);
  }
}

static void handle_play(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  const int was_held = le_transport_held(e);
  le_track* t = &e->tracks[ch];
  if (load_i32(&t->a_state) == LE_TRACK_STOPPED) {
    store_i32(&t->a_state, LE_TRACK_PLAYING);
    /* Playing anything from a held transport unparks the entire loop. */
    if (was_held) le_unpark_stopped(e, frame);
  }
}

/* Applies one lane-mute command, capture-aware. Muting a CAPTURING track
 * punches the capture out (mirroring rec-stop's finalize-then-mute — recording
 * into silence is never meaningful) and defers the mute itself to the capture
 * end via pending_mute, so a capturing track is never observed muted: the
 * mute lands exactly when the capture ends (le_consume_pending_mutes),
 * including across a deferred master-finalize crossfade. The punch-out is
 * logged as the RECORD it is; the deferred mute logs when it lands. Unmutes
 * (and mutes on non-capturing tracks) apply immediately and log verbatim. */
static void le_apply_mute_cmd(le_engine* e, int32_t ch, int32_t lane,
                              int muting, const le_command* cmd,
                              uint64_t frame) {
  le_track* t = &e->tracks[ch];
  le_lane* ln = &t->lanes[lane];
  const int32_t st = load_i32(&t->a_state);
  if (muting &&
      (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING)) {
    ln->pending_mute = 1;
    /* The punch-out supersedes any armed (quantized) action on this track —
     * exactly as apply_command's LE_CMD_RECORD case clears it for a real
     * press. A stale arm would re-fire at the next loop top on the now-
     * PLAYING track and start a spurious overdub (whose capture-start
     * auto-unmute would then override the very mute being applied here). */
    t->pending_record = 0;
    t->pending_trigger = 0;
    store_i32(&t->a_pending, 0);
    /* A master finalize already deferring (xfade_capture > 0) will consume
     * the pending at its completion — no second punch-out. */
    if (t->xfade_capture == 0) {
      le_plog_push(e, frame,
                   (le_command){.code = LE_CMD_RECORD, .arg_i = ch});
      handle_record(e, ch, frame);
    }
    return;
  }
  ln->pending_mute = 0;
  store_i32(&ln->a_muted, muting ? 1 : 0);
  le_plog_push(e, frame, *cmd);
}

static void handle_clear(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  t->record_pos = 0;
  t->start_iter = 0;
  t->pending_record = 0;
  t->od_gain = 0.0f;
  t->xfade_capture = 0; /* cancel any in-flight seam-crossfade deferral */
  /* Same class of per-take audio-thread-local deferral state as xfade_capture
   * above (A6): a stale armed target from an aborted take must not survive
   * into whatever the track records next. Defensive — le_arm_length_preset_
   * target already unconditionally overwrites this at the START of every
   * defining take, so a clear between takes has no reachable window where a
   * stale value would be read, but it costs nothing to reset it here too. */
  t->length_preset_target_frames = 0;
  store_i32(&t->a_pending, 0);
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  /* B3, D18: the track's own division state dies with its content — a
   * re-record decides fresh. The PRIMARY DESIGNATION itself is session-level
   * state (a_primary_track), not per-track, and is deliberately untouched
   * here even when [t] is the primary being cleared (D18: persists through
   * clear; no auto-reassignment). */
  store_i32(&t->a_sync_divisor, 0);
  /* Free mode (B2b): this track's own clock (if it had one established)
   * dies with its content, exactly like the master dies with the last
   * track's content below — unconditional and cheap (a no-op reset when
   * already dormant, i.e. every mode but Free), so "a track reading EMPTY
   * has a dormant free_clock" is an invariant provable by construction
   * rather than by tracing every path that can reach EMPTY (this one, and
   * LE_CMD_UNDO_TO_EMPTY below). */
  le_loop_clock_reset(&t->free_clock);
  t->free_iteration = 0;
  e->track_viz_bucket[ch] = -1;
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
   * rather than silently muted by a leftover Stop (or a pending mid-capture
   * mute whose capture this clear just destroyed). */
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    store_i32(&t->lanes[l].a_muted, 0);
    t->lanes[l].pending_mute = 0;
  }
  /* If every track is now empty, reset the master so a new loop can be defined.
   * Buffers are not zeroed here (RT-unsafe); a re-record overwrites a full loop
   * before the track is heard, so stale data never plays. This runs BEFORE the
   * ack bump below: the bump's release pairs with le_effective_state's acquire,
   * so a control thread that has seen this clear acked is guaranteed to also
   * see the master reset — e.g. the first-wrap pre-arm gate reading
   * a_master_len after an internal grid-redefine clear must read 0, never the
   * dead grid's length (a stale read there would pre-arm, and strand a
   * cap-sized slot on, the defining capture the gate exists to skip). */
  int all_empty = 1;
  for (int32_t k = 0; k < e->track_count; ++k) {
    if (load_i32(&e->tracks[k].a_state) != LE_TRACK_EMPTY) {
      all_empty = 0;
      break;
    }
  }
  if (all_empty) {
    le_loop_clock_reset(&e->clock);
    e->loop_iteration = 0;
    store_i32(&e->a_master_len, 0);
    store_i32(&e->a_master_pos, 0);
    /* The grid dies with its loop — but ONLY the loop-derived part. The tempo
     * value and its source survive (D6 dead-tempo survival: the next defining
     * loop rounds to the surviving tempo instead of re-deriving), and this
     * all-empty reset is also exactly what releases the D6 tempo lock. */
    store_i32(&e->a_loop_bars, 0);
    store_i32(&e->a_current_beat, 0);
    e->grid_total_beats = 0;
    e->grid_prev_beat = -1;
    /* The tap pair dies with the lock: a tap latched before the D6 lock
     * engaged must not pair with the first tap after this release (a
     * record+clear span inside the 0.2–2 s window would otherwise publish a
     * plausible-looking but meaningless TAPPED tempo). */
    e->has_tap = 0;
    e->last_tap_frame = 0;
    /* Clear the loop waveform so a re-record starts from silence. */
    e->loop_viz_bucket = -1;
    for (int i = 0; i < LE_VIZ_POINTS; ++i) {
      store_f32(&e->a_loop_viz[i], 0.0f);
      for (int t = 0; t < e->track_count; ++t) {
        store_f32(&e->a_track_viz[t][i], 0.0f);
      }
    }
  }
  atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
  /* Undo/redo stacks and each lane's a_live are reset by le_engine_clear on the
   * control thread; the audio thread only resets the state/transport here. */
}

/* Per-lane / per-monitor effects DSP (the effect kernels, the phase-vocoder /
 * PSOLA octaver, the Freeverb reverb, and the chain runner) moved to engine_fx.c
 * (S1). The cross-TU surface and the PV/PSOLA tuning constants live in
 * engine_fx.h. */

/* Completes a deferred crossfade-finalize of the defining master (set up by
 * request_master_finalize once xfade_capture frames of overlap are captured).
 * Equal-gain (linear) crossfade of the captured continuation [len, len+F) into
 * the loop head [0, F): each head sample morphs from the continuation (which
 * follows len-1 naturally) into the original head, so the wrap len-1 -> 0 is
 * continuous. Equal-gain — not equal-power — because the two signals are the
 * performance and its own continuation, i.e. highly correlated: linear weights
 * sum to exactly 1.0 so correlated material passes at unity, where equal-power
 * (sin/cos) would bump it up to sqrt(2)x (+3 dB) at mid-fade (#256). The loop
 * is then finalized at exactly `len`. */
static void finalize_master_xfade(le_engine* e, le_track* t, uint64_t frame) {
  const int32_t len = t->xfade_len;
  const int32_t F = seam_xfade_frames(e);
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    float* b = t->lanes[l].pool[load_i32(&t->lanes[l].a_live)];
    if (b == NULL) continue;
    for (int32_t i = 0; i < F; ++i) {
      const float x = (float)i / (float)F;  /* 0..1 across the fade */
      const float w_in = x;                 /* original head fades in */
      const float w_out = 1.0f - x;         /* continuation fades out */
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

/* Drops the last `drop` captured frames of a RECORDING non-defining track
 * (audio thread; A3's quantized record END, round-down case): zeroes them in
 * every lane's live buffer — mirroring the record write head's own mapping,
 * including the fixed-multiple wrap — and rewinds record_pos, so the finalize
 * that follows lands exactly on the rounded-down grid boundary. The zeroed
 * region was silence before the capture began (le_prepare_new_capture memsets
 * the take's buffers), so this restores the pre-capture state. Bounded: a
 * round-down drop is under half a subdivision unit (<= half a bar), a
 * one-shot cost on the press's apply, not a per-frame one. */
static void le_truncate_capture_tail(le_engine* e, le_track* t, int32_t drop) {
  if (drop <= 0 || drop > t->record_pos) return;
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t offset = load_i32(&e->a_record_offset);
  const int32_t k = le_effective_multiple(e, ch);
  const int32_t known_len =
      (k >= 1 && e->clock.length > 0) ? k * e->clock.length : 0;
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    float* b = t->lanes[l].pool[load_i32(&t->lanes[l].a_live)];
    if (b == NULL) continue;
    for (int64_t p = (int64_t)t->record_pos - drop; p < t->record_pos; ++p) {
      int64_t w = p - offset; /* the same mapping the write head used */
      if (w < 0) continue;    /* latency-window frames were never written */
      if (known_len > 0 && w >= known_len) w %= known_len;
      if (w >= e->max_loop_frames) continue;
      b[(int32_t)w] = 0.0f;
    }
  }
  t->record_pos -= drop;
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
        le_track* t = &e->tracks[cmd->arg_i];
        /* arg_f carries the trigger: 0 = grid (quantize), 1 = input level
         * (sound-activated auto-record), 2 = Band section transport (B3b) —
         * see LE_CMD_ARM's doc, loopy_engine_api.h. Only 0/1/2 are ever
         * pushed (le_engine_record / le_engine_toggle_section); the >= 1.5
         * split keeps 1.0f mapping to 1 exactly, unchanged from before B3b. */
        const int trig = cmd->arg_f >= 1.5f ? 2 : (cmd->arg_f != 0.0f ? 1 : 0);
        int64_t sn, sd;
        if (trig == 0 && load_i32(&t->a_state) == LE_TRACK_RECORDING &&
            e->clock.length > 0 && le_live_subdiv_ratio(e, &sn, &sd)) {
          /* Quantized record END (D8): the capture must end on the NEAREST
           * loop-locked subdivision boundary. Strictly nearer behind ->
           * truncate right now (drop the tail past that boundary and finalize);
           * nearer ahead — or the exact midpoint, which rounds up — -> keep
           * capturing and let the per-frame boundary check fire the finalize.
           * A truncation must leave at least one whole subdivision unit of
           * capture (min 1 unit); anything shorter rounds up instead. Only the
           * non-defining path: the defining master (clock.length == 0 while it
           * records) never arms its end — its finalize keeps the seam-crossfade
           * machinery and A1's whole-bar rounding.
           *
           * DESIGN DECISION (code review, A3 follow-up) — min-1-unit's scope
           * under a live granularity change: this check runs ONCE, here, at
           * the press — using whichever division is live AT THE PRESS. When
           * it fails (round-down would leave < 1 unit) the arm falls through
           * to the plain pending_record wait below, which is STATELESS: no
           * target boundary or armed division is latched anywhere, so the
           * eventual fire re-reads le_live_subdiv_ratio's CURRENT value (via
           * advance_transport_frame's boundary check) at the moment it
           * actually fires — the same "live division, no latching" rule as
           * every other pending re-evaluation in A3 (the record-START and
           * granularity-change-while-armed tests rely on exactly this). A
           * granularity change during the wait (e.g. QUARTER -> SIXTEENTH)
           * is therefore honored immediately, on the SIXTEENTH's own next
           * boundary — which can be a shorter span, in SIXTEENTH units, than
           * the QUARTER unit the original press's min-1-unit check reasoned
           * about. This is chosen deliberately (option (a) of two): "min 1
           * unit" means "at least one unit of whichever division is live
           * when the boundary fires", not a length invariant carried from
           * the press — latching the press-time target length (option (b))
           * would need new per-track state (the target unit length, or an
           * armed-division snapshot) purely to serve a rare
           * disarm-mid-granularity-change edge case, contradicting A3's
           * minimal-ABI-growth, no-latched-arm-state design throughout.
           * Pinned by test_quantize_div_min_one_unit_reevaluates_on_
           * granularity_change. */
          const int32_t len = e->clock.length;
          const int32_t pos = e->clock.position;
          const int32_t idx = le_grid_loop_subdiv_at(pos, len, sn, sd);
          const int32_t pb = le_grid_loop_subdiv_start(idx, len, sn, sd);
          const int32_t nb = le_grid_loop_next_subdiv(pos, len, sn, sd);
          const int32_t behind = pos - pb;
          const int32_t ahead = nb > pos ? nb - pos : 0;
          /* record_pos is phase-locked to the master, so the boundary behind
           * sits exactly `behind` frames back on the capture timeline. The
           * span check is the rational min-1-unit test:
           * span >= len/subdivs  <=>  span * sub_num >= len * sub_den. */
          const int64_t span =
              (int64_t)(t->record_pos - behind) - (int64_t)t->record_start;
          if (behind >= 0 && behind < ahead &&
              span * sn >= (int64_t)len * sd) {
            le_truncate_capture_tail(e, t, behind);
            /* The truncated boundary is `behind` frames EARLIER than `frame`
             * (this ARM command's buffer-start perf-log tag): `frame` and
             * `pos` are read at the same instant (perf_frame_base is
             * snapshotted before the ring drains, clock.position is
             * unchanged since the previous buffer — see le_engine_process),
             * so the boundary's own perf-log frame is frame - behind, not
             * frame itself. Passing the raw (too-late) `frame` here would
             * inflate finalize_new_track's LE_PLOG_RECORD_END tag by `behind`
             * frames, and perf_render.c's le_pr_record_end_phase folds that
             * tag straight into (end_frame - start_frame) — an export render
             * of a round-down-truncated take would start its finalized
             * segment `behind` frames late, at the wrong loop phase. Live
             * playback is unaffected (it reads clock.position directly, not
             * this log tag) — export-render only. `frame` only grows while
             * perf recording is armed (0 otherwise) and `behind` is bounded
             * to under one subdivision unit, so underflow should not occur,
             * but the subtraction is clamped defensively rather than trusted
             * to never see it. */
            const uint64_t end_frame =
                frame > (uint64_t)behind ? frame - (uint64_t)behind : 0;
            handle_record(e, cmd->arg_i, end_frame); /* finalize at the boundary */
            break;
          }
        }
        t->pending_record = 1;
        t->pending_trigger = trig;
        store_i32(&t->a_pending, 1);
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
      handle_play(e, cmd->arg_i, frame);
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
      /* The capture (if any) is gone: a mute deferred during it must not
       * ambush some future capture's end. */
      for (int l = 0; l < LE_MAX_LANES; ++l) {
        t->lanes[l].pending_mute = 0;
      }
      store_i32(&t->a_pending, 0);
      store_i32(&t->a_state, LE_TRACK_EMPTY);
      le_track_set_len(t, 0);
      store_i32(&t->a_multiple, 1);
      store_i32(&t->a_sync_divisor, 0); /* B3: division state dies too */
      /* Free mode (B2b): same invariant-preserving reset as handle_clear's —
       * a track reading EMPTY must never carry an established free_clock.
       * Cheap no-op outside Free mode (already dormant there). */
      le_loop_clock_reset(&t->free_clock);
      t->free_iteration = 0;
      e->track_viz_bucket[cmd->arg_i] = -1;
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
        const int was_held = le_transport_held(e);
        /* The restored loop may differ in length from whatever the leftover
         * armed shadows were sized for — drop them (control reclaimed). */
        le_dub_drop_armed(t);
        /* Free/Song mode (B2b, broadened to SONG by B4): restore THIS
         * track's own clock — there is no shared base to be a multiple of
         * (Multi/Sync/Band's `base`/`k` below is meaningless with
         * independent per-track lengths). */
        const int32_t mode = load_i32(&e->a_looper_mode);
        if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
          le_loop_clock_set_length(&t->free_clock, len);
          t->free_iteration = 0;
          store_i32(&t->a_multiple, 1);
          store_i32(&t->a_sync_divisor, 0); /* Free/Song mode never divides */
        } else {
          const int32_t base = e->clock.length > 0 ? e->clock.length : len;
          le_restore_multiple_or_divisor(t, base, len);
        }
        le_track_set_len(t, len);
        t->start_iter = 0;
        store_i32(&t->a_state, LE_TRACK_PLAYING);
        /* The from-EMPTY edge case of redo (LE_PLOG_REDO — see the UNDO_TO_
         * EMPTY case above for why every redo path logs the same code). */
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_REDO, .arg_i = ch});
        /* A resurrect that starts playback from a held transport unparks the
         * whole loop, like any other start. */
        if (was_held) le_unpark_stopped(e, frame);
      }
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_RESTORE_CLEAR: {
      /* Undo of an undoable clear: the control thread already swapped a_live
       * back to the erased take and pushed the mute restore ahead of us; put the
       * transport back here. Distinct from REDO_FROM_EMPTY on two counts — the
       * state may be STOPPED rather than PLAYING, and the grid may need
       * re-establishing rather than merely reading. */
      const int32_t ch = cmd->restore.channel;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      const int32_t len = cmd->restore.len;
      if (load_i32(&t->a_state) == LE_TRACK_EMPTY && len > 0) {
        /* The restored loop may differ in length from whatever the leftover
         * armed shadows were sized for — drop them (control reclaimed). */
        le_dub_drop_armed(t);
        /* Re-establish the grid this clear reset. A clear only resets the master
         * once every track is empty (handle_clear's all-empty path), so this
         * fires for the last track cleared / a whole-rig clear, and is a no-op
         * when a sibling kept the clock running. Restoring the recorded base —
         * not this track's own len — is what keeps a track that was several
         * base loops long coming back at the right multiple. */
        if (e->clock.length == 0 && cmd->restore.master_len > 0) {
          le_plog_push(e, frame,
                       (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED,
                                    .arg_i = cmd->restore.master_len});
          le_loop_clock_set_length(&e->clock, cmd->restore.master_len);
          e->loop_iteration = 0;
          store_i32(&e->a_master_len, cmd->restore.master_len);
          /* ...and the tempo grid: the clear's all-empty reset dropped the
           * loop-derived grid while the tempo value survived (D6). Without
           * this the restored state would be locked (content + source) yet
           * grid-less — tempo commands permanently no-ops. With a surviving
           * tempo sync_grid_to_loop reproduces the pre-clear grid exactly;
           * with sync off it correctly stays grid-free. */
          sync_grid_to_loop(e, cmd->restore.master_len);
        }
        /* Free/Song mode (B2b, broadened to SONG by B4): restore THIS
         * track's own clock, mirroring LE_CMD_REDO_FROM_EMPTY above —
         * restore.master_len is always 0 for a Free/Song-mode clear
         * (a_master_len is never set in either mode), so the block above is
         * already a no-op here; only the per-track base/k computation below
         * needs the same mode branch. */
        const int32_t mode = load_i32(&e->a_looper_mode);
        if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
          le_loop_clock_set_length(&t->free_clock, len);
          t->free_iteration = 0;
          store_i32(&t->a_multiple, 1);
          store_i32(&t->a_sync_divisor, 0); /* Free/Song mode never divides */
        } else {
          const int32_t base = e->clock.length > 0 ? e->clock.length : len;
          le_restore_multiple_or_divisor(t, base, len);
        }
        le_track_set_len(t, len);
        t->start_iter = 0;
        store_i32(&t->a_state, cmd->restore.state);
        /* The clear-restore edge case of undo: same semantic code as every
         * other undo path (see LE_CMD_UNDO_TO_EMPTY), so a downstream consumer
         * never needs to know which internal path fired. */
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_UNDO, .arg_i = ch});
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
        /* Track-addressed mute maps to lane 0 (backward compatibility),
         * capture-aware like the per-lane command below. */
        le_apply_mute_cmd(e, cmd->arg_i, 0, cmd->arg_f != 0.0f, cmd, frame);
      }
      break;
    /* ---- tempo grid (see the helper block above finalize_master). Not
     * perf-logged: in this part none of these changes audible output. */
    case LE_CMD_SET_TEMPO: {
      if (le_tempo_locked(e)) break; /* D6: rejected (no-op) while locked */
      float bpm = cmd->arg_f;
      /* NaN-rejecting clamp: !(x >= MIN) is true for NaN as well as for low
       * values, so a non-finite bpm can never reach the grid math (a NaN
       * interval would spin le_grid_next_boundary forever). */
      if (!(bpm >= LE_GRID_TEMPO_MIN)) {
        bpm = LE_GRID_TEMPO_MIN;
      } else if (bpm > LE_GRID_TEMPO_MAX) {
        bpm = LE_GRID_TEMPO_MAX;
      }
      store_f32(&e->a_tempo_bpm_bits, bpm);
      store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_MANUAL);
      regrid_surviving_master(e);
      break;
    }
    case LE_CMD_SET_TIME_SIGNATURE: {
      if (le_tempo_locked(e)) break; /* D6: rejected (no-op) while locked */
      const int32_t num = cmd->arg_i;
      const int32_t den = (int32_t)cmd->arg_f;
      /* Re-validated here (the exported wrapper already rejects) so a raw
       * le_engine_post_command can never publish an unsupported signature. */
      if (!le_grid_signature_valid(num, den)) break;
      store_i32(&e->a_ts_num, num);
      store_i32(&e->a_ts_den, den);
      /* Unlocked with a surviving grid (the undo-to-empty edge): recompute
       * bars AND beats against the surviving master — a new signature changes
       * the bar length, so keeping the old bar count would be as stale as
       * counting the old numerator. */
      regrid_surviving_master(e);
      break;
    }
    case LE_CMD_TAP_TEMPO:
      if (!le_tempo_locked(e)) handle_tap(e); /* D6: taps ignored wholesale */
      break;
    case LE_CMD_SET_SYNC_TEMPO:
      /* A settings toggle, deliberately not locked: it only governs FUTURE
       * defining-loop finalizes (sync_grid_to_loop), never a live grid. */
      store_i32(&e->a_sync_tempo, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    case LE_CMD_SET_QUANTIZE_DIV: {
      int32_t d = cmd->arg_i;
      if (d < LE_GRID_DIV_OFF) d = LE_GRID_DIV_OFF;
      if (d > LE_GRID_DIV_SIXTEENTH) d = LE_GRID_DIV_SIXTEENTH;
      store_i32(&e->a_quantize_div, d);
      break;
    }
    /* ---- looper mode (B2a, D4; see le_looper_mode_locked above). Not
     * perf-logged: in this part a mode switch changes no audible output. */
    case LE_CMD_SET_LOOPER_MODE: {
      if (le_looper_mode_locked(e)) break; /* D4: rejected (no-op) while locked */
      int32_t m = cmd->arg_i;
      if (m < LE_LOOPER_MODE_MULTI || m > LE_LOOPER_MODE_FREE) {
        break; /* re-validated here; the exported wrapper already rejects */
      }
      store_i32(&e->a_looper_mode, m);
      break;
    }
    /* ---- primary track (B3, D18; see LE_CMD_CROWN_PRIMARY's doc,
     * loopy_engine_api.h). Accepted in ANY mode — the crown is a persistent
     * per-session designation, not gated by the D4 mode lock or by mode
     * itself; it simply has no effect outside Sync/Band
     * (le_sync_quantize_active). Not perf-logged, for the same reason as
     * LE_CMD_SET_LOOPER_MODE above. */
    case LE_CMD_CROWN_PRIMARY: {
      if (!valid_channel(e, cmd->arg_i)) break;
      store_i32(&e->a_primary_track, cmd->arg_i);
      break;
    }
    /* ---- One Shot (B4; see LE_CMD_SET_ONE_SHOT's doc, loopy_engine_api.h).
     * Accepted in ANY mode, like LE_CMD_CROWN_PRIMARY above — a persistent
     * per-track setting, not gated by the D4 mode lock. Only consumed by
     * advance_track_clock_frame's free_clock wrap check below, so it is
     * inert outside Free/Song by construction. Not perf-logged, for the
     * same reason as LE_CMD_SET_LOOPER_MODE / LE_CMD_CROWN_PRIMARY. */
    case LE_CMD_SET_ONE_SHOT: {
      if (!valid_channel(e, cmd->arg_i)) break;
      store_i32(&e->tracks[cmd->arg_i].a_one_shot, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    }
    /* ---- MIDI clock (Phase C/E, D15; see LE_CMD_SET_CLOCK_MODE's doc,
     * loopy_engine_api.h). Not perf-logged, for the same reason as
     * LE_CMD_SET_LOOPER_MODE above. */
    case LE_CMD_SET_CLOCK_MODE: {
      const int32_t m = cmd->arg_i;
      /* Re-validated here (the exported wrapper already rejects RECEIVE and
       * anything else) so a raw le_engine_post_command can never publish an
       * unimplemented/out-of-range clock mode. */
      if (m != LE_CLOCK_OFF && m != LE_CLOCK_SEND) break;
      store_i32(&e->a_clock_mode, m);
      break;
    }
    /* ---- click + count-in (A2; see the helper block above finalize_master).
     * Not perf-logged: the click never reaches the performance capture (it
     * sums after the perf tap by design), so its configuration is invisible
     * to a replay of the captured performance. Each value is re-clamped here
     * (the exported wrappers already validate) so a raw le_engine_post_command
     * can never publish an out-of-range value. */
    case LE_CMD_SET_CLICK_MODE: {
      int32_t m = cmd->arg_i;
      if (m < LE_CLICK_OFF) m = LE_CLICK_OFF;
      if (m > LE_CLICK_PLAY_REC) m = LE_CLICK_PLAY_REC;
      store_i32(&e->a_click_mode, m);
      break;
    }
    case LE_CMD_SET_CLICK_OUTPUT:
      atomic_store_explicit(&e->a_click_mask, cmd->trackmask.mask,
                            memory_order_relaxed);
      break;
    case LE_CMD_SET_CLICK_VOLUME: {
      float v = cmd->arg_f;
      /* NaN-rejecting clamp (same rationale as LE_CMD_SET_TEMPO's). */
      if (!(v >= 0.0f)) {
        v = 0.0f;
      } else if (v > LE_MAX_GAIN) {
        v = LE_MAX_GAIN;
      }
      store_f32(&e->a_click_volume_bits, v);
      break;
    }
    case LE_CMD_SET_COUNT_IN: {
      int32_t bars = cmd->arg_i;
      if (bars < 0) bars = 0;
      if (bars > LE_COUNT_IN_MAX_BARS) bars = LE_COUNT_IN_MAX_BARS;
      store_i32(&e->a_count_in_bars, bars);
      /* ANY mid-count-in change cancels the count-in in flight — not just a
       * change to 0 (code-review fix). The running countdown was frozen at
       * le_count_in_begin from whatever bars was in effect THEN
       * (count_in_total/count_in_beats/count_in_fpb); republishing a
       * different nonzero value here would leave the published setting and
       * the actually-counting schedule silently diverged until the count-in
       * ends on the STALE value. Cancelling and letting the next record
       * press pick up the freshly-published value is simpler and consistent
       * with the existing 0-cancels precedent. */
      if (e->count_in_total > 0) le_count_in_reset(e);
      break;
    }
    /* ---- track length presets (A6, D17; see the helper block above
     * finalize_master). Not perf-logged, like the tempo grid / click block
     * above — state only, no direct audible effect at the moment it's set. */
    case LE_CMD_SET_LENGTH_PRESET: {
      if (!valid_channel(e, cmd->arg_i)) break;
      int32_t bars = (int32_t)cmd->arg_f;
      if (bars < 0) bars = 0;
      if (bars > LE_LENGTH_PRESET_MAX_BARS) bars = LE_LENGTH_PRESET_MAX_BARS;
      store_i32(&e->tracks[cmd->arg_i].a_length_preset_bars, bars);
      break;
    }
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
      le_apply_mute_cmd(e, ch, lane, cmd->lanef.value != 0.0f, cmd, frame);
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
      /* KNOWN GAP (B2b; B4 extends the same guard to SONG), guarded
       * (adversarial-review BUG 2 fix): this command establishes ONE shared
       * `base` length for every imported track via a whole-loop multiple —
       * correct for Multi/Sync/Band, but Free AND Song mode have no single
       * shared loop to import onto (song-mode-spec §2: Song's transport is
       * "structurally identical" to Free's — independent per-track lengths,
       * no shared grid). The control-thread wrapper (le_engine_commit_
       * session, engine_session.c) already rejects this outright when
       * a_looper_mode is FREE or SONG, so this command should never reach
       * here in either mode from the normal session-import path — but
       * le_engine_post_command is a raw FFI escape hatch that can post ANY
       * command directly, bypassing that wrapper. Without this second
       * guard, a raw post here would set e->clock / a_master_len to a
       * nonzero value while FREE/SONG — the exact invariant ("the shared
       * master clock stays permanently dormant in this mode") every other
       * Free/Song-mode code path in this file depends on staying true
       * (advance_transport_frame's shared-clock tick and mix_tracks_frame's
       * Multi-mode defaults would otherwise spuriously activate alongside
       * the per-track Free/Song-mode paths). It would ALSO, independently,
       * leave imported tracks marked PLAYING with no established free_clock
       * of their own — reproducing the exact "playback stuck reading
       * position 0 forever" bug class this PR already found and fixed once
       * in mix_tracks_frame. Free/Song-mode session import (restoring each
       * track's own free_clock from the manifest, per D12's phase-marked
       * freeLengthFrames field) is out of B2b/B4's engine-only scope — the
       * part-2 plan has no B2b/B4 manifest/session task (that lands with
       * A7/B5c) — so this simply declines the whole commit rather than
       * corrupting state or silently mishandling it. */
      {
        const int32_t mode = load_i32(&e->a_looper_mode);
        if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) break;
      }
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
      /* A session import replaces the loop wholesale: the pre-import beat
       * grid (if any) described the OLD loop and must not be applied to the
       * new one. Reset the loop-derived grid; the tempo value and source
       * survive (D6). Deriving a grid for imported audio from the manifest is
       * A7's job — until then an import is grid-free. */
      store_i32(&e->a_loop_bars, 0);
      store_i32(&e->a_current_beat, 0);
      e->grid_total_beats = 0;
      e->grid_prev_beat = -1;
      for (int32_t t = 0; t < e->track_count; ++t) {
        le_track* tr = &e->tracks[t];
        if (load_i32(&tr->a_state) != LE_TRACK_EMPTY) continue;
        const int32_t len = load_i32(&tr->lanes[0].a_len);
        if (len <= 0) continue;
        int32_t k = len / base;
        if (k < 1) k = 1;
        store_i32(&tr->a_multiple, k);
        /* Session import never encodes a B3 Sync/Band division (out of this
         * part's manifest scope, deferred to B5c like every other B3 UI/
         * session surface) — always the ordinary whole-multiple path, and
         * defensively zeroed so a track that was a division before some
         * prior clear+reimport cycle never leaks a stale divisor. */
        store_i32(&tr->a_sync_divisor, 0);
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

/* ---- click + count-in per-frame steps (A2) ----
 *
 * The click sums into its masked output channels AFTER perf_tap_master_frame
 * and BEFORE viz_tap_frame (index Architecture §3, D5). Consequences, all
 * intended: it bypasses master gain and the limiter (click volume is its only
 * gain stage), it is absent from output metering and the loop viz (both fed
 * upstream), and it is excluded from performance capture — and therefore from
 * every bounce/export — by construction. */

/* The frame's click audibility gate (le_click_mode semantics). `st` is the
 * frame's per-track state snapshot from mix_tracks_frame. A count-in overrides
 * every mode but OFF: the whole point of counting is hearing it. */
static inline int le_click_gate(const le_engine* e, int32_t mode, int tc,
                                const int32_t* st) {
  if (e->count_in_total > 0) return 1;
  switch (mode) {
    case LE_CLICK_REC:
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_RECORDING || st[t] == LE_TRACK_OVERDUBBING) {
          return 1;
        }
      }
      return 0;
    case LE_CLICK_REC_FIRST:
      /* Only the DEFINING first-layer recording (no master yet). */
      if (e->clock.length != 0) return 0;
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_RECORDING) return 1;
      }
      return 0;
    case LE_CLICK_PLAY_REC:
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_RECORDING ||
            st[t] == LE_TRACK_OVERDUBBING) {
          return 1;
        }
      }
      return 0;
    default:
      return 0;
  }
}

/* Completes a count-in: the counting state drops and the DEFINING recording
 * begins on count_in_channel — the same start the immediate press would have
 * done, deferred to land exactly on the bar-1 downbeat (the NEXT frame is the
 * first one captured: mix_tracks_frame has already run for this frame, so the
 * capture window opens at press + count_in_total frames precisely). The
 * free-run click phase re-anchors here so the recording's first frame carries
 * the downbeat click when the mode gates it in.
 *
 * count_in_grace_channel opens a one-block cancel-vs-commit race window
 * (code-review fix, engine_private.h has the full rationale): this can fire
 * MID-block, one block before commands next drain, so a cancel press already
 * in flight when this lands would otherwise arrive at handle_record too late
 * to see count_in_total > 0. le_engine_process clears the window back to -1
 * right after every block's command-drain loop, so it survives for exactly
 * the one drain immediately following this commit's block. */
static void le_count_in_commit(le_engine* e, uint64_t frame) {
  const int32_t ch = e->count_in_channel;
  le_count_in_reset(e);
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  /* Both re-checked: a clear/undo cannot have made this stale (counting only
   * ever starts against an empty rig), but the commit must never stomp state
   * if some future path breaks that invariant. */
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY || e->clock.length != 0) return;
  e->count_in_grace_channel = ch; /* open the one-block cancel-race window */
  le_dub_drop_armed(t);
  t->record_pos = 0;
  t->record_start = 0;
  le_loop_clock_reset(&e->clock);
  store_i32(&t->a_state, LE_TRACK_RECORDING);
  le_arm_length_preset_target(e, t); /* A6: may arm an N-bars target */
  le_plog_push(e, frame,
               (le_command){.code = LE_PLOG_RECORD_START, .arg_i = ch});
  le_capture_start_unmute(e, t, frame);
  e->click_free_running = 1;
  e->click_free_frame = 0;
  e->click_free_beat = 0;
}

/* Advances the count-in / free-running click schedulers and synthesizes the
 * click voice into the masked output channels for one frame. `click_on` is
 * the frame's audibility gate (le_click_gate). Dormant cost with the
 * defaults: the single fused compare at the top (all three terms are
 * audio-thread-local ints that read 0). */
static inline void click_frame(le_engine* e, float* out, uint32_t f,
                               int ch_out, int click_on, uint32_t mask,
                               float vol, int sr, uint64_t frame) {
  /* click_free_running joins the fuse so a gate that fell while no burst was
   * sounding still gets its one clean-up pass (the free-run reset below) —
   * after that the whole term reads 0 again and this stays one compare. */
  if ((click_on | e->count_in_total | e->click_remaining |
       e->click_free_running) == 0) {
    return;
  }

  if (e->count_in_total > 0) {
    /* Counting in: beats render from their index against the frozen nominal
     * fpb (no accumulation drift), audible in every mode but OFF. */
    if (e->count_in_beat < e->count_in_beats &&
        e->count_in_elapsed >=
            (int32_t)llround((double)e->count_in_beat * e->count_in_fpb)) {
      const int32_t num = load_i32(&e->a_ts_num);
      const int32_t bar_beat = num > 0 ? e->count_in_beat % num : 0;
      if (click_on) trigger_click(e, bar_beat == 0);
      store_i32(&e->a_current_beat, bar_beat);
      store_i32(&e->a_count_in_beats_left,
                e->count_in_beats - e->count_in_beat);
      e->count_in_beat++;
    }
    e->count_in_elapsed++;
    if (e->count_in_elapsed >= e->count_in_total) {
      le_count_in_commit(e, frame); /* the downbeat: recording starts */
    }
  } else {
    /* Free-running scheduler: with no loop-locked grid (defining recording,
     * or sync-off playback) and a tempo set, the beat phase runs on the
     * nominal grid, re-anchoring its downbeat whenever it activates. The
     * loop-locked case is grid_beat_frame's. */
    const int free_run =
        click_on && (e->grid_total_beats <= 0 || e->clock.length <= 0);
    if (!free_run) {
      e->click_free_running = 0;
    } else {
      if (!e->click_free_running) {
        e->click_free_running = 1;
        e->click_free_frame = 0;
        e->click_free_beat = 0;
      }
      if (e->click_free_frame == 0) {
        /* Beat boundary: refresh fpb from the published tempo (a pre-content
         * tempo change retunes the next beat), click, publish the beat. */
        const float bpm = load_f32(&e->a_tempo_bpm_bits);
        if (bpm > 0.0f) {
          const int32_t fpb = (int32_t)llround(60.0 * (double)sr / (double)bpm);
          e->click_free_fpb = fpb > 0 ? fpb : 1;
          const int32_t num = load_i32(&e->a_ts_num);
          trigger_click(e, e->click_free_beat == 0);
          store_i32(&e->a_current_beat,
                    num > 0 ? e->click_free_beat % num : 0);
        } else {
          e->click_free_fpb = 0; /* no tempo: nothing to click against */
        }
      }
      if (e->click_free_fpb > 0 && ++e->click_free_frame >= e->click_free_fpb) {
        e->click_free_frame = 0;
        const int32_t num = load_i32(&e->a_ts_num);
        e->click_free_beat = num > 0 ? (e->click_free_beat + 1) % num : 0;
      }
    }
  }

  /* Synthesis: one sample of the decaying sine burst, summed into the masked
   * channels only. Post-master-bus by design — see the block comment above. */
  if (e->click_remaining > 0) {
    const float env = (float)e->click_remaining / (float)e->click_len;
    const float s = LE_CLICK_AMP * env * sinf(e->click_phase) * vol;
    e->click_phase += LE_CLICK_TWO_PI * e->click_freq / (float)sr;
    if (e->click_phase > LE_CLICK_TWO_PI) e->click_phase -= LE_CLICK_TWO_PI;
    e->click_remaining--;
    if (mask != 0u) {
      float* o = out + (size_t)f * (size_t)ch_out;
      for (int c = 0; c < ch_out; ++c) {
        if (mask & (1u << c)) o[c] += s;
      }
    }
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

/* Free/Song mode (B2b, broadened to SONG by B4): the per-track twin of
 * viz_tap_frame, above — bucketed against each track's OWN clock instead of
 * the (permanently dormant, Free/Song-mode) master. There is no single
 * shared loop in either mode, so a_loop_viz (the mixed/master waveform) is
 * simply never touched here — viz_tap_frame's own `e->clock.length > 0`
 * gate already keeps IT untouched for the exact same reason. Called as a
 * single guarded call from le_engine_process, immediately after
 * viz_tap_frame, only when a_looper_mode is FREE or SONG. */
static inline void free_track_viz_tap_frame(le_engine* e, int tc,
                                            const float* frame_trk_peak) {
  for (int t = 0; t < tc; ++t) {
    const le_loop_clock* c = &e->tracks[t].free_clock;
    if (c->length <= 0) continue; /* this track's clock isn't established yet */
    int32_t bucket = (int32_t)((int64_t)c->position * LE_VIZ_POINTS / c->length);
    if (bucket >= LE_VIZ_POINTS) bucket = LE_VIZ_POINTS - 1;
    if (bucket != e->track_viz_bucket[t]) {
      const int32_t prev = e->track_viz_bucket[t];
      if (prev >= 0 && prev < LE_VIZ_POINTS) {
        store_f32(&e->a_track_viz[t][prev], e->track_viz_accum[t]);
      }
      e->track_viz_bucket[t] = bucket;
      e->track_viz_accum[t] = 0.0f;
    }
    if (frame_trk_peak[t] > e->track_viz_accum[t]) {
      e->track_viz_accum[t] = frame_trk_peak[t];
    }
  }
}

/* Free/Song mode (B2b, broadened to SONG by B4): advances track [ch]'s own
 * clock by one frame, mirroring le_loop_clock_tick's per-master-clock shape
 * but scoped to a single track — ticks (and bumps the track's own wrap
 * counter) only while that track is actually sounding (PLAYING or
 * OVERDUBBING); a RECORDING, STOPPED, or EMPTY track's own clock holds its
 * position (no "hold the whole rig at the top" concept per-track in either
 * mode — a stopped Free/Song-mode track simply pauses and resumes where it
 * left off, same as playback silently skipping it in mix_tracks_frame while
 * stopped). No-op (by construction) when this track's clock isn't
 * established yet (length <= 0): a track still on its own first/defining
 * recording never reaches PLAYING/OVERDUBBING before finalize_master sets
 * free_clock, so this is a defensive belt more than a reachable guard.
 *
 * One Shot (B4, Sheeran manual §5.9.4): the wrap this function detects
 * (le_loop_clock_tick's boundary return — this track's OWN clock completing
 * one full lap) is the ONLY per-track transport-wrap event the engine
 * currently instruments, which is exactly why One Shot's "stop instead of
 * loop" behavior is wired HERE and only reachable in Free/Song (the two
 * modes that call this function at all — see the call site's mode guard,
 * advance_transport_frame). A one-shot track that wraps stops immediately:
 * the transition mirrors handle_stop's own PLAYING/OVERDUBBING -> STOPPED
 * branch exactly (same pending-mute landing via le_consume_pending_mutes),
 * so an overdub in flight ends its capture and drains/retires through the
 * ordinary dub machinery — a manual Stop press produces byte-identical
 * downstream behavior. Checked AFTER free_iteration bumps: a one-shot track
 * still completed the lap (iteration count stays meaningful for viz/debug),
 * it simply never starts a second one. */
static inline void advance_track_clock_frame(le_engine* e, int32_t ch,
                                             int32_t state, uint64_t frame) {
  le_track* t = &e->tracks[ch];
  if (t->free_clock.length <= 0) return;
  if (state != LE_TRACK_PLAYING && state != LE_TRACK_OVERDUBBING) return;
  if (le_loop_clock_tick(&t->free_clock)) {
    t->free_iteration++;
    if (load_i32(&t->a_one_shot)) {
      store_i32(&t->a_state, LE_TRACK_STOPPED);
      le_consume_pending_mutes(e, t, LE_TRACK_STOPPED, 1, frame);
    }
  }
}

/* Fires a Band section-transport arm (B3b, trigger 2, LE_CMD_ARM's doc): the
 * arm carries no explicit "which direction" — it's a TOGGLE of whatever a
 * press on this track would currently do, exactly like handle_record's own
 * per-state dispatch. STOPPED starts it (mirrors handle_play); PLAYING,
 * OVERDUBBING, or RECORDING stops/finalizes it (handle_stop already covers
 * all three). EMPTY has nothing to toggle — the arm simply expires with no
 * effect (a section reaches this call only after its own defining recording
 * has finalized in practice, but this stays correct even if that invariant
 * is ever violated). */
static void le_fire_section_arm(le_engine* e, int32_t ch, uint64_t frame) {
  const int32_t st = load_i32(&e->tracks[ch].a_state);
  if (st == LE_TRACK_STOPPED) {
    handle_play(e, ch, frame);
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING ||
            st == LE_TRACK_RECORDING) {
    handle_stop(e, ch, frame);
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
      } else if (tr->length_preset_target_frames > 0 &&
                 tr->record_pos >= tr->length_preset_target_frames) {
        /* A6/D17: N-bars + click-on auto-finalize — exactly N bars' worth of
         * frames were captured (target armed at record start by
         * le_arm_length_preset_target). Finalizes into overdub UNCONDITIONALLY
         * — the manual's "auto-finishes... and starts overdubbing" is not
         * gated on rec_dub like a manual second press would be. Deferred via
         * request_master_finalize (not a direct finalize_master call) so the
         * seam gets the same click-free crossfade as a manual press. */
        request_master_finalize(e, tr, LE_TRACK_OVERDUBBING, frame);
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
      const int wrapped = le_loop_clock_tick(&e->clock);
      if (wrapped) e->loop_iteration++;
      /* Grid-armed fire check. The loop top (wrap) is every division's
       * boundary AND the layer boundary, so it fires everything — the exact
       * pre-A3 behavior, and the whole behavior when the quantize division is
       * OFF. With a division set and a loop-locked grid live, a mid-loop
       * subdivision boundary — the first frame whose loop-locked subdivision
       * index differs from the previous frame's (le_grid_loop_subdiv_at over
       * the ACTUAL length, never nominal-BPM multiples) — also fires, except
       * an overdubbing track's punch-out, which stays at the layer boundary
       * (D8: overdub end unchanged). Reading the live division here is what
       * re-evaluates a pending arm on a granularity change: the next check
       * simply uses the new division, and OFF reverts to loop-top-only.
       * Stateless per-frame index compare, gated on an actual trigger-0
       * pending so the dormant cost is a few flag reads. */
      int boundary = wrapped;
      if (!boundary) {
        int has_pending = 0;
        for (int qt = 0; qt < tc; ++qt) {
          if (e->tracks[qt].pending_record &&
              e->tracks[qt].pending_trigger == 0) {
            has_pending = 1;
            break;
          }
        }
        int64_t sn, sd;
        if (has_pending && le_live_subdiv_ratio(e, &sn, &sd)) {
          const int32_t p = e->clock.position; /* just ticked to p >= 1 */
          boundary =
              le_grid_loop_subdiv_at(p, e->clock.length, sn, sd) !=
              le_grid_loop_subdiv_at(p - 1, e->clock.length, sn, sd);
        }
      }
      if (boundary) {
        /* Fire the grid-armed pending records so a deferred start/finalize/
         * overdub lands exactly on the grid. Signal-triggered arms fire in
         * process_input_frame, not here. handle_record enforces the
         * one-capturer hand-off. */
        for (int qt = 0; qt < tc; ++qt) {
          if (e->tracks[qt].pending_record &&
              e->tracks[qt].pending_trigger == 0 &&
              (wrapped ||
               load_i32(&e->tracks[qt].a_state) != LE_TRACK_OVERDUBBING)) {
            e->tracks[qt].pending_record = 0;
            store_i32(&e->tracks[qt].a_pending, 0);
            handle_record(e, qt, frame);
          }
        }
      }
      /* Band section transport (B3b, trigger 2): fires ONLY on the true
       * primary-track loop top (`wrapped`) — deliberately NOT on a
       * subdivision `boundary` like trigger 0 above. The spec's "quantized
       * to the primary track" (song-mode-spec.md §2 Q3, §3's STOP-pedal
       * table) means the primary's CYCLE, not a musical subdivision of it;
       * with mode/primary established this way, the primary defines
       * e->clock (le_sync_quantize_active), so a wrap here IS "the primary
       * track returns to its beginning". */
      if (wrapped) {
        for (int qt = 0; qt < tc; ++qt) {
          if (e->tracks[qt].pending_record &&
              e->tracks[qt].pending_trigger == 2) {
            e->tracks[qt].pending_record = 0;
            store_i32(&e->tracks[qt].a_pending, 0);
            le_fire_section_arm(e, qt, frame);
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
  /* Free/Song mode (B2b, index Architecture §4; broadened to SONG by B4):
   * each track's own clock advances independently of the shared master
   * above, which stays permanently dormant (e->clock.length == 0) in either
   * mode — a single guarded call so this diff stays inspectable at a
   * glance, and provably UNREACHABLE (not merely untested) when
   * a_looper_mode is neither FREE nor SONG. */
  {
    const int32_t mode = load_i32(&e->a_looper_mode);
    if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
      for (int t = 0; t < tc; ++t) {
        advance_track_clock_frame(e, t, st[t], frame);
      }
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

/* Free/Song mode (B2b, broadened to SONG by B4): fills the per-track
 * effective read position / clock length for one frame. Every entry
 * defaults to the shared master's own (pos, e->clock.length) — Multi/Sync/
 * Band's exact values — so a caller that never invokes this (every mode but
 * Free/Song) stays byte-for-byte on the master path; within Free/Song mode,
 * a track whose own clock isn't established yet (still on its first/
 * defining recording) also keeps the default, which is moot —
 * mix_tracks_frame never reads trk_pos/trk_len for a RECORDING track (see
 * rec_w, below). Single guarded call from mix_tracks_frame, mirroring
 * advance_track_clock_frame's per-track scoping above but for the READ side
 * (this does not advance anything; le_engine_process calls it before
 * advance_transport_frame ticks free_clock, so it reads this frame's
 * pre-advance position — exactly like `pos` itself). */
static inline void free_track_positions_frame(le_engine* e, int tc,
                                              int32_t* trk_pos,
                                              int32_t* trk_len) {
  for (int t = 0; t < tc; ++t) {
    const le_loop_clock* c = &e->tracks[t].free_clock;
    if (c->length <= 0) continue; /* not yet established: keep the default */
    trk_pos[t] = c->position;
    trk_len[t] = c->length;
  }
}

/* Sync/Band division read (B3, D16): overrides trk_pos[t]/trk_len[t] for
 * every track [t] with an active division (a_sync_divisor > 0) — the
 * "generalized phase within primary" the seg_base/multiple math (in
 * mix_tracks_frame, below) cannot express, since a division's OWN buffer is
 * SHORTER than the base loop, not a multiple of it. trk_len[t] is
 * e->clock.length / divisor (le_sync_quantize_active guarantees the primary
 * is exactly one base loop whenever a division was created, so no separate
 * lookup is needed); trk_pos[t] is `pos % trk_len[t]`, folding the
 * primary's CURRENT phase into the division's own shorter cycle.
 *
 * base / divisor is an EXACT integer division with NO remainder here —
 * adversarial-review BUG 2 fix: le_sync_choose_ratio (finalize_new_track)
 * now only ever publishes a divisor that tiles the primary's length
 * exactly (base % divisor == 0), stepping down (4 -> 2) or falling back to
 * an ordinary multiple otherwise, rather than this function's old
 * `llround(base / n)` — which, whenever the primary's length wasn't evenly
 * divisible by n (the ORDINARY case for a freely-recorded primary, not a
 * rare edge case), silently repeated or skipped one buffer index every
 * single cycle: an audible, permanent stutter. With base % divisor == 0
 * guaranteed on write, `pos % trk_len[t]` now tiles PROVABLY exactly:
 * over one full primary cycle (pos sweeping 0..base-1), it visits every
 * one of the divisor's own trk_len[t] indices exactly `divisor` times,
 * with no repeats and no skips, for any pos — not just at pos == 0.
 *
 * Deliberately anchored to `pos` (the primary's live phase), not a running
 * iteration/segment count like the multiple path's seg_base: whenever pos
 * == 0 (the primary's loop top), pos % trk_len[t] == 0 too, for ANY
 * trk_len[t] > 0 — so a division track's own loop-top ALWAYS coincides
 * with the primary's, on every primary cycle, regardless of how many times
 * either has wrapped. A half-length division therefore completes exactly 2
 * of its own loops per 1 primary loop, phase-aligned at the start — the
 * behavior a musician expects from a half-length loop layered under a
 * full-length one. (seg_base itself already reads 0 for these tracks with
 * no changes needed: finalize_new_track sets a_multiple to 1 for a
 * division, so the existing `seg = (iter - start_iter) % 1` collapses to 0
 * unconditionally.)
 *
 * Per-track, not mode-gated (mirrors free_track_positions_frame's shape but
 * checks per-track state instead of a single outer mode flag): a_sync_
 * divisor is only ever set nonzero by finalize_new_track under le_sync_
 * quantize_active, which requires SYNC/BAND, so this is mutually exclusive
 * with Free mode's own per-track free_clock by construction — cheap
 * (a single comparison) on every track that isn't a division. */
static inline void sync_division_positions_frame(le_engine* e, int tc,
                                                  int32_t pos,
                                                  int32_t* trk_pos,
                                                  int32_t* trk_len) {
  const int32_t base = e->clock.length;
  if (base <= 0) return;
  for (int t = 0; t < tc; ++t) {
    const int32_t n = load_i32(&e->tracks[t].a_sync_divisor);
    if (n < 2) continue;
    const int32_t len = base / n; /* exact: le_sync_choose_ratio guarantees
                                    * base % n == 0 for every divisor it
                                    * ever publishes */
    if (len < 1) continue; /* defensive; unreachable given the guarantee */
    trk_len[t] = len;
    trk_pos[t] = pos % len;
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

  /* Free/Song mode (B2b, broadened to SONG by B4): each track with its own
   * established clock reads/writes at ITS OWN position and against ITS OWN
   * length below, not the shared master's — single guarded call
   * (free_track_positions_frame) so this is the only place mix_tracks_frame
   * diverges from the Multi/Sync/Band path; every trk_pos[t]/trk_len[t]
   * entry equals pos/e->clock.length verbatim whenever the call is skipped
   * (mode is neither FREE nor SONG) or a specific track's own clock isn't
   * established yet, so the per-track loop below is byte-for-byte the
   * master path in every case but an active Free/Song-mode track. */
  int32_t trk_pos[LE_MAX_TRACKS];
  int32_t trk_len[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    trk_pos[t] = pos;
    trk_len[t] = e->clock.length;
  }
  {
    const int32_t mode = load_i32(&e->a_looper_mode);
    if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
      free_track_positions_frame(e, tc, trk_pos, trk_len);
    }
  }
  /* Sync/Band divisions (B3): per-track, so this always runs (mutually
   * exclusive with Free mode's per-track override above by construction —
   * see sync_division_positions_frame's doc). */
  sync_division_positions_frame(e, tc, pos, trk_pos, trk_len);

  /* The looper mix is additive: clear this output frame, then sum every active
   * lane's mono contribution into the output channels its mask selects. */
  for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] = 0.0f;

  for (int t = 0; t < tc; ++t) {
    /* The punch fade only engages once the loop is long enough to host a full
     * fade-in plus fade-out tail with steady audio between them; shorter loops
     * (sub-20 ms — not musically a loop) snap straight to the target,
     * preserving the exact unfaded write the deterministic tests rely on.
     * Per-track (trk_len[t]) so a Free-mode track's own length governs its
     * own punch fade instead of the (always-0) master's — identical to
     * `e->clock.length >= 2 * od_fade_frames` in every other mode, since
     * trk_len[t] == e->clock.length there. */
    const int od_fade_on = trk_len[t] >= 2 * od_fade_frames;
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
        od_gain > 0.0f && trk_len[t] > 0;
    int32_t wdub = 0;
    int backing = 0;
    if (dub_writes) {
      wdub = seg_base[t] + comp_pos(trk_pos[t], tr->dub_offset, trk_len[t]);
      backing = tr->dub_slot >= 0 && !tr->dub_draining && tr->dub_len > 0 &&
                tr->dub_count < tr->dub_len;
      if (backing && tr->dub_count < 0) {
        tr->dub_count = 0;
        tr->dub_start_vpos = trk_pos[t];
        tr->dub_start_vseg = seg_base[t] / trk_len[t];
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
         * od_gain == 0 in steady playback, so this is a plain read.
         * trk_pos[t] (Free mode, B2b): this track's own clock position;
         * equals pos otherwise. */
        loopsample = lbuf[seg_base[t] + trk_pos[t]];
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

  /* Close the count-in cancel-race grace window (code-review fix) right
   * after this block's command drain: it is open for exactly one block's
   * worth of draining — the block immediately following the commit that set
   * it (engine_private.h / le_count_in_commit have the full rationale) —
   * whether or not a matching press showed up to consume it. */
  e->count_in_grace_channel = -1;

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

  /* Click bus settings, read once per block (same rationale; the click's
   * volume is its ONLY gain stage — deliberately outside the master bus). */
  const int32_t click_mode = load_i32(&e->a_click_mode);
  const uint32_t click_mask =
      atomic_load_explicit(&e->a_click_mask, memory_order_relaxed);
  const float click_vol = load_f32(&e->a_click_volume_bits);
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

    /* Master bus (gain + limiter + output metering), then the perf tap, THEN
     * the click bus (Architecture §3: after the tap so captures/exports never
     * contain it; after gain/limiter/metering so none of them touch it), then
     * the loop-viz tap, then advance the record heads and master transport —
     * see the static-inline step definitions above le_engine_process. The
     * latency-calibration pulse path bypassed all of this via `continue`
     * above. Dormant click cost: the click_on ternary here plus click_frame's
     * fused compare. */
    master_bus_frame(e, out, f, ch_out, master_gain, limiter_on, limiter_ceiling,
                     lim_release, &out_sumsq, &frame_out_peak);
    perf_tap_master_frame(e, out, f, ch_out);
    const int click_on =
        click_mode != LE_CLICK_OFF ? le_click_gate(e, click_mode, tc, st) : 0;
    grid_beat_frame(e, pos, click_on); /* dormant-grid cost: one int compare */
    /* click_mask & out_enabled (code-review fix): a structurally-disabled
     * output must never carry click energy even if the click's own routing
     * mask points at it — exactly like every other source's fan-out (lanes:
     * out_mask & out_enabled in mix_tracks_frame; monitors: mon_out &
     * out_enabled in mix_monitors_frame). out_enabled is already loaded once
     * per block above. */
    click_frame(e, out, f, ch_out, click_on, click_mask & out_enabled,
                click_vol, sr, perf_frame_base + f);
    viz_tap_frame(e, tc, pos, frame_out_peak, frame_trk_peak);
    /* Free/Song mode (B2b, broadened to SONG by B4): the per-track twin of
     * the tap above, single guarded call — see free_track_viz_tap_frame's
     * doc for why a_loop_viz itself stays untouched in either mode. */
    {
      const int32_t mode = load_i32(&e->a_looper_mode);
      if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
        free_track_viz_tap_frame(e, tc, frame_trk_peak);
      }
    }
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
  /* Tap-tempo frame clock, advanced once per block (taps arrive via the ring,
   * which drains before the frame loop, so block granularity IS the command's
   * real timing resolution — no per-frame work on the hot path). */
  e->frame_clock += (uint64_t)frames;
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

  /* MIDI clock send (C1, D15). BLOCK granularity, like the tap-tempo frame
   * clock above: the emitter is driven once per le_engine_process call with
   * this call's whole frame count, not per-sample — MIDI clock's practical
   * timing tolerance is well inside one audio block (a few ms at typical
   * buffer sizes), and every other block-rate decision in this function
   * (limiter params, click bus settings, master gain) already uses this same
   * granularity. `transport_active` reads the states AFTER this block's
   * transport advances above, so a track that started/stopped mid-block is
   * reflected from the very next call — le_transport_held is the exact
   * negation this needs (see its own doc for why it's the audio-thread twin
   * of le_transport_active on the control side). Bytes are appended to
   * midi_clock_ring (RT-safe: bounded push, no allocation/lock/syscall) for
   * whatever forwards them to le_midi_out_send — see le_midi_clock.h. */
  {
    int32_t num = load_i32(&e->a_ts_num);
    if (num <= 0) num = 4;
    uint8_t clock_bytes[32];
    const int32_t clock_n = le_midi_clock_advance(
        &e->midi_clock, (int32_t)frames, load_f32(&e->a_tempo_bpm_bits), num,
        load_i32(&e->a_ts_den), sr, !le_transport_held(e),
        le_clock_send_gate_open(e), clock_bytes, (int32_t)sizeof(clock_bytes));
    for (int32_t i = 0; i < clock_n; ++i) {
      le_ring_push(&e->midi_clock_ring,
                   (le_command){.code = clock_bytes[i]});
    }
  }
}
