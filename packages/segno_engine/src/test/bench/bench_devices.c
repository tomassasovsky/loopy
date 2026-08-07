/*
 * bench_devices.c — what one tick of the audio-device picker's refresh costs.
 *
 * NOT part of the test gate. Build and run it with ./bench_devices.sh.
 *
 * WHY: AudioSetupCubit re-enumerates on a 1 Hz Timer.periodic, synchronously
 * over FFI on the UI isolate, in BOTH directions. One tick is therefore one
 * le_enumerate_playback_devices + one le_enumerate_capture_devices — that pair
 * is the unit this bench reports, because that pair is what the UI isolate
 * actually blocks on. Any figure per-direction or per-device understates it.
 *
 * The four modes separate the cost that was always there from the cost the
 * channel-count query added:
 *
 *   real     the shipped le_enumerate_* pair, whatever this platform does.
 *            On macOS/Windows that is the miniaudio path with the per-device
 *            ma_context_get_device_info. On Linux le_platform_enumerate_devices
 *            takes it (ALSA cards on the appliance, JACK ports on the desktop)
 *            and returns before device_info_copy, so `real` there is the
 *            platform seam and NOT the miniaudio path below.
 *   ma-lean  a local replica of the miniaudio path WITHOUT the per-device
 *            query: ma_context_init, ma_context_get_devices, copy, uninit.
 *            This is what enumerate_devices cost before the counts landed.
 *   ma-full  the same replica WITH ma_context_get_device_info per device —
 *            what it costs after. ma-full minus ma-lean is the added cost,
 *            measured rather than reasoned about.
 *   ctx      ma_context_init + ma_context_uninit alone, nothing else. The
 *            floor every mode pays twice per tick, and the number that says
 *            whether the per-device query or the context churn dominates.
 *   perdev   every single ma_context_get_device_info timed on its own, printed
 *            per device with its name. Says whether the added cost is spread
 *            evenly (so it scales with the device count) or concentrated in
 *            one slow device, and it names that device if so — which decides
 *            whether caching per device id is worth it.
 *
 * The replicas exist so the delta can be read on a single binary with no
 * production edits and no rebuild between arms — and so Linux can report what
 * the miniaudio path WOULD cost there, even though the seam short-circuits
 * before it today.
 *
 * Usage: ./bench_devices [--iters N] [--mode real|ma-lean|ma-full|ctx|perdev|all]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segno_engine_api.h"
#include "miniaudio.h"

#define BENCH_MAX_DEVICES 64

/* Monotonic wall clock in nanoseconds. CLOCK_MONOTONIC is what matters here:
 * enumeration blocks on the OS audio daemon, so CPU time would miss most of
 * what the UI isolate actually waits for. */
static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void* a, const void* b) {
  const uint64_t x = *(const uint64_t*)a;
  const uint64_t y = *(const uint64_t*)b;
  return (x > y) - (x < y);
}

/* One direction of the local miniaudio replica. `with_counts` selects whether
 * each device also gets the ma_context_get_device_info query that fills the
 * channel counts, which is the whole point of the comparison. Returns the
 * number of devices seen, or -1 if the context/enumeration failed. */
static int ma_replica(int capture, int with_counts) {
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) return -1;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(&ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    ma_context_uninit(&ctx);
    return -1;
  }
  ma_device_info* list = capture ? cap : playback;
  const ma_uint32 n = capture ? cap_count : playback_count;
  const ma_device_type type =
      capture ? ma_device_type_capture : ma_device_type_playback;
  int seen = 0;
  for (ma_uint32 i = 0; i < n && seen < BENCH_MAX_DEVICES; ++i, ++seen) {
    if (!with_counts) continue;
    ma_device_info info;
    if (ma_context_get_device_info(&ctx, type, &list[i].id, &info) !=
        MA_SUCCESS) {
      continue;
    }
    /* Read the field so no optimizer can drop the call as dead. */
    volatile ma_uint32 sink = info.nativeDataFormatCount;
    (void)sink;
  }
  ma_context_uninit(&ctx);
  return seen;
}

/* One tick, whichever mode. Fills *out_devices with the devices seen across
 * both directions so the report can state the size of the rig the numbers
 * were taken on — a 2-device laptop and a 20-device interface are not the
 * same measurement, and a per-device cost is only readable next to a count. */
typedef enum {
  MODE_REAL,
  MODE_MA_LEAN,
  MODE_MA_FULL,
  MODE_CTX,
  MODE_PERDEV
} bench_mode;

static int one_tick(bench_mode mode, int* out_devices) {
  int devices = 0;
  switch (mode) {
    case MODE_REAL: {
      static le_device_info buf[BENCH_MAX_DEVICES];
      int32_t count = 0;
      if (le_enumerate_playback_devices(buf, BENCH_MAX_DEVICES, &count) !=
          LE_OK) {
        return -1;
      }
      devices += (int)count;
      if (le_enumerate_capture_devices(buf, BENCH_MAX_DEVICES, &count) !=
          LE_OK) {
        return -1;
      }
      devices += (int)count;
      break;
    }
    case MODE_MA_LEAN:
    case MODE_MA_FULL: {
      const int with_counts = (mode == MODE_MA_FULL);
      const int p = ma_replica(/*capture=*/0, with_counts);
      const int c = ma_replica(/*capture=*/1, with_counts);
      if (p < 0 || c < 0) return -1;
      devices = p + c;
      break;
    }
    case MODE_CTX: {
      /* Twice, because a tick pays the context twice — once per direction. */
      for (int i = 0; i < 2; ++i) {
        ma_context ctx;
        if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) return -1;
        ma_context_uninit(&ctx);
      }
      break;
    }
    case MODE_PERDEV:
      /* Not a tick — reported on its own by run_perdev. */
      return -1;
  }
  if (out_devices != NULL) *out_devices = devices;
  return 0;
}

static const char* mode_name(bench_mode mode) {
  switch (mode) {
    case MODE_REAL: return "real";
    case MODE_MA_LEAN: return "ma-lean";
    case MODE_MA_FULL: return "ma-full";
    case MODE_CTX: return "ctx";
    case MODE_PERDEV: return "perdev";
  }
  return "?";
}

/* Times ma_context_get_device_info once per device, `iters` times each, and
 * prints the per-device median beside the device's name. One context for the
 * whole direction, which is what enumerate_devices does — so this measures the
 * query and not the context. */
static void run_perdev_direction(int capture, int iters, uint64_t* samples) {
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) {
    printf("  perdev  FAILED (context init)\n");
    return;
  }
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(&ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    printf("  perdev  FAILED (get_devices)\n");
    ma_context_uninit(&ctx);
    return;
  }
  ma_device_info* list = capture ? cap : playback;
  const ma_uint32 n = capture ? cap_count : playback_count;
  const ma_device_type type =
      capture ? ma_device_type_capture : ma_device_type_playback;

  for (ma_uint32 d = 0; d < n; ++d) {
    int ok = 1;
    for (int i = 0; i < iters; ++i) {
      ma_device_info info;
      const uint64_t t0 = now_ns();
      if (ma_context_get_device_info(&ctx, type, &list[d].id, &info) !=
          MA_SUCCESS) {
        ok = 0;
        break;
      }
      samples[i] = now_ns() - t0;
    }
    if (!ok) {
      printf("    %-7s %-40.40s  (query failed)\n",
             capture ? "capture" : "playback", list[d].name);
      continue;
    }
    qsort(samples, (size_t)iters, sizeof(uint64_t), cmp_u64);
    printf("    %-7s %-40.40s  %7.3f ms\n", capture ? "capture" : "playback",
           list[d].name, (double)samples[iters / 2] / 1e6);
  }
  ma_context_uninit(&ctx);
}

static void run_perdev(int iters) {
  uint64_t* samples = calloc((size_t)iters, sizeof(uint64_t));
  if (samples == NULL) return;
  printf("  perdev   ma_context_get_device_info, median per device\n");
  run_perdev_direction(/*capture=*/0, iters, samples);
  run_perdev_direction(/*capture=*/1, iters, samples);
  free(samples);
}

/* Runs `iters` ticks and prints the distribution. Median, not mean, leads:
 * enumeration contends with whatever else is talking to the audio daemon, so
 * the tail is real but it is not the typical tick. Returns the median in ns
 * (0 on failure) so main can print the ma-full/ma-lean delta. */
static uint64_t run_mode(bench_mode mode, int iters) {
  uint64_t* samples = calloc((size_t)iters, sizeof(uint64_t));
  if (samples == NULL) return 0;

  /* One warm-up tick, unrecorded: the first context init on a cold process
   * pays for loading the backend and waking the audio daemon, which no
   * subsequent 1 Hz tick pays again. Charging that to the steady-state figure
   * would overstate every mode. */
  int devices = 0;
  if (one_tick(mode, &devices) != 0) {
    printf("  %-8s FAILED (enumeration returned an error)\n", mode_name(mode));
    free(samples);
    return 0;
  }

  for (int i = 0; i < iters; ++i) {
    const uint64_t t0 = now_ns();
    if (one_tick(mode, &devices) != 0) {
      printf("  %-8s FAILED at iteration %d\n", mode_name(mode), i);
      free(samples);
      return 0;
    }
    samples[i] = now_ns() - t0;
  }

  uint64_t total = 0;
  for (int i = 0; i < iters; ++i) total += samples[i];
  qsort(samples, (size_t)iters, sizeof(uint64_t), cmp_u64);
  const uint64_t median = samples[iters / 2];
  const uint64_t p95 = samples[(int)((double)iters * 0.95) < iters
                                   ? (int)((double)iters * 0.95)
                                   : iters - 1];

  printf("  %-8s median %8.3f ms   min %8.3f   p95 %8.3f   max %8.3f"
         "   mean %8.3f",
         mode_name(mode), (double)median / 1e6, (double)samples[0] / 1e6,
         (double)p95 / 1e6, (double)samples[iters - 1] / 1e6,
         (double)total / (double)iters / 1e6);
  if (mode == MODE_CTX) {
    printf("   (2 contexts)\n");
  } else {
    printf("   (%d devices)\n", devices);
  }
  free(samples);
  return median;
}

int main(int argc, char** argv) {
  int iters = 50;
  const char* only = "all";
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--iters") == 0 && i + 1 < argc) {
      iters = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
      only = argv[++i];
    } else {
      fprintf(
          stderr,
          "usage: %s [--iters N] [--mode real|ma-lean|ma-full|ctx|perdev|all]\n",
          argv[0]);
      return 2;
    }
  }
  if (iters < 1) iters = 1;

  printf("device enumeration — one UI tick = playback pair + capture pair\n");
  printf("%d iterations, warm-up discarded\n\n", iters);

  const bench_mode modes[] = {MODE_REAL, MODE_MA_LEAN, MODE_MA_FULL, MODE_CTX,
                              MODE_PERDEV};
  uint64_t lean = 0;
  uint64_t full = 0;
  for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
    if (strcmp(only, "all") != 0 && strcmp(only, mode_name(modes[i])) != 0) {
      continue;
    }
    if (modes[i] == MODE_PERDEV) {
      run_perdev(iters);
      continue;
    }
    const uint64_t median = run_mode(modes[i], iters);
    if (modes[i] == MODE_MA_LEAN) lean = median;
    if (modes[i] == MODE_MA_FULL) full = median;
  }

  if (lean > 0 && full > 0) {
    printf("\n  channel-count query adds %+.3f ms per tick (median)\n",
           ((double)full - (double)lean) / 1e6);
  }
  return 0;
}
