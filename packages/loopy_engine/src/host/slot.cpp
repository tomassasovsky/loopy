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

 private:
  int mode_;
};

}  // namespace

// The slot is opaque to the C engine. All heap buffers are sized once on the
// control thread (finishSlot), so the audio-thread adapter never allocates.
struct le_plugin_slot {
  loopy::IPluginHost* host = nullptr;
  std::atomic<bool> ready{false};
  std::vector<float> inL, inR;    // input accumulator for the pending block
  std::vector<float> outL, outR;  // previously-processed block, drained 1/sample
  int fill = 0;                   // samples accumulated into the current block
};

namespace {

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
    // Process the just-filled input block into the output buffers in place.
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

}  // extern "C"

#endif  // LOOPY_ENABLE_PLUGINS
