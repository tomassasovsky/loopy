/*
 * engine_fx.c — per-lane / per-monitor effects DSP (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: audio thread. Every kernel here runs inside the device
 * callback via fx_apply_chain; all are branch-light and allocation-free (delay
 * rings and octaver buffers are pre-allocated by the control thread in
 * le_fx_prepare_entry). The only control-thread entry points are le_fx_entry_reset
 * (also called on the audio thread), le_fx_free_octaver, le_octaver_latency, and
 * le_fx_ensure_hann. Parameters arrive normalized (0..1) and are mapped to
 * musical ranges here.
 *
 * Behaviour is identical to the pre-split engine.c; the chain is non-destructive
 * (recordings stay dry) and stageless (every active entry colours in order). The
 * cross-TU surface and the PV/PSOLA tuning constants live in engine_fx.h.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_internal.h" /* le_psola_detect prototype (defined below) */
#include "fft.h" /* le_rfft_fwd / le_rfft_inv / le_fft / le_hann_init */

#ifndef LE_PI
#define LE_PI 3.14159265358979323846f
#endif

/* Read-only Hann window shared by every octaver instance (analysis + synthesis
 * window). Built once under a guarded init; never per-instance state. */
static float le_hann[LE_PV_N];
static int le_hann_ready;

void le_fx_ensure_hann(void) { le_hann_init(le_hann, LE_PV_N, &le_hann_ready); }

/* Soft-clipping overdrive: tanh saturation with a pre-gain, then output trim. */
static float fx_drive(float x, const float* p) {
  const float drive = 1.0f + p[0] * 29.0f; /* 1x .. 30x pre-gain */
  const float level = p[1];                /* 0..1 output trim */
  return tanhf(x * drive) * level;
}

/* Resonant low-pass: a TPT state-variable filter (Cytomic/Zavalishin form).
 * p0 = cutoff (20 Hz .. ~18 kHz, log), p1 = resonance. */
static float fx_filter(le_fx_state* fx, int slot, int chan, int sr, float x,
                       const float* p) {
  float fc = 20.0f * powf(900.0f, p[0]); /* 20 * 900 = 18 kHz at p0 = 1 */
  const float nyq = 0.45f * (float)sr;
  if (fc > nyq) fc = nyq;
  const float g = tanf(LE_PI * fc / (float)sr);
  const float k = 2.0f - 1.8f * p[1]; /* damping: 2 (none) .. 0.2 (resonant) */
  const float a1 = 1.0f / (1.0f + g * (g + k));
  const float a2 = g * a1;
  const float a3 = g * a2;
  float* ic1 = &fx->svf_ic1[slot][chan];
  float* ic2 = &fx->svf_ic2[slot][chan];
  const float v3 = x - *ic2;
  const float v1 = a1 * (*ic1) + a2 * v3;
  const float v2 = *ic2 + a2 * (*ic1) + a3 * v3;
  *ic1 = 2.0f * v1 - *ic1;
  *ic2 = 2.0f * v2 - *ic2;
  return v2; /* low-pass output */
}

/* Feedback delay: p0 = time (0..1 s), p1 = feedback, p2 = wet mix. The ring is
 * the control-thread-allocated fx_delay line of e->fx_delay_frames samples. */
static float fx_delay(le_fx_state* fx, int slot, int chan, int cap, float x,
                      const float* p) {
  float* buf = fx->delay[slot][chan];
  if (buf == NULL || cap <= 1) return x;
  int d = (int)(p[0] * (float)(cap - 1));
  if (d < 1) d = 1;
  int pos = fx->delay_pos[slot][chan];
  int rp = pos - d;
  if (rp < 0) rp += cap;
  const float delayed = buf[rp];
  const float fb = p[1] * 0.95f; /* keep the feedback loop stable (< 1) */
  buf[pos] = x + delayed * fb;
  pos += 1;
  if (pos >= cap) pos = 0;
  fx->delay_pos[slot][chan] = pos;
  const float mix = p[2];
  return x * (1.0f - mix) + delayed * mix;
}

/* Tremolo: sine LFO amplitude modulation. p0 = rate (0.1..12 Hz), p1 = depth. */
static float fx_tremolo(le_fx_state* fx, int slot, int chan, int sr, float x,
                        const float* p) {
  const float rate = 0.1f + p[0] * 11.9f;
  const float depth = p[1];
  float ph = fx->lfo[slot][chan];
  const float lfo = 0.5f * (1.0f + sinf(2.0f * LE_PI * ph)); /* 0..1 */
  ph += rate / (float)sr;
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot][chan] = ph;
  return x * (1.0f - depth * (1.0f - lfo));
}

/* Linearly interpolated read from a ring of [cap] samples, [d] samples behind
 * the head [head] (the index of the most recently written sample). [d] may be
 * fractional and is assumed in [0, cap). */
static float fx_read_frac(const float* buf, int cap, int head, float d) {
  float rp = (float)head - d;
  while (rp < 0.0f) rp += (float)cap;
  while (rp >= (float)cap) rp -= (float)cap;
  const int i0 = (int)rp;
  const float frac = rp - (float)i0;
  int i1 = i0 + 1;
  if (i1 >= cap) i1 = 0;
  return buf[i0] + frac * (buf[i1] - buf[i0]);
}

/* --- Phase-vocoder octaver (LE_FX_OCTAVER) ------------------------------------
 *
 * A streaming STFT phase vocoder that shifts pitch while holding the formant
 * (spectral) envelope fixed, so a shifted voice neither combs (granular overlap)
 * nor chipmunks (resampled formants). The chain still calls the effect one sample
 * at a time; internally it buffers input in the slot's delay ring, runs one FFT
 * frame every LE_PV_HOP samples, and emits a latency-delayed sample. All heavy
 * buffers are control-thread allocated; the audio thread never allocates. */

/* Wraps a phase value into [-pi, pi] in O(1) — the raw per-hop phase deviation
 * (phase - k*expct) can be hundreds of radians for high bins, so a subtract loop
 * would spin many times per bin per hop. */
static float le_wrap_pi(float x) {
  const float two_pi = 2.0f * LE_PI;
  return x - two_pi * roundf(x / two_pi);
}

/* Zeros the octaver's per-mode DSP runtime (phase history, synthesis
 * accumulator, hop counter) without touching the heap-buffer allocation or the
 * smoothed params / current mode. Used on a mode switch and on entry reset; safe
 * with NULL buffers (a slot that is not an octaver). */
static void le_pv_reset_runtime(le_octaver_state* o) {
  o->hop_count = 0;
  o->out_pos = 0;
  o->in_epoch = 0;
  o->out_epoch = 0;
  o->period = 0.0f;
  o->voiced = 0.0f;
  if (o->out != NULL) memset(o->out, 0, sizeof(float) * LE_PV_N);
  if (o->last_phase != NULL) memset(o->last_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->sum_phase != NULL) memset(o->sum_phase, 0, sizeof(float) * LE_PV_BINS);
}

/* Runs one STFT analysis/synthesis frame: windows the newest LE_PV_N FIFO
 * samples, shifts the harmonic structure by `ratio` while holding the cepstral
 * formant envelope fixed in frequency, and overlap-adds the result into o->out.
 * Called once per LE_PV_HOP samples from le_pv_tick. All scratch is stack-local
 * (bounded; no allocation). `head` indexes the newest FIFO sample.
 *
 * Cost per hop per channel: four length-N FFTs — analysis (le_rfft_fwd), the two
 * cepstrum transforms (le_fft inverse + forward), and synthesis (le_rfft_inv).
 * Stack peak ~60 KB at N = 1024 (the locals below ~27 KB plus the fixed ~32 KB
 * scratch inside one le_rfft_* call, which run sequentially, not nested); this
 * scales with N, so a future bump to N = 2048 must re-check constrained
 * (e.g. plugin-host) audio-thread stack budgets. */
static void le_octaver_frame(le_octaver_state* o, const float* fifo, int head,
                             int cap, float ratio) {
  float win[LE_PV_N];
  float re[LE_PV_BINS];
  float im[LE_PV_BINS];
  float mag[LE_PV_BINS];
  float freq[LE_PV_BINS];
  float env[LE_PV_BINS];
  float syn_mag[LE_PV_BINS];
  float syn_freq[LE_PV_BINS];
  float cr[LE_PV_N];
  float ci[LE_PV_N];

  const float expct = 2.0f * LE_PI * (float)LE_PV_HOP / (float)LE_PV_N;
  const float osamp = (float)LE_PV_N / (float)LE_PV_HOP;

  /* 1. Hann-window the newest N samples (win[N-1] is the freshest). */
  for (int i = 0; i < LE_PV_N; ++i) {
    int idx = head - LE_PV_N + 1 + i;
    idx %= cap;
    if (idx < 0) idx += cap;
    win[i] = fifo[idx] * le_hann[i];
  }
  le_rfft_fwd(win, re, im, LE_PV_N);

  /* 2. Per-bin magnitude + true frequency (in bins) from the phase advance. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const float r = re[k];
    const float im_k = im[k];
    mag[k] = sqrtf(r * r + im_k * im_k);
    const float phase = atan2f(im_k, r);
    float d = phase - o->last_phase[k];
    o->last_phase[k] = phase;
    d -= (float)k * expct;
    d = le_wrap_pi(d);
    freq[k] = (float)k + osamp * d / (2.0f * LE_PI);
  }

  /* 3. Formant envelope: lifter the low-quefrency cepstrum of log|X|. The full
   *    symmetric log-magnitude round-trips through a complex FFT pair (inverse
   *    then forward == * N), so the net 1/N is divided back out below. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    cr[k] = logf(mag[k] + 1e-9f);
    ci[k] = 0.0f;
  }
  for (int k = 1; k < LE_PV_N / 2; ++k) {
    cr[LE_PV_N - k] = cr[k];
    ci[LE_PV_N - k] = 0.0f;
  }
  le_fft(cr, ci, LE_PV_N, 1); /* -> cepstrum (real, even) */
  for (int q = LE_PV_LIFTER; q <= LE_PV_N - LE_PV_LIFTER; ++q) {
    cr[q] = 0.0f;
    ci[q] = 0.0f;
  }
  le_fft(cr, ci, LE_PV_N, 0); /* -> N * smoothed log-magnitude */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    env[k] = expf(cr[k] / (float)LE_PV_N);
  }

  /* 4. Whiten (mag/env), shift bins by `ratio`, then re-apply the envelope at
   *    the DESTINATION bin so the formants stay fixed in frequency. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    syn_mag[k] = 0.0f;
    syn_freq[k] = 0.0f;
  }
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const int j = (int)((float)k * ratio + 0.5f);
    if (j >= 0 && j < LE_PV_BINS) {
      const float res = mag[k] / (env[k] + 1e-9f);
      syn_mag[j] += res * env[j];
      syn_freq[j] = freq[k] * ratio;
    }
  }

  /* 5. Accumulate synthesis phase (advance per hop = 2*pi*freq*HOP/N) and
   *    rebuild the half spectrum. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    o->sum_phase[k] +=
        2.0f * LE_PI * syn_freq[k] * (float)LE_PV_HOP / (float)LE_PV_N;
    re[k] = syn_mag[k] * cosf(o->sum_phase[k]);
    im[k] = syn_mag[k] * sinf(o->sum_phase[k]);
  }

  /* 6. Inverse transform, synthesis-window, overlap-add. The Hann analysis x
   *    Hann synthesis window at 4x overlap sums to 1.5 — divide for unity. */
  le_rfft_inv(re, im, win, LE_PV_N);
  const float norm = 1.0f / 1.5f;
  for (int i = 0; i < LE_PV_N; ++i) {
    o->out[i] += win[i] * le_hann[i] * norm;
  }
}

/* Emits one phase-vocoder output sample (latency LE_PV_N), running a fresh frame
 * at each hop boundary and streaming the synthesis accumulator out by one sample
 * per call, shifting it down by a hop once a block is fully emitted. */
static float le_pv_tick(le_octaver_state* o, const float* fifo, int head, int cap,
                        float ratio) {
  if (o->out == NULL) return 0.0f;
  if (o->hop_count == 0) {
    le_octaver_frame(o, fifo, head, cap, ratio);
  }
  const float y = o->out[o->hop_count];
  if (++o->hop_count >= LE_PV_HOP) {
    memmove(o->out, o->out + LE_PV_HOP, sizeof(float) * (LE_PV_N - LE_PV_HOP));
    memset(o->out + (LE_PV_N - LE_PV_HOP), 0, sizeof(float) * LE_PV_HOP);
    o->hop_count = 0;
  }
  return y;
}

/* YIN pitch detector (see engine_internal.h). Plain autocorrelation peak-picking
 * is prone to octave errors — a sub/multiple of the true period correlates nearly
 * as well — and a mis-spaced grain wrecks both pitch and formants, so the modest
 * extra cost of YIN's cumulative-mean normalization is worth it here. */
int le_psola_detect(const float* x, int n, int sr, float* out_period,
                    float* out_voiced) {
  *out_period = 0.0f;
  *out_voiced = 0.0f;
  int minlag = sr / 1000; /* ~1000 Hz ceiling */
  if (minlag < 2) minlag = 2;
  int maxlag = sr / 60; /* ~60 Hz floor */
  if (maxlag > LE_PSOLA_MAXLAG) maxlag = LE_PSOLA_MAXLAG;
  if (maxlag > n / 2) maxlag = n / 2;
  if (maxlag <= minlag) return 0;
  const int integ = n - maxlag; /* difference-function integration length */

  /* Silence floor: never run the detector on the noise floor (avoids reporting a
   * spurious "pitch" for hiss); a quiet frame reads as unvoiced. */
  double energy = 0.0;
  for (int i = 0; i < integ; ++i) energy += (double)x[i] * (double)x[i];
  if (energy < (double)integ * 1e-7) return 0;

  /* Difference function d(tau), then its cumulative-mean normalization d'(tau). */
  float dp[LE_PSOLA_MAXLAG + 1];
  dp[0] = 1.0f;
  double cum = 0.0;
  for (int tau = 1; tau <= maxlag; ++tau) {
    double sum = 0.0;
    for (int i = 0; i < integ; ++i) {
      const float diff = x[i] - x[i + tau];
      sum += (double)diff * (double)diff;
    }
    cum += sum;
    dp[tau] = cum > 0.0 ? (float)(sum * (double)tau / cum) : 1.0f;
  }

  /* First dip below the absolute threshold, walked down to its local minimum;
   * fall back to the global minimum (low confidence) when nothing crosses. */
  int tau = -1;
  for (int t = minlag; t <= maxlag; ++t) {
    if (dp[t] < LE_PSOLA_THRESH) {
      while (t + 1 <= maxlag && dp[t + 1] < dp[t]) ++t;
      tau = t;
      break;
    }
  }
  if (tau < 0) {
    float best = dp[minlag];
    tau = minlag;
    for (int t = minlag + 1; t <= maxlag; ++t) {
      if (dp[t] < best) {
        best = dp[t];
        tau = t;
      }
    }
  }

  /* Parabolic interpolation around the chosen lag for a sub-sample period. */
  float period = (float)tau;
  if (tau > minlag && tau < maxlag) {
    const float s0 = dp[tau - 1];
    const float s1 = dp[tau];
    const float s2 = dp[tau + 1];
    const float denom = s0 + s2 - 2.0f * s1;
    if (fabsf(denom) > 1e-9f) period = (float)tau + 0.5f * (s0 - s2) / denom;
  }

  float conf = 1.0f - dp[tau];
  if (conf < 0.0f) conf = 0.0f;
  if (conf > 1.0f) conf = 1.0f;
  *out_period = period;
  *out_voiced = conf;
  return conf > 0.5f ? 1 : 0;
}

/* Added latency (frames) of the active octaver. Single source of truth, read in
 * two places: the dry-delay match in fx_octaver (D2), and — per the part-5 plan —
 * the control thread, which folds it into the published snapshot so the UI can
 * warn about monitoring lag. PSOLA reuses the LE_PV_N OLA accumulator (the no-
 * extra-allocation budget part 3 fixed), and by construction its grain centers sit
 * LE_PV_N behind the head, so its latency equals the phase vocoder's; both modes
 * therefore report LE_PV_N and the dry tap does not jump on a switch. The argument
 * is the per-mode seam a future dedicated PSOLA buffer (lower latency) would use. */
int le_octaver_latency(const le_octaver_state* o) {
  (void)o;
  return LE_PV_N;
}

/* TD-PSOLA pitch shift (mode >= 0.5). Grains are repositioned but never resampled,
 * so the grain's spectral shape — the formants — stays fixed while the epoch
 * repetition rate changes the pitch. Lowest-latency, most natural on solo voice;
 * polyphonic/transient input reads as unvoiced (low YIN confidence) and falls back
 * to the delay-matched dry, and silence collapses to dry (~0). A one-pole-smoothed
 * confidence drives a soft voiced<->unvoiced crossfade (no dry<->wet chatter). The
 * synthesis OLA reuses o->out as a circular accumulator (PSOLA's circular access
 * and the phase vocoder's linear+memmove access never coexist — the mode switch
 * resets the shared buffer at the gain-dip bottom; no new allocation either way).
 *
 * Analysis marks are uniform (period-spaced), not true glottal-closure instants —
 * the plan's deliberate "it's an effect, not speech-synthesis" choice. The cost is
 * that a pulse-less, near-pure tone (e.g. a flute/whistle/sine) can self-cancel on
 * a large up-shift, where same-period grains land antiphase; harmonic-rich voice
 * (the documented sweet spot) has localized epochs and reinforces. */
static float le_psola_tick(le_octaver_state* o, const float* fifo, int head,
                           int cap, float ratio) {
  if (o->out == NULL) return 0.0f;
  const int N = LE_PV_N;
  const int sr = cap; /* the fx ring is 1 s long, so cap == sample rate */

  /* 1. Emit one sample from the circular OLA accumulator, clearing it behind. */
  const int rp = o->out_pos;
  const float y = o->out[rp];
  o->out[rp] = 0.0f;
  o->out_pos = (rp + 1 >= N) ? 0 : rp + 1;

  /* 2. Periodic pitch analysis: YIN over a contiguous copy of the FIFO tail. */
  if (--o->hop_count <= 0) {
    o->hop_count = LE_PSOLA_AHOP;
    float win[LE_PSOLA_WIN];
    for (int i = 0; i < LE_PSOLA_WIN; ++i) {
      int idx = head - (LE_PSOLA_WIN - 1) + i;
      idx %= cap;
      if (idx < 0) idx += cap;
      win[i] = fifo[idx];
    }
    float p = 0.0f;
    float vc = 0.0f;
    le_psola_detect(win, LE_PSOLA_WIN, sr, &p, &vc);
    o->voiced += 0.35f * (vc - o->voiced); /* smooth -> chatter-free soft gate */
    if (p > 0.0f) {                        /* hold last period through gaps */
      o->period = o->period <= 0.0f ? p : o->period + 0.5f * (p - o->period);
    }
  }

  /* 3. Synthesis: marks recede from the head one sample per tick; at each
   *    synthesis mark deposit a Hann grain whose source snaps to the nearest
   *    analysis mark, so the grain spacing (pitch) changes by `ratio` while the
   *    grain shape (formant envelope) does not. */
  o->in_epoch += 1;
  if (--o->out_epoch <= 0) {
    float pf = o->period; /* sub-sample period: sets the grain spacing (pitch) */
    if (pf < 2.0f) pf = 2.0f;
    if (pf > (float)LE_PSOLA_MAXLAG) pf = (float)LE_PSOLA_MAXLAG;
    float ps = pf / ratio; /* synthesis spacing -> output pitch = ratio * f0 */
    if (ps < 1.0f) ps = 1.0f;
    /* Integer countdown to the next deposit; sub-sample spacing is fine to round
     * here — the pitch error is < 1 sample over a period and is inaudible. */
    o->out_epoch += (int)(ps + 0.5f);

    const int pi = (int)(pf + 0.5f); /* integer period: the analysis-mark grid step */
    int th = pi;
    if (th > LE_PSOLA_THMAX) th = LE_PSOLA_THMAX;
    const int c = N / 2;  /* grain center offset ahead of the read pointer */
    const int dn = N - c; /* nominal source distance behind the head */
    /* Snap the analysis mark to the nearest of the period-spaced grid near dn. */
    while (o->in_epoch - dn > pi / 2) o->in_epoch -= pi;
    while (dn - o->in_epoch > pi / 2) o->in_epoch += pi;
    if (o->in_epoch < th) o->in_epoch = th; /* keep the grain read causal */
    if (o->in_epoch > cap - 1 - th) o->in_epoch = cap - 1 - th;

    /* COLA gain: Hann area (= th) over the hop (= ps) keeps the overlap-add near
     * unity across the shift; clamp so a clamped grain cannot blow up. */
    float gain = ps / (float)th;
    if (gain > 2.0f) gain = 2.0f;
    for (int j = -th; j <= th; ++j) {
      const float wf =
          0.5f - 0.5f * cosf(LE_PI * (float)(j + th) / (float)th); /* Hann */
      int src = head - o->in_epoch + j;
      src %= cap;
      if (src < 0) src += cap;
      int dst = rp + c + j;
      dst %= N;
      if (dst < 0) dst += N;
      o->out[dst] += gain * wf * fifo[src];
    }
  }

  /* 4. Soft voiced/unvoiced gate (D4): crossfade the grain voice against the
   *    delay-matched dry by the smoothed confidence. Silence -> voiced ~0 and the
   *    dry tap is ~0, so the output collapses to silence (no grain buzz). */
  int didx = head - le_octaver_latency(o) + 1;
  didx %= cap;
  if (didx < 0) didx += cap;
  const float dry = fifo[didx];
  float wv = (o->voiced - 0.3f) / 0.3f; /* soft gate around conf ~0.3..0.6 */
  if (wv < 0.0f) wv = 0.0f;
  if (wv > 1.0f) wv = 1.0f;
  return wv * y + (1.0f - wv) * dry;
}

/* Formant-preserving octaver. Writes the newest sample to the slot's FIFO ring,
 * then mixes a delay-matched dry tap (head - LE_PV_N) with a wet voice from the
 * phase vocoder (mode p3 < 0.5) or PSOLA (part 4, currently silent). p0 = shift
 * (0 = -2 oct, 0.5 = unison, 1 = +2 oct), p1 = tone (one-pole darkening of the
 * wet voice), p2 = dry/wet mix, p3 = mode. Params are one-pole smoothed
 * (zipper-free) and a mode switch runs an equal-power gain dip while the DSP
 * runtime resets. The ring length `cap` equals the sample rate (1 s), used here
 * as the time base for the smoothing / dip constants. */
static float fx_octaver(le_fx_state* fx, int slot, int chan, int cap, float x,
                        const float* p) {
  float* buf = fx->delay[slot][chan];
  le_octaver_state* o = &fx->oct[slot][chan];
  if (buf == NULL || o->out == NULL || cap < LE_PV_N + 1) return x;

  /* Write the newest sample at the head, then advance. */
  const int head = fx->delay_pos[slot][chan];
  buf[head] = x;
  int npos = head + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot][chan] = npos;

  /* Zipper-free param smoothing (~5 ms one-pole; cap == sample rate). */
  const float sc = 1.0f / (0.005f * (float)cap);
  o->sm_shift += sc * (p[0] - o->sm_shift);
  o->sm_tone += sc * (p[1] - o->sm_tone);
  o->sm_mix += sc * (p[2] - o->sm_mix);

  /* Mode switch (D1): equal-power gain dip, ~15 ms per leg — fade the wet out,
   * reset the DSP runtime at the bottom, then fade back in on the new mode. */
  const int requested = p[3] >= 0.5f ? 1 : 0;
  const float xstep = 1.0f / (0.015f * (float)cap);
  if (requested != o->cur_mode) {
    o->xfade -= xstep;
    if (o->xfade <= 0.0f) {
      o->xfade = 0.0f;
      o->cur_mode = requested;
      le_pv_reset_runtime(o);
    }
  } else if (o->xfade < 1.0f) {
    o->xfade += xstep;
    if (o->xfade > 1.0f) o->xfade = 1.0f;
  }

  const float ratio = powf(2.0f, (o->sm_shift - 0.5f) * 48.0f / 12.0f);
  const float wet = o->cur_mode == 0 ? le_pv_tick(o, buf, head, cap, ratio)
                                     : le_psola_tick(o, buf, head, cap, ratio);

  /* Tone: a one-pole low-pass on the wet voice that opens up as p1 rises. */
  const float a = 0.05f + 0.9f * o->sm_tone;
  float lp = fx->fx_lp[slot][chan];
  lp += a * (wet - lp);
  fx->fx_lp[slot][chan] = lp;

  /* Delay-matched dry (D2): read the dry tap behind the newest by the active
   * mode's added latency (le_octaver_latency) so the mix stays comb-free. Both
   * modes report LE_PV_N today, so the dry tap does not jump on a mode switch. */
  int dry_idx = head - le_octaver_latency(o) + 1;
  dry_idx %= cap;
  if (dry_idx < 0) dry_idx += cap;
  const float dry = buf[dry_idx];

  /* Equal-power gain-dip envelope on the wet leg (g == 1 when steady). */
  const float g = sinf(o->xfade * 0.5f * LE_PI);
  const float mix = o->sm_mix;
  return dry * (1.0f - mix) + g * lp * mix;
}

/* Tape-style echo. Three things set it apart from the clean digital delay: a
 * slow wow LFO wobbles the read time (tape pitch flutter, read fractionally), a
 * heavy one-pole low-pass darkens the loop so each repeat loses highs, and the
 * fed-back signal is softly saturated (tape compression, which also self-limits
 * the feedback). The wet tap is that processed signal, so even the first repeat
 * is coloured rather than a clean copy. p0 = time (0..1 s), p1 = feedback,
 * p2 = wet mix. Shares the fx_delay ring; lfo is the wow phase, fx_lp the loop
 * low-pass. */
static float fx_echo(le_fx_state* fx, int slot, int chan, int sr, int cap,
                     float x, const float* p) {
  float* buf = fx->delay[slot][chan];
  if (buf == NULL || cap <= 1) return x;

  /* Wow/flutter: a slow LFO wobbles the read time a few ms for tape wobble. */
  float ph = fx->lfo[slot][chan];
  const float wow = sinf(2.0f * LE_PI * ph);
  ph += 0.7f / (float)sr; /* ~0.7 Hz wow */
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot][chan] = ph;
  const float wob = 0.004f * (float)sr; /* ~4 ms wobble depth */
  float d = p[0] * (float)(cap - 1) + wow * wob;
  if (d < 1.0f) d = 1.0f;
  if (d > (float)(cap - 1)) d = (float)(cap - 1);

  const int pos = fx->delay_pos[slot][chan];
  const float delayed = fx_read_frac(buf, cap, pos, d);

  /* Darken the loop (~1.4 kHz one-pole) then soft-saturate the repeats. */
  float lp = fx->fx_lp[slot][chan];
  lp += 0.18f * (delayed - lp);
  fx->fx_lp[slot][chan] = lp;
  const float wet = tanhf(lp);
  const float fb = p[1] * 0.97f;

  buf[pos] = x + wet * fb;
  int npos = pos + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot][chan] = npos;

  const float mix = p[2];
  return x * (1.0f - mix) + wet * mix;
}

/* Comb and allpass line lengths (samples at 44.1 kHz; scaled to the running
 * rate). The classic Freeverb tunings: mutually prime lengths so the comb
 * resonances and allpass diffusion never line up into a periodic ring. */
static const int LE_REV_COMB_LEN[LE_REV_COMBS] = {1116, 1188, 1277, 1356,
                                                  1422, 1491, 1557, 1617};
static const int LE_REV_AP_LEN[LE_REV_APS] = {556, 441, 341, 225};

/* Freeverb stereo spread: the right bank's lines are this many samples longer
 * (at 44.1 kHz, scaled to the running rate) so its tail decorrelates from the
 * left's, giving a mono input a wide stereo decay. */
#define LE_REV_SPREAD 23

/* Clears the reverb comb/allpass write heads and per-comb damping memory for
 * chain slot [s] across both stereo banks (the reverb's share of the per-slot
 * DSP state). */
static void le_fx_clear_reverb(le_fx_state* fx, int s) {
  for (int i = 0; i < LE_REV_COMBS * LE_REV_BANKS; ++i) {
    fx->rev_comb_pos[s][i] = 0;
    fx->rev_comb_lp[s][i] = 0.0f;
  }
  for (int i = 0; i < LE_REV_APS * LE_REV_BANKS; ++i) fx->rev_ap_pos[s][i] = 0;
}

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay read head, one-pole memory, octaver phase-vocoder runtime, reverb
 * lines) so a freshly engaged effect starts clean — no filter blow-up from stale
 * integrators, no delay-read of old content. Does NOT free or allocate the delay
 * ring or octaver buffers; the control thread owns their lifetime. Shared by
 * le_lane_reset, le_monitor_lane_reset, and the SET_*_FX ring handlers (which
 * reset one slot when its type changes), removing what was a copy-pasted clear.
 *
 * RT note: this runs on the AUDIO THREAD (the SET_*_FX ring handlers). For an
 * allocated octaver slot it now memsets the three phase-vocoder buffers
 * (~16 KB/channel). That is bounded and fires only on a discrete type-change
 * event (never per sample), consistent with the existing reverb-line clears. */
void le_fx_entry_reset(le_fx_state* fx, int slot) {
  for (int chan = 0; chan < 2; ++chan) {
    fx->svf_ic1[slot][chan] = 0.0f;
    fx->svf_ic2[slot][chan] = 0.0f;
    fx->lfo[slot][chan] = 0.0f;
    fx->delay_pos[slot][chan] = 0;
    fx->fx_lp[slot][chan] = 0.0f;
    le_octaver_state* o = &fx->oct[slot][chan];
    o->sm_shift = 0.5f; /* unison: the smoother ramps up from no shift, not -2 oct */
    o->sm_tone = 0.0f;
    o->sm_mix = 0.0f; /* starts dry, so the param ramp-in is inaudible */
    o->cur_mode = 0;  /* phase vocoder */
    o->xfade = 1.0f;  /* steady (no gain dip) */
    le_pv_reset_runtime(o);
  }
  le_fx_clear_reverb(fx, slot);
}

/* Frees a chain slot's octaver phase-vocoder heap buffers (both channels) and
 * nulls them. Control-thread only (lane/monitor reset and engine destroy), where
 * the audio thread is no longer reading the slot — mirroring how the delay rings
 * are freed. Like the rings, the buffers are KEPT (not freed) across an in-place
 * retype so a retype-back reuses them; freeing on retype would race the audio
 * thread still processing the slot before the type-change command is observed. */
void le_fx_free_octaver(le_fx_state* fx, int slot) {
  for (int chan = 0; chan < 2; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    free(o->out);
    o->out = NULL;
    free(o->last_phase);
    o->last_phase = NULL;
    free(o->sum_phase);
    o->sum_phase = NULL;
  }
}

/* Schroeder/Freeverb reverb: LE_REV_COMBS parallel damped comb filters are
 * summed and run through LE_REV_APS series allpass diffusers, producing a dense
 * decaying tail rather than the discrete repeats of DELAY/ECHO. Two such banks
 * run in parallel — a left and a right whose lines are offset by LE_REV_SPREAD —
 * each fed by its own input (the left bank by xl, the right by xr) and returned
 * through *out_l / *out_r. A mono input (xl == xr) feeds both banks identically,
 * so it still yields a decorrelated stereo tail from the spread alone, exactly as
 * before; an already-stereo input reverberates each side on its own bank. p0 =
 * size (tail length, via comb feedback), p1 = damping (treble absorbed each
 * pass), p2 = wet mix. The wet path carries only the reverberated signal, so the
 * dry is heard through (1 - mix). Both banks are packed into the slot's single
 * 1 s ring delay[slot][0] (delay[slot][1] is unused by reverb); both banks total
 * well under 1 s even at 192 kHz.
 *
 * The call site passes &xl / &xr as the out-params while xl / xr are also the
 * inputs, so both wet[] values are computed before either out-param is written —
 * xl / xr are never read after the first store. */
static void fx_reverb(le_fx_state* fx, int slot, int sr, int cap, float xl,
                      float xr, const float* p, float* out_l, float* out_r) {
  float* buf = fx->delay[slot][0];
  if (buf == NULL || cap <= 1) {
    *out_l = xl;
    *out_r = xr;
    return;
  }
  const float scale = (float)sr / 44100.0f;
  const float room = 0.70f + p[0] * 0.28f; /* 0.70..0.98 comb feedback */
  const float damp = p[1] * 0.4f;          /* 0..0.4 feedback low-pass */
  const float mix = p[2];

  int off = 0;
  float wet[LE_REV_BANKS] = {0.0f, 0.0f};
  for (int bank = 0; bank < LE_REV_BANKS; ++bank) {
    const int spread = bank == 0 ? 0 : (int)((float)LE_REV_SPREAD * scale);
    const int cbase = bank * LE_REV_COMBS; /* this bank's state slice */
    const int abase = bank * LE_REV_APS;
    const float in = (bank == 0 ? xl : xr) * 0.015f; /* Freeverb input gain */
    float acc = 0.0f;
    for (int c = 0; c < LE_REV_COMBS; ++c) {
      int len = (int)((float)LE_REV_COMB_LEN[c] * scale) + spread;
      if (len < 1) len = 1;
      if (off + len > cap) break; /* safety: never index past the ring */
      int pos = fx->rev_comb_pos[slot][cbase + c];
      if (pos >= len) pos = 0;
      const float y = buf[off + pos];
      acc += y;
      float lp = fx->rev_comb_lp[slot][cbase + c];
      lp = y * (1.0f - damp) + lp * damp; /* damp the signal fed back */
      fx->rev_comb_lp[slot][cbase + c] = lp;
      buf[off + pos] = in + lp * room;
      pos += 1;
      if (pos >= len) pos = 0;
      fx->rev_comb_pos[slot][cbase + c] = pos;
      off += len;
    }
    float s = acc;
    for (int a = 0; a < LE_REV_APS; ++a) {
      int len = (int)((float)LE_REV_AP_LEN[a] * scale) + spread;
      if (len < 1) len = 1;
      if (off + len > cap) break;
      int pos = fx->rev_ap_pos[slot][abase + a];
      if (pos >= len) pos = 0;
      const float bufout = buf[off + pos];
      buf[off + pos] = s + bufout * 0.5f; /* allpass feedback coefficient */
      s = bufout - s;
      pos += 1;
      if (pos >= len) pos = 0;
      fx->rev_ap_pos[slot][abase + a] = pos;
      off += len;
    }
    wet[bank] = s;
  }
  /* Write both out-params last: they may alias the xl / xr inputs. */
  *out_l = xl * (1.0f - mix) + wet[0] * mix;
  *out_r = xr * (1.0f - mix) + wet[1] * mix;
}

/* Applies a chain to one stereo sample, in chain order, carrying the (l, r) pair
 * in place. The chain is stageless: every active entry processes both channels.
 * [count] is the active chain length; [types]/[params] are the per-buffer
 * snapshot.
 *
 * Every effect runs in full stereo — each colours l and r through its own
 * per-channel DSP state, so there is no mono/stereo distinction and no ordering
 * constraint: a reverb (or any decorrelating effect) may sit anywhere in the
 * chain and every later effect still processes both channels. A mono source
 * seeds l == r, so a symmetric chain leaves l == r and is audibly unchanged. */
void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS]) {
  float xl = *l;
  float xr = *r;
  for (int s = 0; s < count; ++s) {
    switch (types[s]) {
      case LE_FX_DRIVE:
        xl = fx_drive(xl, params[s]);
        xr = fx_drive(xr, params[s]);
        break;
      case LE_FX_FILTER:
        xl = fx_filter(fx, s, 0, sr, xl, params[s]);
        xr = fx_filter(fx, s, 1, sr, xr, params[s]);
        break;
      case LE_FX_DELAY:
        xl = fx_delay(fx, s, 0, cap, xl, params[s]);
        xr = fx_delay(fx, s, 1, cap, xr, params[s]);
        break;
      case LE_FX_TREMOLO:
        xl = fx_tremolo(fx, s, 0, sr, xl, params[s]);
        xr = fx_tremolo(fx, s, 1, sr, xr, params[s]);
        break;
      case LE_FX_OCTAVER:
        xl = fx_octaver(fx, s, 0, cap, xl, params[s]);
        xr = fx_octaver(fx, s, 1, cap, xr, params[s]);
        break;
      case LE_FX_ECHO:
        xl = fx_echo(fx, s, 0, sr, cap, xl, params[s]);
        xr = fx_echo(fx, s, 1, sr, cap, xr, params[s]);
        break;
      case LE_FX_REVERB:
        fx_reverb(fx, s, sr, cap, xl, xr, params[s], &xl, &xr);
        break;
      default:
        break;
    }
  }
  *l = xl;
  *r = xr;
}
