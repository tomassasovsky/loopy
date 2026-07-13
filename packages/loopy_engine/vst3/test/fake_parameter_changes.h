/*
 * fake_parameter_changes.h — minimal test-only IParameterChanges/
 * IParamValueQueue stub, shared by the part 2/3 wrapper tests
 * (vst3/delay/test_vst3_delay_wrapper.cpp, vst3/reverb/test_vst3_reverb_wrapper.cpp)
 * and the part 4 golden-parity harness (host_harness.cpp) — three call sites
 * that all need to hand a plugin's IAudioProcessor::process() a fixed set of
 * queued param changes, with no other IParameterChanges feature actually
 * exercised by any of them.
 *
 * Processor::process() only ever calls getParameterCount/getParameterData/
 * getParameterId/getPointCount/getPoint, so that's all this stub implements;
 * queryInterface/addPoint are never reached by the code under test.
 */
#pragma once

#include <vector>

#include "pluginterfaces/vst/ivstparameterchanges.h"

namespace loopy_vst3_test {

class FakeParamQueue : public Steinberg::Vst::IParamValueQueue {
 public:
  FakeParamQueue(Steinberg::Vst::ParamID id, Steinberg::Vst::ParamValue v)
      : id_(id), value_(v) {}

  Steinberg::Vst::ParamID PLUGIN_API getParameterId() SMTG_OVERRIDE { return id_; }
  Steinberg::int32 PLUGIN_API getPointCount() SMTG_OVERRIDE { return 1; }
  Steinberg::tresult PLUGIN_API getPoint(Steinberg::int32 index,
                                         Steinberg::int32& sampleOffset,
                                         Steinberg::Vst::ParamValue& value)
      SMTG_OVERRIDE {
    if (index != 0) return Steinberg::kResultFalse;
    sampleOffset = 0;
    value = value_;
    return Steinberg::kResultTrue;
  }
  Steinberg::tresult PLUGIN_API addPoint(Steinberg::int32, Steinberg::Vst::ParamValue,
                                         Steinberg::int32&) SMTG_OVERRIDE {
    return Steinberg::kNotImplemented;
  }
  Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID,
                                               void**) SMTG_OVERRIDE {
    return Steinberg::kNoInterface;
  }
  Steinberg::uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
  Steinberg::uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }

 private:
  Steinberg::Vst::ParamID id_;
  Steinberg::Vst::ParamValue value_;
};

class FakeParameterChanges : public Steinberg::Vst::IParameterChanges {
 public:
  void add(Steinberg::Vst::ParamID id, Steinberg::Vst::ParamValue v) {
    queues_.emplace_back(id, v);
  }

  Steinberg::int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE {
    return static_cast<Steinberg::int32>(queues_.size());
  }
  Steinberg::Vst::IParamValueQueue* PLUGIN_API getParameterData(
      Steinberg::int32 index) SMTG_OVERRIDE {
    if (index < 0 || index >= static_cast<Steinberg::int32>(queues_.size())) {
      return nullptr;
    }
    return &queues_[index];
  }
  Steinberg::Vst::IParamValueQueue* PLUGIN_API addParameterData(
      const Steinberg::Vst::ParamID&, Steinberg::int32&) SMTG_OVERRIDE {
    return nullptr;
  }
  Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID,
                                               void**) SMTG_OVERRIDE {
    return Steinberg::kNoInterface;
  }
  Steinberg::uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
  Steinberg::uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }

 private:
  std::vector<FakeParamQueue> queues_;
};

}  // namespace loopy_vst3_test
