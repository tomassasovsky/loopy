// Plugin chain slot: the per-slot lifecycle + the sample-to-block adapter.
//
// This is the audio-thread-facing core of plugin hosting (umbrella D-LIFE /
// D-RT). The engine's FX chain is per-sample, but VST3/CLAP plugins process in
// blocks — so each slot buffers input until a fixed block fills, calls the
// plugin once, and drains the block sample-by-sample. That costs exactly one
// block of latency per slot. The audio thread only ever reads an atomic `ready`
// flag: while a slot is loading, unloading, or failed, it renders dry
// passthrough (no click). Loading, activation, and destruction all happen on the
// control thread (see engine_plugin.c for the publish + quiescent-handshake
// teardown that guarantees no use-after-free).

#if defined(LOOPY_ENABLE_PLUGINS)

#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

#include "plugin_host.h"
#include "plugin_slot.h"

namespace {

// Adapter block size: the plugin processes kBlock frames at a time, so each slot
// adds kBlock samples of latency. 128 @ 48 kHz ≈ 2.7 ms — small, and large
// enough that plugins disliking tiny blocks behave.
constexpr int kBlock = 128;

// Deterministic test host — exercises the lifecycle, adapter, and sanitize
// boundary without a real plugin install. Never linked into a release path; it
// is reachable only via le_plugin_slot_create_stub.
class StubHost final : public loopy::IPluginHost {
 public:
  explicit StubHost(int mode) : mode_(mode) {}

  loopy::LoadStatus load(const loopy::PluginDescriptor&, double, int) override {
    return mode_ == LE_PLUGIN_STUB_UNSUPPORTED
               ? loopy::LoadStatus::unsupportedTopology
               : loopy::LoadStatus::ok;
  }

  void process(float* l, float* r, int n) override {
    // Apply params staged since the last block, in order (the SDK event-queue
    // stand-in for the stub) — fixed buffers, no allocation. paramGet then
    // reflects them, which is how the native test verifies queued delivery +
    // ordering (last write wins).
    for (int i = 0; i < pending_; ++i) {
      const int slot = paramSlot(pendingId_[i]);
      if (slot >= 0) values_[slot] = pendingVal_[i];
    }
    pending_ = 0;

    switch (mode_) {
      case LE_PLUGIN_STUB_IDENTITY:
        break;
      case LE_PLUGIN_STUB_GAIN:
        for (int i = 0; i < n; ++i) {
          l[i] *= 0.5f;
          r[i] *= 0.5f;
        }
        break;
      case LE_PLUGIN_STUB_NAN:
        for (int i = 0; i < n; ++i) {
          l[i] = NAN;
          r[i] = INFINITY;
        }
        break;
      case LE_PLUGIN_STUB_DENORMAL:
        for (int i = 0; i < n; ++i) {
          l[i] = 1e-39f;   // subnormal float
          r[i] = -1e-40f;  // subnormal float
        }
        break;
      case LE_PLUGIN_STUB_SILENCE:
      default:
        std::memset(l, 0, sizeof(float) * static_cast<size_t>(n));
        std::memset(r, 0, sizeof(float) * static_cast<size_t>(n));
        break;
    }
  }

  // Three deterministic automatable params (ids 100/200/300) for tests.
  int paramCount() override { return kParams; }

  bool paramInfoAt(int index, loopy::PluginParamInfo& out) override {
    if (index < 0 || index >= kParams) return false;
    out = loopy::PluginParamInfo{};
    out.id = kIds[index];
    out.name = std::string("Param ") + static_cast<char>('1' + index);
    out.min = 0.0;
    out.max = 1.0;
    out.def = 0.5;
    out.flags = loopy::kParamAutomatable;
    return true;
  }

  double paramGet(uint32_t id) override {
    const int slot = paramSlot(id);
    return slot >= 0 ? values_[slot] : 0.0;
  }

  void queueParam(uint32_t id, double plain) override {
    if (pending_ < kMaxPending) {
      pendingId_[pending_] = id;
      pendingVal_[pending_] = plain;
      ++pending_;
    }
  }

 private:
  static constexpr int kParams = 3;
  static constexpr int kMaxPending = 64;
  static constexpr uint32_t kIds[kParams] = {100, 200, 300};

  static int paramSlot(uint32_t id) {
    for (int i = 0; i < kParams; ++i) {
      if (kIds[i] == id) return i;
    }
    return -1;
  }

  int mode_;
  double values_[kParams] = {0.5, 0.5, 0.5};
  // Audio-thread-owned, fixed-size (no allocation in queueParam / process).
  uint32_t pendingId_[kMaxPending] = {};
  double pendingVal_[kMaxPending] = {};
  int pending_ = 0;
};

constexpr uint32_t StubHost::kIds[];

}  // namespace

// One queued parameter change handed from the control thread to the audio
// thread through the slot's lock-free SPSC ring (D-PARAM).
struct ParamChange {
  uint32_t id = 0;
  double value = 0.0;
};

// Capacity of the param ring (power of two for a cheap mask). Far beyond the
// per-block change rate of a knob drag; a full ring drops the oldest unread
// change rather than blocking or allocating.
constexpr uint32_t kParamRing = 256;

// The slot is opaque to the C engine. All heap buffers are sized once on the
// control thread (finishSlot), so the audio-thread adapter never allocates.
struct le_plugin_slot {
  loopy::IPluginHost* host = nullptr;
  std::atomic<bool> ready{false};
  std::vector<float> inL, inR;    // input accumulator for the pending block
  std::vector<float> outL, outR;  // previously-processed block, drained 1/sample
  int fill = 0;                   // samples accumulated into the current block

  // Param-change ring: control thread (producer) pushes via le_plugin_param_set;
  // the audio thread (consumer) drains it into host->queueParam at each block
  // boundary. SPSC, lock-free, allocation-free.
  ParamChange paramRing[kParamRing];
  std::atomic<uint32_t> paramHead{0};  // consumer index (audio thread)
  std::atomic<uint32_t> paramTail{0};  // producer index (control thread)
};

namespace {

// Copies a std::string into a fixed-size C char buffer, NUL-terminated and
// truncated to fit.
template <size_t N>
void copyField(char (&dst)[N], const std::string& src) {
  const size_t n = src.size() < N - 1 ? src.size() : N - 1;
  std::memcpy(dst, src.data(), n);
  dst[n] = '\0';
}

// Finalizes a slot around an already-constructed host: load+activate it bypassed
// and size the adapter buffers. Returns NULL (and deletes the host) on failure,
// writing the LE_ERR_* reason into *reason.
le_plugin_slot* finishSlot(loopy::IPluginHost* host,
                           const loopy::PluginDescriptor& desc,
                           double sampleRate, int32_t* reason) {
  if (!host) {
    if (reason) *reason = LE_ERR_INVALID;
    return nullptr;
  }
  const loopy::LoadStatus status = host->load(desc, sampleRate, kBlock);
  if (status != loopy::LoadStatus::ok) {
    if (reason) {
      *reason = status == loopy::LoadStatus::unsupportedTopology
                    ? LE_ERR_UNSUPPORTED
                    : LE_ERR_DEVICE;
    }
    delete host;
    return nullptr;
  }
  if (reason) *reason = LE_OK;
  auto* slot = new le_plugin_slot();
  slot->host = host;
  slot->inL.assign(kBlock, 0.0f);
  slot->inR.assign(kBlock, 0.0f);
  slot->outL.assign(kBlock, 0.0f);
  slot->outR.assign(kBlock, 0.0f);
  slot->fill = 0;
  slot->ready.store(false, std::memory_order_release);
  return slot;
}

}  // namespace

extern "C" {

void le_plugin_slot_process(le_plugin_slot* slot, float* l, float* r) {
  // Not-ready slots (loading / unloading / failed) pass audio through dry — the
  // audio thread never touches the host or the buffers until ready is published.
  if (!slot || !slot->ready.load(std::memory_order_acquire)) return;

  const int i = slot->fill;
  // Emit the matching sample of the last processed block (zeros for the first
  // block — this is the one-block adapter latency), then stash this input.
  const float outL = slot->outL[i];
  const float outR = slot->outR[i];
  slot->inL[i] = *l;
  slot->inR[i] = *r;
  *l = outL;
  *r = outR;

  if (++slot->fill >= kBlock) {
    slot->fill = 0;
    // Drain queued param changes into the host (it stages them for the SDK
    // event queue), then process the just-filled block in place.
    uint32_t head = slot->paramHead.load(std::memory_order_relaxed);
    const uint32_t tail = slot->paramTail.load(std::memory_order_acquire);
    while (head != tail) {
      const ParamChange& pc = slot->paramRing[head & (kParamRing - 1)];
      slot->host->queueParam(pc.id, pc.value);
      ++head;
    }
    slot->paramHead.store(head, std::memory_order_release);

    std::memcpy(slot->outL.data(), slot->inL.data(), sizeof(float) * kBlock);
    std::memcpy(slot->outR.data(), slot->inR.data(), sizeof(float) * kBlock);
    slot->host->process(slot->outL.data(), slot->outR.data(), kBlock);
  }
}

le_plugin_slot* le_plugin_slot_create(const char* plugin_id, double sample_rate,
                                      int32_t* out_reason) {
  if (!plugin_id) {
    if (out_reason) *out_reason = LE_ERR_INVALID;
    return nullptr;
  }
  loopy::PluginDescriptor desc;
  if (!loopy::findScannedPlugin(plugin_id, desc)) {
    if (out_reason) *out_reason = LE_ERR_INVALID;  // unknown id
    return nullptr;
  }
  loopy::IPluginHost* host = desc.format == loopy::PluginFormat::vst3
                                 ? loopy::createVst3Host()
                                 : loopy::createClapHost();
  return finishSlot(host, desc, sample_rate, out_reason);
}

le_plugin_slot* le_plugin_slot_create_stub(int32_t mode, double sample_rate,
                                           int32_t* out_reason) {
  return finishSlot(new StubHost(mode), loopy::PluginDescriptor{}, sample_rate,
                    out_reason);
}

void le_plugin_slot_set_ready(le_plugin_slot* slot, int32_t ready) {
  if (slot) slot->ready.store(ready != 0, std::memory_order_release);
}

void le_plugin_slot_destroy(le_plugin_slot* slot) {
  if (!slot) return;
  delete slot->host;  // control-thread destruction (VST3/CLAP teardown)
  delete slot;
}

int32_t le_plugin_param_count(le_plugin_slot* slot, int32_t* count) {
  if (!slot || !count) return LE_ERR_INVALID;
  *count = slot->host->paramCount();
  return LE_OK;
}

int32_t le_plugin_param_info_at(le_plugin_slot* slot, int32_t index,
                                le_plugin_param_info* out) {
  if (!slot || !out) return LE_ERR_INVALID;
  loopy::PluginParamInfo info;
  if (!slot->host->paramInfoAt(index, info)) return LE_ERR_INVALID;
  std::memset(out, 0, sizeof(*out));
  out->id = info.id;
  copyField(out->name, info.name);
  copyField(out->unit, info.unit);
  out->min = info.min;
  out->max = info.max;
  out->def = info.def;
  out->step_count = info.stepCount;
  out->flags = info.flags;
  return LE_OK;
}

int32_t le_plugin_param_get(le_plugin_slot* slot, uint32_t id, double* plain) {
  if (!slot || !plain) return LE_ERR_INVALID;
  *plain = slot->host->paramGet(id);
  return LE_OK;
}

int32_t le_plugin_param_set(le_plugin_slot* slot, uint32_t id, double value) {
  if (!slot) return LE_ERR_INVALID;
  // SPSC produce: drop the change if the ring is full (a stalled audio thread)
  // rather than block or allocate.
  const uint32_t tail = slot->paramTail.load(std::memory_order_relaxed);
  const uint32_t next = (tail + 1) & (kParamRing - 1);
  if (next == slot->paramHead.load(std::memory_order_acquire)) return LE_OK;
  slot->paramRing[tail] = ParamChange{id, value};
  slot->paramTail.store(next, std::memory_order_release);
  return LE_OK;
}

}  // extern "C"

#endif  // LOOPY_ENABLE_PLUGINS
