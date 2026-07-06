/*
 * perf_log_ring.h — single-producer/single-consumer lock-free ring for
 * performance-recording event-log entries.
 *
 * lockfree_ring.h's le_ring carries POD commands from control -> audio; this is
 * a sibling ring for the reverse concern this part adds: while performance
 * capture is armed, every audibility-affecting command applied by the audio
 * thread (plus a handful of transport facts — record start/end, loop length
 * locked, layer retired) is tagged with the capture frame it occurred at and
 * pushed here, to be drained to disk by perf_drain.c's background thread (see
 * docs/design/performance-event-log-format.md for the on-disk format and the
 * full audited command table).
 *
 * Two independent instances of this ring exist per le_perf_capture (see
 * engine_private.h): one with the AUDIO thread as producer (apply_command +
 * the per-frame transport-fact call sites), one with the CONTROL thread as
 * producer (the direct-atomic setters that bypass the command ring entirely —
 * FX/monitor params, the limiter, overdub feedback, and the common in-track
 * undo/redo swap). Each individual ring is strictly single-producer, matching
 * every other ring in this codebase; splitting by producer thread — rather
 * than trying to make one ring safe for two concurrent producers — is what
 * keeps both instances wait-free with zero new synchronization primitives.
 * The drain thread pops both every cycle and appends both streams to the same
 * events.log file; entries are monotonic in frame *within* each stream but the
 * two streams are not globally merged/sorted (see the format doc).
 */
#ifndef LOOPY_PERF_LOG_RING_H
#define LOOPY_PERF_LOG_RING_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "lockfree_ring.h" /* le_command: reused as this ring's payload shape */

#ifdef __cplusplus
extern "C" {
#endif

/* Perf-log-only event codes (audio thread and control thread alike), numbered
 * apart from le_command_code's LE_CMD_ and LE_EVT_ ranges (0-42, 100) so the
 * two enums are never confused. Values below LE_PLOG_RECORD_START correspond
 * 1:1 to an audited LE_CMD_ code the entry's `cmd.code` field mirrors
 * verbatim (same code, same union arm) — see the audited table in
 * docs/design/performance-event-log-format.md. Values from
 * LE_PLOG_RECORD_START on are transport facts / control-side-only concepts
 * with no corresponding LE_CMD_ code. */
typedef enum le_perf_log_code {
  LE_PLOG_RECORD_START = 300, /* a track actually began recording (immediate or
                               * a quantized ARM firing at the loop top). generic
                               * arm: arg_i = channel (arg_f unused). */
  LE_PLOG_RECORD_END = 301,   /* a track left RECORDING (stop, punch-out, or
                               * overdub toggle). generic arm: arg_i = channel. */
  LE_PLOG_LOOP_LENGTH_LOCKED = 302, /* the master loop length was (re)established
                                     * — first record finalize, or a session
                                     * commit/import. generic arm: arg_i =
                                     * length in frames. */
  LE_PLOG_LAYER_RETIRED = 303,      /* a completed overdub pass retired. evt arm:
                                     * channel, slot, generation (mirrors
                                     * LE_EVT_LAYER_RETIRED's payload verbatim). */
  LE_PLOG_UNDO = 304, /* an undo succeeded (the common in-track swap; the
                       * to-EMPTY edge case logs via LE_CMD_UNDO_TO_EMPTY
                       * instead, applied on the audio thread). generic arm:
                       * arg_i = channel. */
  LE_PLOG_REDO = 305, /* a redo succeeded (the common in-track swap; the
                       * from-EMPTY edge case logs via LE_CMD_REDO_FROM_EMPTY
                       * instead). generic arm: arg_i = channel. */
  /* The next two reuse the `fx` arm {channel, lane, index, type}, but neither
   * has a "type" or a bare param index to carry alone — a param change needs
   * (channel, lane, effect-slot index, param 0..LE_FX_PARAMS-1, float value),
   * one field more than any existing arm has room for. Packed the same way
   * LE_CMD_SET_LANE_FX's own docs already pack channel/lane/index into one
   * int elsewhere in this ABI: `fx.index` carries LE_PLOG_FX_PARAM_PACK(index,
   * param) (below), and `fx.type` carries the float value bit-cast to int32
   * (see f32_to_bits / bits_to_f32 in engine_private.h — the same
   * reinterpretation already used for every atomic float field in this
   * engine, just applied to a plain local instead of an atomic slot).
   * `fx.lane` is -1 for the monitor variant (input effects have no lane). */
  LE_PLOG_SET_LANE_FX_PARAM = 306,    /* fx arm: channel, lane,
                                      * index=LE_PLOG_FX_PARAM_PACK(index,
                                      * param), type=bits(value). */
  LE_PLOG_SET_MONITOR_FX_PARAM = 307, /* fx arm: channel=input, lane=-1,
                                      * index=LE_PLOG_FX_PARAM_PACK(index,
                                      * param), type=bits(value). */
  LE_PLOG_SET_LIMITER = 308, /* generic arm: arg_i = enabled (0/1), arg_f =
                             * ceiling. */
  LE_PLOG_SET_OVERDUB_FEEDBACK = 309, /* generic arm: arg_f = feedback (0..1). */
} le_perf_log_code;

/* Pack/unpack helpers for LE_PLOG_SET_LANE_FX_PARAM / _MONITOR_FX_PARAM's
 * `fx.index` field (see above) — one definition shared by both emission call
 * sites (engine_commands.c) and any future decoder, so the packing formula
 * exists in exactly one place rather than being reproduced by hand wherever
 * it's needed. */
#define LE_PLOG_FX_PARAM_PACK(index, param) (((index) << 8) | (param))
#define LE_PLOG_FX_PARAM_INDEX(packed) ((packed) >> 8)
#define LE_PLOG_FX_PARAM_PARAM(packed) ((packed) & 0xff)

/* One logged event: the capture frame it occurred at (frames elapsed since
 * arm, same epoch as a_perf_frames/the PCM captures — see perf_drain.c), plus
 * an le_command-shaped payload (code + the same tagged union apply_command
 * already reads/writes, reused verbatim for entries whose `code` is an
 * audited LE_CMD_*; le_perf_log_code entries reuse whichever arm fits their
 * own payload, documented per code above). */
typedef struct le_perf_log_entry {
  uint64_t frame;
  le_command cmd;
} le_perf_log_entry;

/* Fixed-capacity SPSC ring of le_perf_log_entry. `capacity` is a power of two;
 * one slot is kept empty to distinguish full from empty, so usable slots ==
 * capacity - 1. */
typedef struct le_perf_log_ring {
  le_perf_log_entry* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index (drain thread reads) */
  _Atomic size_t tail; /* producer index */
} le_perf_log_ring;

/* Initialises `ring` to use `buffer` of `capacity` entries. `capacity` must be
 * a power of two and >= 2. Returns 1 on success, 0 on invalid arguments. */
int le_perf_log_ring_init(le_perf_log_ring* ring, le_perf_log_entry* buffer,
                          size_t capacity);

/* Producer side. Returns 1 if the entry was enqueued, 0 if the ring is full
 * (the caller counts this as one dropped log event — see LE_PLOG overrun
 * accounting in the emitting call sites). Wait-free. */
int le_perf_log_ring_push(le_perf_log_ring* ring, le_perf_log_entry entry);

/* Consumer side. Writes the next entry into *out and returns 1, or returns 0
 * if the ring is empty. Wait-free; safe to call from the drain thread. */
int le_perf_log_ring_pop(le_perf_log_ring* ring, le_perf_log_entry* out);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_PERF_LOG_RING_H */
