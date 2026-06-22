/*
 * fft.h — header-only radix-2 FFT primitive for the phase vocoder.
 *
 * A pure, self-contained transform with no engine coupling: every function is
 * `static` and the caller owns all buffers (no malloc, no platform headers).
 * Header-only means no new translation unit — it is #included by exactly one TU
 * (the phase vocoder's engine.c in part 3; the native test here in part 1), so
 * the static functions never multiply-define and never sit unused.
 *
 * Pure C11; compiles under MSVC (/std:c11), Clang, and GCC. The real-FFT helpers
 * run a full length-n complex FFT (the simplest correct approach; the packed
 * real-FFT optimization is not worth the complexity at n = 1024) and expose the
 * non-redundant n/2+1 bins.
 */
#ifndef LOOPY_FFT_H
#define LOOPY_FFT_H

#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LE_FFT_PI 3.14159265358979323846f

/* Upper bound on the transform size the real-FFT helpers can scratch on the
 * stack. The phase vocoder uses n = 1024; the cap leaves headroom while keeping
 * the per-call scratch (2 * LE_FFT_MAX_N floats) small enough for the audio
 * thread's stack. n passed to le_rfft_fwd/le_rfft_inv MUST be <= this. */
#define LE_FFT_MAX_N 4096

/* In-place iterative radix-2 complex FFT. n MUST be a power of two.
 * inverse == 0: forward; inverse != 0: inverse WITHOUT 1/n scaling (callers that
 * need an orthonormal round-trip divide by n themselves; le_rfft_inv does). */
static void le_fft(float* re, float* im, int n, int inverse) {
  /* Bit-reversal permutation: reorder samples into butterfly order in place. */
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      float tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      float ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  /* Danielson–Lanczos butterflies, doubling the sub-transform length each pass. */
  for (int len = 2; len <= n; len <<= 1) {
    float ang = (inverse ? 2.0f : -2.0f) * LE_FFT_PI / (float)len;
    float wlen_re = cosf(ang);
    float wlen_im = sinf(ang);
    for (int i = 0; i < n; i += len) {
      float w_re = 1.0f;
      float w_im = 0.0f;
      for (int k = 0; k < len / 2; ++k) {
        int a = i + k;
        int b = a + len / 2;
        float v_re = re[b] * w_re - im[b] * w_im;
        float v_im = re[b] * w_im + im[b] * w_re;
        re[b] = re[a] - v_re;
        im[b] = im[a] - v_im;
        re[a] += v_re;
        im[a] += v_im;
        float next_re = w_re * wlen_re - w_im * wlen_im;
        w_im = w_re * wlen_im + w_im * wlen_re;
        w_re = next_re;
      }
    }
  }
}

/* Real input x[n] -> half spectrum re/im[0..n/2] (n/2+1 bins). re/im sized
 * >= n/2+1. n MUST be a power of two and <= LE_FFT_MAX_N. */
static void le_rfft_fwd(const float* x, float* re, float* im, int n) {
  float sr[LE_FFT_MAX_N];
  float si[LE_FFT_MAX_N];
  if (n <= 0 || n > LE_FFT_MAX_N) {
    return; /* contract violation: never overrun the stack scratch. */
  }
  for (int i = 0; i < n; ++i) {
    sr[i] = x[i];
    si[i] = 0.0f;
  }
  le_fft(sr, si, n, 0);
  for (int i = 0; i <= n / 2; ++i) {
    re[i] = sr[i];
    im[i] = si[i];
  }
}

/* Half spectrum re/im[0..n/2] -> real output y[n], normalized by 1/n. The full
 * spectrum is reconstructed from the Hermitian-symmetric mirror of the half.
 * n MUST be a power of two and <= LE_FFT_MAX_N. */
static void le_rfft_inv(const float* re, const float* im, float* y, int n) {
  float sr[LE_FFT_MAX_N];
  float si[LE_FFT_MAX_N];
  if (n <= 0 || n > LE_FFT_MAX_N) {
    return; /* contract violation: never overrun the stack scratch. */
  }
  sr[0] = re[0]; /* DC bin is real. */
  si[0] = im[0];
  for (int i = 1; i < n / 2; ++i) {
    sr[i] = re[i];
    si[i] = im[i];
    sr[n - i] = re[i]; /* mirror bin is the complex conjugate. */
    si[n - i] = -im[i];
  }
  sr[n / 2] = re[n / 2]; /* Nyquist bin is real for a real signal. */
  si[n / 2] = im[n / 2];
  le_fft(sr, si, n, 1);
  for (int i = 0; i < n; ++i) {
    y[i] = sr[i] / (float)n;
  }
}

/* Fills table[0..n-1] with a periodic Hann window once, then short-circuits on
 * later calls via *ready. The table is read-only shared state owned by the
 * caller (the phase vocoder keeps a file-scope table + ready flag, sized to its
 * own LE_PV_N), so fft.h stays free of engine constants. Periodic form
 * (divide by n, not n-1) gives correct constant-overlap-add for the STFT. */
static void le_hann_init(float* table, int n, int* ready) {
  if (*ready) {
    return;
  }
  for (int i = 0; i < n; ++i) {
    table[i] = 0.5f - 0.5f * cosf(2.0f * LE_FFT_PI * (float)i / (float)n);
  }
  *ready = 1;
}

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_FFT_H */
