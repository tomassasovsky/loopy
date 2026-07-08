/*
 * factory.cpp — "Loopy Reverb" plug-in factory + module init/deinit.
 *
 * Same hand-rolled shape as part 2's Delay factory (no vendored CMake
 * helpers or sample template exist in the vendored SDK) — see
 * packages/loopy_engine/vst3/delay/factory.cpp.
 *
 * No dedicated unit test for this file specifically (same accepted scope
 * boundary as part 2's Delay factory): the bundle-build acceptance
 * criterion proves the two DEF_VST3_CLASS entries register and link, and
 * the manual Ableton check verifies the "Fx|Reverb" category/name surface a
 * host actually sees — nothing here has host-independent logic worth a
 * standalone test beyond that.
 */
#include "public.sdk/source/main/pluginfactory.h"

#include "controller.h"
#include "ids.h"
#include "processor.h"

#define kLoopyReverbVersion "1.0.0"

// Called by the platform entry point (macmain.cpp) when the bundle is
// loaded/unloaded. Nothing to set up beyond static factory registration
// below.
bool InitModule() { return true; }
bool DeinitModule() { return true; }

BEGIN_FACTORY(/*vendor=*/"Loopy", /*url=*/"https://loopy.audio",
              /*email=*/"mailto:support@loopy.audio", Steinberg::PFactoryInfo::kNoFlags)

DEF_VST3_CLASS(
    "Loopy Reverb", "Fx|Reverb", Steinberg::Vst::kDistributable, kLoopyReverbVersion,
    INLINE_UID(LOOPY_REVERB_PROCESSOR_UID_1, LOOPY_REVERB_PROCESSOR_UID_2,
               LOOPY_REVERB_PROCESSOR_UID_3, LOOPY_REVERB_PROCESSOR_UID_4),
    loopy_vst3_reverb::Processor::createInstance,
    INLINE_UID(LOOPY_REVERB_CONTROLLER_UID_1, LOOPY_REVERB_CONTROLLER_UID_2,
               LOOPY_REVERB_CONTROLLER_UID_3, LOOPY_REVERB_CONTROLLER_UID_4),
    loopy_vst3_reverb::Controller::createInstance)

END_FACTORY
