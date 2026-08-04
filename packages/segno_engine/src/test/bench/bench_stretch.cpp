/* bench_stretch.cpp — spike D0 benchmark for Signalsmith Stretch.
 *
 * Standalone harness, NOT part of the native test gate (run_native_tests.sh
 * compiles explicit file lists and never looks in src/test/bench/).
 *
 * Answers, with numbers (see docs/plan/2026-07-22-time-stretch-spike-findings.md):
 *   - per-block cost of stretching N concurrent 48 kHz mono streams in
 *     480-frame (10 ms) blocks, per preset (default / cheaper) and ratio
 *     (0.5, 0.8, 1.2, 2.0 where ratio = output/input = original/current tempo)
 *   - resident heap per stretcher instance (global new/delete tracking)
 *   - whether process() allocates on the audio thread (RT-safety signal)
 *   - cost of a trivial linear-interp varispeed leg for comparison
 *
 * Build + run: ./bench.sh            (host compiler, -O2)
 * Optional:    ./bench_stretch --wav <dir>   dumps WAVs for manual listening.
 */

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <random>
#include <string>
#include <vector>

/* ---------------- global allocation tracking (macOS) ---------------- */
/* malloc_size gives the true block size, so unsized delete works too.   */

#if defined(__APPLE__)
#include <malloc/malloc.h>
static std::atomic<long long> g_liveBytes{0};
static std::atomic<long long> g_allocCount{0};

static void* trackedAlloc(size_t n) {
  void* p = std::malloc(n ? n : 1);
  if (!p) throw std::bad_alloc();
  g_liveBytes.fetch_add((long long)malloc_size(p), std::memory_order_relaxed);
  g_allocCount.fetch_add(1, std::memory_order_relaxed);
  return p;
}
static void trackedFree(void* p) noexcept {
  if (!p) return;
  g_liveBytes.fetch_sub((long long)malloc_size(p), std::memory_order_relaxed);
  std::free(p);
}
void* operator new(size_t n) { return trackedAlloc(n); }
void* operator new[](size_t n) { return trackedAlloc(n); }
void operator delete(void* p) noexcept { trackedFree(p); }
void operator delete[](void* p) noexcept { trackedFree(p); }
void operator delete(void* p, size_t) noexcept { trackedFree(p); }
void operator delete[](void* p, size_t) noexcept { trackedFree(p); }
static long long liveBytes() { return g_liveBytes.load(); }
static long long allocCount() { return g_allocCount.load(); }
#else
static long long liveBytes() { return 0; }
static long long allocCount() { return 0; }
#endif

#include "third_party/signalsmith-stretch/signalsmith-stretch.h"

/* ---------------- constants ---------------- */

static constexpr int kSampleRate = 48000;
static constexpr int kBlock = 480; /* 10 ms */
static constexpr double kBlockMs = 1000.0 * kBlock / kSampleRate;
static constexpr int kSourceSeconds = 10;
static constexpr int kSourceFrames = kSampleRate * kSourceSeconds;

static const double kRatios[] = {0.5, 0.8, 1.2, 2.0};

/* ---------------- timing helpers ---------------- */

using Clock = std::chrono::steady_clock;

static double msSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

struct Stats {
  double p50, p99, mx, mean;
};

static Stats stats(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  auto pct = [&](double p) {
    size_t i = (size_t)std::ceil(p * v.size());
    return v[std::min(v.size() - 1, i ? i - 1 : 0)];
  };
  double sum = 0;
  for (double x : v) sum += x;
  return {pct(0.50), pct(0.99), v.back(), sum / v.size()};
}

/* ---------------- source synthesis: mixed sines + noise bursts ------- */

static std::vector<float> makeSource() {
  std::vector<float> s(kSourceFrames, 0.0f);
  const double freqs[] = {82.41, 220.0, 330.0, 587.33, 1244.5};
  const double amps[] = {0.28, 0.22, 0.16, 0.10, 0.06};
  for (int i = 0; i < kSourceFrames; ++i) {
    double t = (double)i / kSampleRate;
    double x = 0;
    for (int k = 0; k < 5; ++k) {
      double am = 0.7 + 0.3 * std::sin(2 * M_PI * (0.31 + 0.17 * k) * t);
      x += amps[k] * am * std::sin(2 * M_PI * freqs[k] * t);
    }
    s[i] = (float)x;
  }
  /* 30 ms decaying white-noise bursts every 500 ms (percussive content). */
  std::mt19937 rng(12345);
  std::uniform_real_distribution<float> uni(-1.0f, 1.0f);
  for (int start = 0; start + kSampleRate / 2 <= kSourceFrames;
       start += kSampleRate / 2) {
    int len = kSampleRate * 30 / 1000;
    for (int i = 0; i < len; ++i) {
      float env = std::exp(-6.0f * i / len);
      s[start + i] += 0.4f * env * uni(rng);
    }
  }
  return s;
}

/* ---------------- stretch stream wrapper ---------------- */

struct StretchStream {
  signalsmith::stretch::SignalsmithStretch<float> st{12345};
  const float* src = nullptr;
  int64_t srcLen = 0;
  int64_t readPos = 0;  /* integer read head into src (wraps) */
  double frac = 0;      /* fractional input remainder */
  std::vector<float> inBuf, outBuf;

  void init(bool cheaper, const std::vector<float>& source, int64_t offset) {
    if (cheaper)
      st.presetCheaper(1, (float)kSampleRate);
    else
      st.presetDefault(1, (float)kSampleRate);
    src = source.data();
    srcLen = (int64_t)source.size();
    readPos = offset % srcLen;
    frac = 0;
    /* worst input per block here is ratio 0.5 → 960 frames; leave margin. */
    inBuf.assign(4096, 0.0f);
    outBuf.assign(kBlock, 0.0f);
  }

  /* Advance the stretcher by `outSamples` of output so its internal STFT
   * hop phase shifts — used to stagger hop-aligned cost spikes across
   * concurrent streams. */
  void prime(int outSamples, double ratio) {
    while (outSamples > 0) {
      int n = std::min(outSamples, kBlock);
      double want = frac + (double)n / ratio;
      int nIn = (int)want;
      frac = want - nIn;
      for (int i = 0; i < nIn; ++i)
        inBuf[(size_t)i] = src[(readPos + i) % srcLen];
      readPos = (readPos + nIn) % srcLen;
      float* ip = inBuf.data();
      float* op = outBuf.data();
      st.process(&ip, nIn, &op, n);
      outSamples -= n;
    }
  }

  /* ratio = output/input = originalTempo/currentTempo. */
  void processBlock(double ratio) {
    double want = frac + (double)kBlock / ratio;
    int nIn = (int)want;
    frac = want - nIn;
    for (int i = 0; i < nIn; ++i)
      inBuf[(size_t)i] = src[(readPos + i) % srcLen];
    readPos = (readPos + nIn) % srcLen;
    float* ip = inBuf.data();
    float* op = outBuf.data();
    st.process(&ip, nIn, &op, kBlock);
  }
};

/* ---------------- trivial linear-interp varispeed ---------------- */

struct VarispeedStream {
  const float* src = nullptr;
  int64_t srcLen = 0;
  double pos = 0;
  std::vector<float> outBuf;

  void init(const std::vector<float>& source, int64_t offset) {
    src = source.data();
    srcLen = (int64_t)source.size();
    pos = (double)(offset % srcLen);
    outBuf.assign(kBlock, 0.0f);
  }

  /* rate = input frames per output frame = currentTempo/originalTempo. */
  void processBlock(double rate) {
    for (int i = 0; i < kBlock; ++i) {
      int64_t i0 = (int64_t)pos;
      float t = (float)(pos - (double)i0);
      float a = src[i0 % srcLen];
      float b = src[(i0 + 1) % srcLen];
      outBuf[(size_t)i] = a + t * (b - a);
      pos += rate;
      if (pos >= (double)srcLen) pos -= (double)srcLen;
    }
  }
};

/* ---------------- WAV dump (16-bit PCM mono) ---------------- */

static void writeWav(const std::string& path, const std::vector<float>& s) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) {
    std::fprintf(stderr, "cannot write %s\n", path.c_str());
    return;
  }
  uint32_t dataBytes = (uint32_t)(s.size() * 2);
  uint32_t riffLen = 36 + dataBytes;
  uint32_t rate = kSampleRate, byteRate = rate * 2, fmtLen = 16;
  uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
  std::fwrite("RIFF", 1, 4, f);
  std::fwrite(&riffLen, 4, 1, f);
  std::fwrite("WAVEfmt ", 1, 8, f);
  std::fwrite(&fmtLen, 4, 1, f);
  std::fwrite(&fmt, 2, 1, f);
  std::fwrite(&ch, 2, 1, f);
  std::fwrite(&rate, 4, 1, f);
  std::fwrite(&byteRate, 4, 1, f);
  std::fwrite(&align, 2, 1, f);
  std::fwrite(&bits, 2, 1, f);
  std::fwrite("data", 1, 4, f);
  std::fwrite(&dataBytes, 4, 1, f);
  for (float x : s) {
    int v = (int)std::lround(std::max(-1.0f, std::min(1.0f, x)) * 32767.0f);
    int16_t v16 = (int16_t)v;
    std::fwrite(&v16, 2, 1, f);
  }
  std::fclose(f);
}

/* ---------------- scenarios ---------------- */

static void memoryReport() {
  std::printf("\n== Memory: resident heap per stretcher instance ==\n");
  std::printf("| preset  | bytes/stream | KiB | block | interval | inLat | outLat | total lat ms |\n");
  std::printf("|---------|-------------:|----:|------:|---------:|------:|-------:|-------------:|\n");
  for (int cheap = 0; cheap <= 1; ++cheap) {
    long long before = liveBytes();
    auto* s = new StretchStream();
    /* dummy source: memory of the stretcher itself only */
    static std::vector<float> dummy(kSourceFrames, 0.0f);
    s->init(cheap != 0, dummy, 0);
    long long perStream = liveBytes() - before;
    /* subtract our own wrapper scratch (inBuf+outBuf) to isolate the lib */
    long long wrapper =
        (long long)((s->inBuf.capacity() + s->outBuf.capacity()) * sizeof(float));
    std::printf("| %-7s | %12lld | %3lld | %5d | %8d | %5d | %6d | %12.1f |\n",
                cheap ? "cheaper" : "default", perStream - wrapper,
                (perStream - wrapper) / 1024, s->st.blockSamples(),
                s->st.intervalSamples(), s->st.inputLatency(),
                s->st.outputLatency(),
                1000.0 * (s->st.inputLatency() + s->st.outputLatency()) /
                    kSampleRate);
    delete s;
  }
}

static void singleStreamSweep(const std::vector<float>& src) {
  std::printf("\n== Single stream: 20 s of output, 480-frame blocks ==\n");
  std::printf("| preset  | ratio | p50 ms | p99 ms | max ms | mean ms | CPU%% core |\n");
  std::printf("|---------|------:|-------:|-------:|-------:|--------:|----------:|\n");
  for (int cheap = 0; cheap <= 1; ++cheap) {
    for (double ratio : kRatios) {
      StretchStream s;
      s.init(cheap != 0, src, 0);
      for (int b = 0; b < 100; ++b) s.processBlock(ratio); /* warmup */
      const int nBlocks = 2000;
      std::vector<double> times;
      times.reserve(nBlocks);
      for (int b = 0; b < nBlocks; ++b) {
        auto t0 = Clock::now();
        s.processBlock(ratio);
        times.push_back(msSince(t0));
      }
      Stats st = stats(times);
      std::printf("| %-7s | %5.2f | %6.3f | %6.3f | %6.3f | %7.3f | %8.1f%% |\n",
                  cheap ? "cheaper" : "default", ratio, st.p50, st.p99, st.mx,
                  st.mean, 100.0 * st.mean / kBlockMs);
    }
  }
}

static void concurrentSweep(const std::vector<float>& src, int nStreams,
                            bool staggered) {
  std::printf(
      "\n== %d concurrent streams (single thread%s): per-block totals ==\n",
      nStreams, staggered ? ", hop-staggered" : "");
  std::printf("| preset  | ratio | p50 ms | p99 ms | max ms | CPU%% core | allocs during run |\n");
  std::printf("|---------|------:|-------:|-------:|-------:|----------:|------------------:|\n");
  for (int cheap = 0; cheap <= 1; ++cheap) {
    for (double ratio : kRatios) {
      std::vector<StretchStream> streams(nStreams);
      for (int i = 0; i < nStreams; ++i) {
        streams[i].init(cheap != 0, src, (int64_t)i * kSourceFrames / nStreams);
        if (staggered) {
          int interval = streams[i].st.intervalSamples();
          streams[i].prime((int)((int64_t)i * interval / nStreams), ratio);
        }
      }
      for (int b = 0; b < 50; ++b) /* warmup */
        for (auto& s : streams) s.processBlock(ratio);
      const int nBlocks = 1000; /* 10 s */
      std::vector<double> times;
      times.reserve(nBlocks);
      long long allocs0 = allocCount();
      for (int b = 0; b < nBlocks; ++b) {
        auto t0 = Clock::now();
        for (auto& s : streams) s.processBlock(ratio);
        times.push_back(msSince(t0));
      }
      long long allocs = allocCount() - allocs0;
      Stats st = stats(times);
      std::printf(
          "| %-7s | %5.2f | %6.3f | %6.3f | %6.3f | %8.1f%% | %18lld |\n",
          cheap ? "cheaper" : "default", ratio, st.p50, st.p99, st.mx,
          100.0 * st.mean / kBlockMs, allocs);
    }
  }
}

static void varispeedSweep(const std::vector<float>& src) {
  std::printf("\n== Varispeed (linear interp), 480-frame blocks ==\n");
  std::printf("| streams | rate | p50 ms | p99 ms | max ms | CPU%% core |\n");
  std::printf("|--------:|-----:|-------:|-------:|-------:|----------:|\n");
  for (int nStreams : {8, 64}) {
    for (double ratio : {0.5, 2.0}) {
      double rate = 1.0 / ratio;
      std::vector<VarispeedStream> streams(nStreams);
      for (int i = 0; i < nStreams; ++i)
        streams[i].init(src, (int64_t)i * kSourceFrames / nStreams);
      for (int b = 0; b < 50; ++b)
        for (auto& s : streams) s.processBlock(rate);
      const int nBlocks = 1000;
      std::vector<double> times;
      times.reserve(nBlocks);
      for (int b = 0; b < nBlocks; ++b) {
        auto t0 = Clock::now();
        for (auto& s : streams) s.processBlock(rate);
        times.push_back(msSince(t0));
      }
      Stats st = stats(times);
      std::printf("| %7d | %4.2f | %6.3f | %6.3f | %6.3f | %8.2f%% |\n",
                  nStreams, rate, st.p50, st.p99, st.mx,
                  100.0 * st.mean / kBlockMs);
    }
  }
}

static void wavDump(const std::vector<float>& src, const std::string& dir) {
  std::printf("\n== WAV dump to %s ==\n", dir.c_str());
  writeWav(dir + "/source.wav", src);
  for (int cheap = 0; cheap <= 1; ++cheap) {
    for (double ratio : {0.5, 2.0}) {
      StretchStream s;
      s.init(cheap != 0, src, 0);
      int totalOut = (int)(kSourceFrames * ratio);
      std::vector<float> out;
      out.reserve((size_t)totalOut);
      for (int done = 0; done < totalOut; done += kBlock) {
        s.processBlock(ratio);
        int n = std::min(kBlock, totalOut - done);
        out.insert(out.end(), s.outBuf.begin(), s.outBuf.begin() + n);
      }
      char base[64];
      std::snprintf(base, sizeof base, "stretch_%s_%.1fx.wav",
                    cheap ? "cheaper" : "default", ratio);
      std::string name = dir + "/" + base;
      writeWav(name, out);
      std::printf("  %s (%zu frames)\n", name.c_str(), out.size());
    }
  }
}

int main(int argc, char** argv) {
  std::string wavDir;
  bool onlyWav = false;
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == "--wav" && i + 1 < argc) wavDir = argv[++i];
    if (std::string(argv[i]) == "--only-wav") onlyWav = true;
  }

  std::printf("Signalsmith Stretch bench — %d kHz mono, %d-frame (%.0f ms) blocks\n",
              kSampleRate / 1000, kBlock, kBlockMs);
  std::printf("library version %zu.%zu.%zu\n",
              signalsmith::stretch::SignalsmithStretch<float>::version[0],
              signalsmith::stretch::SignalsmithStretch<float>::version[1],
              signalsmith::stretch::SignalsmithStretch<float>::version[2]);
#if !defined(__APPLE__)
  std::printf("NOTE: heap tracking disabled (non-Apple build)\n");
#endif

  auto src = makeSource();

  if (!onlyWav) {
    memoryReport();
    singleStreamSweep(src);
    concurrentSweep(src, 8, false);
    concurrentSweep(src, 64, false);
    concurrentSweep(src, 8, true);
    concurrentSweep(src, 64, true);
    varispeedSweep(src);
  }
  if (!wavDir.empty()) wavDump(src, wavDir);

  std::printf("\ndone\n");
  return 0;
}
