/*
 * engine_core.h — low-level engine helpers shared across the split core TUs.
 *
 * These are the small primitives the per-concern TUs (engine_transport.c,
 * engine_process.c, engine_snapshot.c, engine_session.c, engine_commands.c,
 * engine_lifecycle.c) all reach for. The tiny, hot ones are `static inline`
 * here; the rest are declared here and defined in engine.c (the residual shared
 * core). NOT the FFI surface (segno_engine_api.h) and NOT the test surface
 * (engine_internal.h) — the private contract between the engine's own TUs, like
 * engine_private.h but for behaviour rather than the struct layout.
 */
#ifndef SEGNO_ENGINE_CORE_H
#define SEGNO_ENGINE_CORE_H

#include <stdint.h>

#include "engine_private.h" /* le_engine, le_track, store_i32, LE_MAX_LANES */

#ifdef __cplusplus
extern "C" {
#endif

/* Loopback latency harness tuning. The echo returns only mildly attenuated
 * (~0.9 from a full-scale pulse on a typical interface), so we emit a quiet
 * calibration tone rather than full scale to spare the user's monitors, and
 * detect with a threshold comfortably below the echo yet above the noise floor.
 * Shared by the audio thread (engine_process.c emits + correlates) and the
 * control thread (engine.c's le_engine_configure sizes lat_buf from CAPTURE_DIV). */
#define LE_LATENCY_PULSE_AMP 0.9f  /* calibration tone amplitude (0..1) */
#define LE_LATENCY_TONE_HZ 1000.0f /* tone-burst freq (AC: survives AC-coupling) */
#define LE_LATENCY_PEAK_RATIO 2.5f /* correlation peak must exceed this x baseline */
#define LE_LATENCY_PULSE_DIV 100   /* pulse length = sample_rate / this (~10ms) */
#define LE_LATENCY_CAPTURE_DIV 10  /* capture window = sample_rate / this (~100ms) */

/* Input level (0..1) that triggers sound-activated recording (~-34 dBFS). */
#define LE_AUTO_RECORD_THRESHOLD 0.02f

/* Wraps `pos - offset` into [0, len). Used to write captured input at the
 * latency-compensated loop position so overdubs align with what was heard. */
static inline int32_t comp_pos(int32_t pos, int32_t offset, int32_t len) {
  if (len <= 0) return pos;
  int32_t p = (pos - offset) % len;
  if (p < 0) p += len;
  return p;
}

/* A track's active lane count, clamped to a usable range (a track always has at
 * least one lane). */
static inline int32_t le_lanes_active(const le_track* t) {
  int32_t n = t->lane_count;
  if (n < 1) n = 1;
  if (n > LE_MAX_LANES) n = LE_MAX_LANES;
  return n;
}

/* FNV-1a fold of one 32-bit value, byte by byte in little-endian order so the
 * hash is endianness-independent. The primitive under every chain-fingerprint
 * fold (engine_snapshot.c's canonical le_fx_chain_fingerprint, the wet cache's
 * enqueue-snapshot fold in engine_cache.c, and — mirrored — the Dart
 * trackChainFingerprint): ONE definition, so the folds can never drift at the
 * byte level. `static inline` like the other tiny hot helpers here. */
static inline uint64_t le_fx_fp_u32(uint64_t h, uint32_t v) {
  for (int b = 0; b < 4; ++b) {
    h ^= (uint8_t)(v >> (8 * b));
    h *= 0x100000001b3ULL;
  }
  return h;
}

/* The control thread's view of a track's state: the target of a
 * posted-but-unapplied state-flip command (UNDO_TO_EMPTY / REDO_FROM_EMPTY /
 * CLEAR), or the published a_state once everything posted has been acked.
 * Ring FIFO makes this deterministic — no observation race. Shared by the
 * command producers (engine_commands.c) and the wet-cache scheduler's enqueue
 * gate (engine_cache.c), which must never diverge on this predicate. The
 * acquire pairs with the audio thread's release on the ack bump, so once the
 * counters match, the a_state store that preceded the ack is visible. */
static inline int32_t le_effective_state(le_track* t) {
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return t->pending_target;
  }
  return load_i32(&t->a_state);
}

/* Publishes pool slot [slot] as every active lane's live buffer AND bumps the
 * track's content revision in the same motion — the STRUCTURAL half of the
 * a_audio_rev bump-site table (engine_private.h): every control-side history
 * operation that re-points a_live (undo/redo swaps, redo-from-empty,
 * clear-restore, layered session finalize) MUST go through this helper, so
 * the [R1] bump can never be forgotten when the next history feature copies
 * the swap. Control thread only (a_live's sole writer). */
static inline void le_track_publish_live(le_track* t, int32_t slot) {
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, slot);
  le_audio_rev_bump(t); /* [R1] a_live now names other audio */
}

/* Whether `ch` is a usable track index. Defined in engine.c. */
int valid_channel(le_engine* e, int32_t ch);

/* Publishes a recorded length onto every active lane of a track (all lanes share
 * the one transport, so they share the length). Defined in engine.c. */
void le_track_set_len(le_track* t, int32_t len);

/* Lowest set bit of `mask` as a channel index, or -1 when no bit is set.
 * Collapses a legacy track input bitmask into lane 0's single input channel.
 * Defined in engine.c. */
int32_t le_mask_to_channel(uint32_t mask);

/* Posts a command into the engine's SPSC ring (control thread). Returns LE_OK,
 * LE_ERR_NOT_RUNNING (not configured), or LE_ERR_INVALID (null / ring full).
 * le_push builds a generic { arg_i, arg_f } command; le_push_cmd posts a
 * prebuilt typed command (the addressed/packed families fill a named union arm).
 * Both defined in engine.c. */
int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i, float arg_f);
int32_t le_push_cmd(le_engine* engine, le_command cmd);

/* Resets a lane to defaults (routing / volume / mute / effects / metering),
 * clearing DSP state and freeing octaver buffers. Control-thread lifecycle helper
 * defined in engine.c, also called by le_engine_set_lane_count in
 * engine_commands.c. (The per-input monitor's single-chain reset lives in
 * engine.c as le_monitor_input_reset.) */
void le_lane_reset(le_lane* ln, int32_t input_channel);

/* Ensures lane [ln]'s pool slot [slot] holds a buffer of >= [frames] frames
 * (control thread only; the caller guarantees the audio thread is not reading
 * the slot's CONTENT — an EMPTY track's live slot, or a slot outside
 * live/stacks/outstanding). Growth replaces the buffer (free + fresh calloc);
 * no content survives a regrow by design — snapshots are always written whole
 * before use. Returns 1 on success, 0 on allocation failure (the slot is left
 * unallocated). Defined in engine.c. */
int le_lane_ensure_slot(le_lane* ln, int32_t slot, int32_t frames);

/* Shrinks an over-allocated slot to `frames`, PRESERVING the leading `frames`
 * samples — the counterpart to le_lane_ensure_slot's grow-by-replace, for the
 * one case that must keep its content: a retired undo layer whose slot was
 * pre-armed at the recording cap because the loop length was not yet known.
 * Control thread only, and only for a slot the audio thread no longer holds
 * (never the live slot). No-op when the slot is unallocated or already at or
 * below `frames`; a failed realloc keeps the oversized buffer. Defined in
 * engine.c. */
void le_lane_shrink_slot(le_lane* ln, int32_t slot, int32_t frames);

/* Drains the audio->control event ring (retired per-pass undo layers) into the
 * per-track undo stacks, replenishes shadow-slot spares, pre-arms the
 * first-wrap shadow for a RECORDING track bound to continue into overdub
 * (le_capture_may_overdub — deferred-arm captures get their slot ONLY from
 * this poll, so the per-block snapshot cadence during capture is load-bearing,
 * not an optimization target), and applies any undo taps that were queued
 * while a layer was in flight. Control thread only; called at the top of
 * le_engine_get_snapshot and of the transport entry points. Defined in
 * engine_commands.c. */
void le_engine_drain_events(le_engine* engine);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_CORE_H */
