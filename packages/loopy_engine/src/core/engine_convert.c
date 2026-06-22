/*
 * engine_convert.c — pure sample-format conversion + ASIO buffer-size math.
 *
 * THREAD OWNERSHIP: none. Every function here is pure (no engine state, no
 * miniaudio/ASIO headers, no allocation): given inputs, computes outputs. The
 * deinterleave/interleave pair is called from the ASIO device backend on the
 * audio thread; le_asio_pick_buffer is called once at device open on the control
 * thread. Both are unit-tested off-thread via the engine_internal.h surface.
 *
 * Split out of engine.c (S1) behind the unchanged ABI; declarations live in
 * engine_internal.h (the non-public test surface).
 */
#include <stdint.h>
#include <string.h>

#include "engine_internal.h" /* le_sample_fmt + the function declarations */

static int le_sample_bytes(le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16: return 2;
    case LE_SMP_I24: return 3;
    case LE_SMP_I32: return 4;
    case LE_SMP_F32: return 4;
  }
  return 4;
}

/* One little-endian native sample -> normalized f32 (integer formats map their
 * full range to [-1, 1)). */
static float le_native_to_f32(const uint8_t* p, le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16: {
      int16_t v = (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
      return (float)v / 32768.0f;
    }
    case LE_SMP_I24: {
      int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                            ((uint32_t)p[2] << 16));
      if (v & 0x00800000) v |= (int32_t)0xFF000000; /* sign-extend 24 -> 32 */
      return (float)v / 8388608.0f;
    }
    case LE_SMP_I32: {
      int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                            ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
      return (float)v / 2147483648.0f;
    }
    case LE_SMP_F32: {
      uint32_t bits = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                      ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
      float f;
      memcpy(&f, &bits, sizeof(f));
      return f;
    }
  }
  return 0.0f;
}

/* Rounds + clamps to a signed integer range, then writes `bytes` little-endian. */
static void le_write_le_int(uint8_t* p, double scaled, double lo, double hi,
                            int bytes) {
  if (scaled > hi) scaled = hi;
  if (scaled < lo) scaled = lo;
  int64_t v = (int64_t)(scaled < 0 ? scaled - 0.5 : scaled + 0.5);
  for (int b = 0; b < bytes; ++b) p[b] = (uint8_t)((v >> (8 * b)) & 0xFF);
}

/* Normalized f32 -> one little-endian native sample (clamped to the format). */
static void le_f32_to_native(uint8_t* p, float f, le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16:
      le_write_le_int(p, (double)f * 32768.0, -32768.0, 32767.0, 2);
      break;
    case LE_SMP_I24:
      le_write_le_int(p, (double)f * 8388608.0, -8388608.0, 8388607.0, 3);
      break;
    case LE_SMP_I32:
      le_write_le_int(p, (double)f * 2147483648.0, -2147483648.0, 2147483647.0,
                      4);
      break;
    case LE_SMP_F32: {
      uint32_t bits;
      memcpy(&bits, &f, sizeof(bits));
      p[0] = (uint8_t)(bits & 0xFF);
      p[1] = (uint8_t)((bits >> 8) & 0xFF);
      p[2] = (uint8_t)((bits >> 16) & 0xFF);
      p[3] = (uint8_t)((bits >> 24) & 0xFF);
      break;
    }
  }
}

void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count,
                        int frames) {
  if (out_interleaved == NULL || native_block == NULL || channel_count <= 0 ||
      chan < 0 || chan >= channel_count) {
    return;
  }
  const int bytes = le_sample_bytes(fmt);
  const uint8_t* src = (const uint8_t*)native_block;
  for (int f = 0; f < frames; ++f) {
    out_interleaved[(size_t)f * channel_count + chan] =
        le_native_to_f32(src + (size_t)f * bytes, fmt);
  }
}

void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count,
                       int frames) {
  if (native_block == NULL || in_interleaved == NULL || channel_count <= 0 ||
      chan < 0 || chan >= channel_count) {
    return;
  }
  const int bytes = le_sample_bytes(fmt);
  uint8_t* dst = (uint8_t*)native_block;
  for (int f = 0; f < frames; ++f) {
    le_f32_to_native(dst + (size_t)f * bytes,
                     in_interleaved[(size_t)f * channel_count + chan], fmt);
  }
}

int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity) {
  /* Fixed-size driver: only `preferred` is selectable. */
  if (granularity == 0) return preferred;
  /* A request the driver can't honor (outside its window) -> preferred. */
  if (requested < min || requested > max) return preferred;

  if (granularity == -1) {
    /* Powers of two only: snap to the nearest power of two within [min,max]
     * (preferring the larger on a tie). */
    int32_t best = 0;
    int64_t best_dist = 0;
    for (int64_t p = 1; p <= max; p <<= 1) {
      if (p < min) continue;
      int64_t d = p > requested ? p - requested : requested - p;
      if (best == 0 || d < best_dist || (d == best_dist && p > best)) {
        best = (int32_t)p;
        best_dist = d;
      }
    }
    return best != 0 ? best : preferred;
  }

  /* granularity > 0: linear steps from `min`. Snap to the nearest valid step,
   * clamped to the largest step that does not exceed `max`. */
  int64_t steps = ((int64_t)requested - min + granularity / 2) / granularity;
  int64_t snapped = (int64_t)min + steps * granularity;
  int64_t last = (int64_t)min + (((int64_t)max - min) / granularity) * granularity;
  if (snapped > last) snapped = last;
  if (snapped < min) snapped = min;
  return (int32_t)snapped;
}
