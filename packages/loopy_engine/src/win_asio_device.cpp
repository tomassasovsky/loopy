/*
 * win_asio_device.cpp — opt-in Windows ASIO duplex device backend (Part 2).
 *
 * Built ONLY when LOOPY_ENABLE_ASIO is set (see CMakeLists.txt + docs/
 * WINDOWS_ASIO.md). Implements the le_device_backend seam with a real ASIO
 * capture/playback device so a pro multichannel interface (e.g. an 18-in/20-out
 * Focusrite) runs at its full channel count, which the shared OS mixer never
 * exposes.
 *
 * What this TU absorbs so the engine core never sees ASIO's quirks:
 *   1. Non-interleaved, per-channel buffers      -> le_deinterleave_in / _out
 *   2. Native sample formats (Int16/24/32, F32)  -> le_deinterleave_in / _out
 *   3. ASIO's own RT thread + buffer-switch model -> all conversion + the call to
 *      le_engine_process happen inside bufferSwitch, on pre-allocated scratch
 *      (no allocation/locking in the callback — the engine's RT contract holds).
 *
 * Channel mapping is direct: ASIO channel c -> engine channel c. The driver's
 * channel counts (clamped to LE_MAX_CHANNELS) become the engine's negotiated
 * counts; le_engine_process and the rest of the engine are reused unchanged.
 *
 * Re-entrancy: the ASIO host SDK loads a single process-global driver, so the
 * device backend and le_enumerate_asio_drivers must never both touch it. While a
 * device is open, enumeration reports the open driver only (it probes nothing).
 *
 * Licensing: the Steinberg ASIO SDK is GPLv3-or-proprietary and is vendored
 * under third_party/asiosdk (this repo is GPL-3.0-or-later).
 *
 * Lifecycle-flag note: this is a C++ TU and cannot include engine_private.h (its
 * struct uses the C11 `_Atomic` keyword), so it publishes "started" through the
 * C helper le_engine_mark_started; le_engine_stop clears the flags above the seam.
 */
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <stdlib.h>
#include <string.h>

// User-supplied Steinberg ASIO SDK (LOOPY_ASIO_SDK_DIR on the include path).
// asiosys.h MUST precede asio.h: it defines the platform macros (IEEE754_64FLOAT,
// NATIVE_INT64, …) that asio.h reads to pick its native types — without it,
// asio.h falls back to the non-Windows ASIOSampleRate struct instead of `double`.
#include "asiosys.h"
#include "asio.h"
#include "asiodrivers.h"

// loadAsioDriver() is defined in the SDK host glue (asiodrivers.cpp) but declared
// in no SDK header, so the host declares it itself (as hostsample.cpp does). C++
// linkage — keep it OUTSIDE the extern "C" engine includes below.
bool loadAsioDriver(char* name);

extern "C" {
#include "engine_internal.h"  // le_deinterleave_in/_out, le_asio_pick_buffer,
                              // le_engine_process, le_engine_mark_started
#include "le_device_backend.h"  // le_device_backend, le_device_open_result
#include "loopy_engine_api.h"   // le_engine, le_config, LE_MAX_CHANNELS, le_result
#include "win_asio_device.h"    // le_asio_backend
}

namespace {

constexpr int kMaxAsioDrivers = 32;
constexpr int kAsioNameLen = 32;  // ASIO driver/channel names are char[32].

// The open ASIO device's state. ASIO is process-global (one loaded driver), so a
// single file-static instance matches the SDK's own model. The static callbacks
// reach the engine through `engine`, cleared only after ASIOStop returns.
struct AsioState {
  le_engine* engine;
  long input_channels;
  long output_channels;
  long buffer_frames;
  le_sample_fmt in_fmt[LE_MAX_CHANNELS];
  le_sample_fmt out_fmt[LE_MAX_CHANNELS];
  ASIOBufferInfo buffer_infos[2 * LE_MAX_CHANNELS];  // inputs first, then outputs
  float* in_scratch;   // buffer_frames * input_channels, interleaved
  float* out_scratch;  // buffer_frames * output_channels, interleaved
  ASIOCallbacks callbacks;
  bool post_output;  // driver supports ASIOOutputReady()
  bool active;       // a device is currently open (buffers created)
  // Matches le_config.asio_driver / le_device_open_result.device_name (256), so
  // the name reported by le_enumerate_asio_drivers while open is never truncated.
  char driver_name[256];
};

AsioState g_asio;

// Maps an ASIO native sample type to the engine's le_sample_fmt. Returns false
// for a format outside the common Int16/Int24/Int32/Float32 set (per-driver
// format edge cases are an explicit out-of-scope follow-up); the caller then
// fails the open loudly (Windows is ASIO-only) rather than play noise.
bool map_format(ASIOSampleType type, le_sample_fmt* out) {
  switch (type) {
    case ASIOSTInt16LSB: *out = LE_SMP_I16; return true;
    case ASIOSTInt24LSB: *out = LE_SMP_I24; return true;
    case ASIOSTInt32LSB: *out = LE_SMP_I32; return true;
    case ASIOSTFloat32LSB: *out = LE_SMP_F32; return true;
    default: return false;
  }
}

// Input-channel names collected at open, fed to the portable mask builder so the
// loopback-exclusion logic stays shared with macOS (le_excluded_mask_from_names /
// le_label_is_loopback) and no ASIO-specific string matching leaks into it.
struct AsioInputNames {
  char names[LE_MAX_CHANNELS][kAsioNameLen];
  int count;
};

const char* asio_input_name(void* ctx, int channel) {
  const AsioInputNames* n = static_cast<const AsioInputNames*>(ctx);
  if (channel < 0 || channel >= n->count) return nullptr;
  return n->names[channel];
}

// Fills `out` (room for 8) with the standard buffer sizes the driver actually
// allows for its (min,max,preferred,granularity) — reusing le_asio_pick_buffer
// so the validity rule matches what open() will snap to — and always includes
// the driver's preferred size. Ascending. Returns the count. Driver must be
// ASIOInit'd. The same probe backs the UI chips and the open-time snap.
int fill_asio_buffers(int32_t* out, long bmin, long bmax, long bpref,
                      long bgran) {
  static const int32_t kStd[] = {32, 64, 128, 256, 512, 1024, 2048};
  int n = 0;
  for (size_t i = 0; i < sizeof(kStd) / sizeof(kStd[0]) && n < 8; ++i) {
    if (le_asio_pick_buffer(kStd[i], static_cast<int32_t>(bmin),
                            static_cast<int32_t>(bmax),
                            static_cast<int32_t>(bpref),
                            static_cast<int32_t>(bgran)) == kStd[i]) {
      out[n++] = kStd[i];
    }
  }
  bool has_pref = false;
  for (int i = 0; i < n; ++i) {
    if (out[i] == static_cast<int32_t>(bpref)) has_pref = true;
  }
  if (!has_pref && n < 8) out[n++] = static_cast<int32_t>(bpref);
  for (int i = 1; i < n; ++i) {  // insertion sort (preferred may be appended)
    const int32_t v = out[i];
    int j = i - 1;
    while (j >= 0 && out[j] > v) {
      out[j + 1] = out[j];
      --j;
    }
    out[j + 1] = v;
  }
  return n;
}

// Fills `out` (room for 8) with the standard sample rates the driver accepts
// (ASIOCanSampleRate). Driver must be ASIOInit'd. Returns the count.
int fill_asio_rates(int32_t* out) {
  static const int32_t kStd[] = {44100, 48000, 88200, 96000, 176400, 192000};
  int n = 0;
  for (size_t i = 0; i < sizeof(kStd) / sizeof(kStd[0]) && n < 8; ++i) {
    if (ASIOCanSampleRate(static_cast<ASIOSampleRate>(kStd[i])) == ASE_OK) {
      out[n++] = kStd[i];
    }
  }
  return n;
}

// Frees the pre-allocated scratch buffers (idempotent).
void free_scratch() {
  free(g_asio.in_scratch);
  free(g_asio.out_scratch);
  g_asio.in_scratch = nullptr;
  g_asio.out_scratch = nullptr;
}

// ---- ASIO callbacks (static; reach the engine through g_asio.engine) --------

// The ASIO real-time callback: de-interleave each input block into the engine's
// interleaved scratch, run le_engine_process, interleave each output block back.
// No allocation/locking — the engine's RT contract is preserved.
void asio_buffer_switch(long index, ASIOBool /*directProcess*/) {
  AsioState* s = &g_asio;
  le_engine* e = s->engine;
  if (e == nullptr) return;  // teardown raced us (shouldn't after ASIOStop)
  const int frames = static_cast<int>(s->buffer_frames);
  const int ic = static_cast<int>(s->input_channels);
  const int oc = static_cast<int>(s->output_channels);

  for (int c = 0; c < ic; ++c) {
    le_deinterleave_in(s->in_scratch, s->buffer_infos[c].buffers[index],
                       s->in_fmt[c], c, ic, frames);
  }
  le_engine_process(e, s->out_scratch, s->in_scratch,
                    static_cast<uint32_t>(frames));
  for (int c = 0; c < oc; ++c) {
    le_interleave_out(s->buffer_infos[ic + c].buffers[index], s->out_scratch,
                      s->out_fmt[c], c, oc, frames);
  }
  if (s->post_output) ASIOOutputReady();
}

ASIOTime* asio_buffer_switch_time_info(ASIOTime* params, long index,
                                       ASIOBool process) {
  asio_buffer_switch(index, process);
  return params;
}

void asio_sample_rate_did_change(ASIOSampleRate /*rate*/) {
  // v1: sample-rate / reset / hot-swap handling is deferred (Out of Scope). The
  // seam keeps this callback so it can be wired later; for now it is a no-op.
}

long asio_messages(long selector, long value, void* /*message*/,
                   double* /*opt*/) {
  switch (selector) {
    case kAsioSelectorSupported:
      // Acknowledge the queries we answer below; decline everything else.
      if (value == kAsioEngineVersion || value == kAsioSupportsTimeInfo) {
        return 1L;
      }
      return 0L;
    case kAsioEngineVersion:
      return 2L;  // ASIO 2.
    case kAsioSupportsTimeInfo:
      return 1L;  // use bufferSwitchTimeInfo (delegates to bufferSwitch).
    case kAsioResetRequest:
      // Hot reset / device re-open is deferred (Out of Scope). Decline so the
      // driver does not expect us to re-create buffers mid-stream.
      return 0L;
    default:
      return 0L;
  }
}

// Fully releases the open device: ASIOStop FIRST (the ASIO spec guarantees
// bufferSwitch is not called again once it returns), THEN clear the engine
// pointer (so no callback can race teardown), dispose buffers, exit the driver,
// and free scratch. Idempotent: safe as both stop() and close(), and a no-op if
// nothing is open.
void asio_teardown() {
  if (!g_asio.active) {
    // Still free any scratch a failed open may have left, and clear the pointer.
    g_asio.engine = nullptr;
    free_scratch();
    return;
  }
  ASIOStop();
  g_asio.engine = nullptr;  // only after ASIOStop returns (no use-after-free)
  ASIODisposeBuffers();
  ASIOExit();
  free_scratch();
  g_asio.active = false;
}

// ---- le_device_backend vtable ----------------------------------------------

int32_t le_asio_open(le_engine* engine, const le_config* config,
                     le_device_open_result* out) {
  memset(&g_asio, 0, sizeof(g_asio));
  if (config->asio_driver[0] == '\0') return LE_ERR_DEVICE;

  if (!loadAsioDriver(const_cast<char*>(config->asio_driver))) {
    return LE_ERR_DEVICE;
  }
  ASIODriverInfo info;
  memset(&info, 0, sizeof(info));
  info.asioVersion = 2;
  info.sysRef = GetDesktopWindow();  // ASIO wants an HWND; we need no UI.
  if (ASIOInit(&info) != ASE_OK) {
    ASIOExit();
    return LE_ERR_DEVICE;
  }

  long max_in = 0;
  long max_out = 0;
  if (ASIOGetChannels(&max_in, &max_out) != ASE_OK) {
    ASIOExit();
    return LE_ERR_DEVICE;
  }
  if (max_in > LE_MAX_CHANNELS) max_in = LE_MAX_CHANNELS;
  if (max_out > LE_MAX_CHANNELS) max_out = LE_MAX_CHANNELS;
  if (max_in <= 0 || max_out <= 0) {  // duplex engine needs both directions
    ASIOExit();
    return LE_ERR_DEVICE;
  }

  // Sample rate: request the configured rate, else keep the driver's current.
  ASIOSampleRate rate =
      static_cast<ASIOSampleRate>(config->sample_rate > 0 ? config->sample_rate
                                                          : 48000);
  if (ASIOCanSampleRate(rate) != ASE_OK || ASIOSetSampleRate(rate) != ASE_OK) {
    if (ASIOGetSampleRate(&rate) != ASE_OK) {
      ASIOExit();
      return LE_ERR_DEVICE;
    }
  }

  // Buffer size: snap the requested size into the driver's allowed set.
  long bmin = 0;
  long bmax = 0;
  long bpref = 0;
  long bgran = 0;
  if (ASIOGetBufferSize(&bmin, &bmax, &bpref, &bgran) != ASE_OK) {
    ASIOExit();
    return LE_ERR_DEVICE;
  }
  const int32_t want_buf = config->buffer_frames > 0
                               ? config->buffer_frames
                               : static_cast<int32_t>(bpref);
  const long bufsize = static_cast<long>(le_asio_pick_buffer(
      want_buf, static_cast<int32_t>(bmin), static_cast<int32_t>(bmax),
      static_cast<int32_t>(bpref), static_cast<int32_t>(bgran)));

  // Per-channel native formats (any unsupported format fails the open). Input
  // channel names are also collected here, from the already-open driver, to
  // build the loopback-excluded mask — re-probing labels via win_asio_labels
  // while the device is open would tear it down (R1).
  AsioInputNames in_names;
  in_names.count = 0;
  for (int c = 0; c < max_in; ++c) {
    ASIOChannelInfo ci;
    memset(&ci, 0, sizeof(ci));
    ci.channel = c;
    ci.isInput = ASIOTrue;
    if (ASIOGetChannelInfo(&ci) != ASE_OK ||
        !map_format(ci.type, &g_asio.in_fmt[c])) {
      ASIOExit();
      return LE_ERR_DEVICE;
    }
    strncpy(in_names.names[c], ci.name, kAsioNameLen - 1);
    in_names.names[c][kAsioNameLen - 1] = '\0';
    in_names.count++;
  }
  for (int c = 0; c < max_out; ++c) {
    ASIOChannelInfo ci;
    memset(&ci, 0, sizeof(ci));
    ci.channel = c;
    ci.isInput = ASIOFalse;
    if (ASIOGetChannelInfo(&ci) != ASE_OK ||
        !map_format(ci.type, &g_asio.out_fmt[c])) {
      ASIOExit();
      return LE_ERR_DEVICE;
    }
  }

  // Buffer-info table: inputs first, then outputs (matching the callback's
  // de-interleave / interleave indexing).
  for (int c = 0; c < max_in; ++c) {
    g_asio.buffer_infos[c].isInput = ASIOTrue;
    g_asio.buffer_infos[c].channelNum = c;
    g_asio.buffer_infos[c].buffers[0] = nullptr;
    g_asio.buffer_infos[c].buffers[1] = nullptr;
  }
  for (int c = 0; c < max_out; ++c) {
    const int idx = static_cast<int>(max_in) + c;
    g_asio.buffer_infos[idx].isInput = ASIOFalse;
    g_asio.buffer_infos[idx].channelNum = c;
    g_asio.buffer_infos[idx].buffers[0] = nullptr;
    g_asio.buffer_infos[idx].buffers[1] = nullptr;
  }

  // Pre-allocate interleaved scratch BEFORE ASIOCreateBuffers registers the RT
  // callback, so the callback never allocates.
  g_asio.engine = engine;
  g_asio.input_channels = max_in;
  g_asio.output_channels = max_out;
  g_asio.buffer_frames = bufsize;
  g_asio.in_scratch = static_cast<float*>(
      calloc(static_cast<size_t>(bufsize) * max_in, sizeof(float)));
  g_asio.out_scratch = static_cast<float*>(
      calloc(static_cast<size_t>(bufsize) * max_out, sizeof(float)));
  if (g_asio.in_scratch == nullptr || g_asio.out_scratch == nullptr) {
    free_scratch();
    g_asio.engine = nullptr;
    ASIOExit();
    return LE_ERR_DEVICE;
  }

  g_asio.callbacks.bufferSwitch = asio_buffer_switch;
  g_asio.callbacks.sampleRateDidChange = asio_sample_rate_did_change;
  g_asio.callbacks.asioMessage = asio_messages;  // SDK field is singular
  g_asio.callbacks.bufferSwitchTimeInfo = asio_buffer_switch_time_info;

  if (ASIOCreateBuffers(g_asio.buffer_infos, max_in + max_out, bufsize,
                        &g_asio.callbacks) != ASE_OK) {
    free_scratch();
    g_asio.engine = nullptr;
    ASIOExit();
    return LE_ERR_DEVICE;
  }
  g_asio.post_output = (ASIOOutputReady() == ASE_OK);
  g_asio.active = true;
  strncpy(g_asio.driver_name, config->asio_driver,
          sizeof(g_asio.driver_name) - 1);
  g_asio.driver_name[sizeof(g_asio.driver_name) - 1] = '\0';

  out->sample_rate = static_cast<int32_t>(rate + 0.5);
  out->input_channels = static_cast<int32_t>(max_in);
  out->output_channels = static_cast<int32_t>(max_out);
  out->buffer_frames = static_cast<int32_t>(bufsize);
  out->active_backend = LE_BACKEND_ASIO;
  // Loopback-excluded inputs from the driver's own channel labels (e.g. a
  // Scarlett's "Loop 1/2"), shared with the macOS Core Audio path.
  out->excluded_input_mask =
      le_excluded_mask_from_names(asio_input_name, &in_names,
                                  static_cast<int>(max_in));
  strncpy(out->device_name, config->asio_driver, sizeof(out->device_name) - 1);
  out->device_name[sizeof(out->device_name) - 1] = '\0';
  return LE_OK;
}

int32_t le_asio_start(le_engine* engine) {
  if (ASIOStart() != ASE_OK) return LE_ERR_DEVICE;
  le_engine_mark_started(engine);  // publishes device-present + running (C side)
  return LE_OK;
}

int32_t le_asio_stop(le_engine* /*engine*/) {
  asio_teardown();
  return LE_OK;
}

void le_asio_close(le_engine* /*engine*/) { asio_teardown(); }

}  // namespace

extern "C" const le_device_backend le_asio_backend = {
    le_asio_open,
    le_asio_start,
    le_asio_stop,
    le_asio_close,
};

// ASIO driver enumeration with a per-driver channel-count probe. Mirrors the
// label probe's defensive style: a driver that fails to load/init is omitted,
// and the whole call degrades to *count = 0 rather than erroring.
//
// Re-entrancy (R1): the ASIO host SDK loads ONE process-global driver, so this
// must never probe while a device is open — doing so would ASIOExit the live
// stream. While g_asio.active, it reports only the open driver (probing nothing);
// the Dart layer additionally never calls this while running on ASIO.
extern "C" int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                             int32_t* count) {
  if (out == nullptr || count == nullptr || max <= 0) return LE_ERR_INVALID;
  *count = 0;

  // A device is open: report it without touching the global driver state.
  if (g_asio.active) {
    strncpy(out[0].id, g_asio.driver_name, sizeof(out[0].id) - 1);
    out[0].id[sizeof(out[0].id) - 1] = '\0';
    strncpy(out[0].name, g_asio.driver_name, sizeof(out[0].name) - 1);
    out[0].name[sizeof(out[0].name) - 1] = '\0';
    out[0].is_default = 0;
    out[0].input_channels = static_cast<int32_t>(g_asio.input_channels);
    out[0].output_channels = static_cast<int32_t>(g_asio.output_channels);
    *count = 1;
    return LE_OK;
  }

  char name_storage[kMaxAsioDrivers][kAsioNameLen];
  char* name_ptrs[kMaxAsioDrivers];
  for (int i = 0; i < kMaxAsioDrivers; ++i) name_ptrs[i] = name_storage[i];
  AsioDrivers drivers;
  const long driver_count = drivers.getDriverNames(name_ptrs, kMaxAsioDrivers);

  int32_t written = 0;
  for (long i = 0; i < driver_count && written < max; ++i) {
    if (!loadAsioDriver(name_ptrs[i])) continue;
    ASIODriverInfo info;
    memset(&info, 0, sizeof(info));
    info.asioVersion = 2;
    info.sysRef = GetDesktopWindow();
    if (ASIOInit(&info) != ASE_OK) {
      ASIOExit();
      continue;
    }
    long in_ch = 0;
    long out_ch = 0;
    const bool ok = ASIOGetChannels(&in_ch, &out_ch) == ASE_OK;
    // Probe the driver's buffer-size set and supported sample rates while it is
    // still ASIOInit'd, so the picker can offer the driver's real options.
    int32_t bufs[8];
    int n_bufs = 0;
    int32_t rates[8];
    int n_rates = 0;
    if (ok) {
      long bmin = 0;
      long bmax = 0;
      long bpref = 0;
      long bgran = 0;
      if (ASIOGetBufferSize(&bmin, &bmax, &bpref, &bgran) == ASE_OK) {
        n_bufs = fill_asio_buffers(bufs, bmin, bmax, bpref, bgran);
      }
      n_rates = fill_asio_rates(rates);
    }
    ASIOExit();  // release the global driver before the next probe / returning
    if (!ok) continue;

    le_device_info* d = &out[written];
    strncpy(d->id, name_ptrs[i], sizeof(d->id) - 1);
    d->id[sizeof(d->id) - 1] = '\0';
    strncpy(d->name, name_ptrs[i], sizeof(d->name) - 1);
    d->name[sizeof(d->name) - 1] = '\0';
    d->is_default = 0;
    d->input_channels = static_cast<int32_t>(in_ch);
    d->output_channels = static_cast<int32_t>(out_ch);
    for (int b = 0; b < n_bufs; ++b) d->asio_buffer_sizes[b] = bufs[b];
    d->asio_buffer_count = n_bufs;
    for (int r = 0; r < n_rates; ++r) d->asio_sample_rates[r] = rates[r];
    d->asio_sample_rate_count = n_rates;
    ++written;
  }
  *count = written;
  return LE_OK;
}

#else
typedef int loopy_win_asio_device_tu_unused; /* keep the TU non-empty when off */
#endif
