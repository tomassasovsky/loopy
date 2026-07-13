/*
 * factory.cpp — "Loopy Octaver" plug-in factory + module init/deinit.
 *
 * The vendored SDK has no CMake helper modules or sample template
 * (packages/loopy_engine/third_party/vst3sdk has no *.cmake files) — this
 * shape (BEGIN_FACTORY/DEF_VST3_CLASS/END_FACTORY, split AudioEffect +
 * EditController) matches Steinberg's own reference adelay sample, not a
 * vendored template.
 */
#include "public.sdk/source/main/pluginfactory.h"

#include "controller.h"
#include "ids.h"
#include "processor.h"

#define kLoopyOctaverVersion "1.0.0"

// Called by the platform entry point (macmain.cpp) when the bundle is
// loaded/unloaded. Nothing to set up beyond static factory registration
// below.
bool InitModule() { return true; }
bool DeinitModule() { return true; }

BEGIN_FACTORY(/*vendor=*/"Loopy", /*url=*/"https://loopy.audio",
              /*email=*/"mailto:support@loopy.audio", Steinberg::PFactoryInfo::kNoFlags)

DEF_VST3_CLASS(
    "Loopy Octaver", "Fx|Pitch Shift", Steinberg::Vst::kDistributable,
    kLoopyOctaverVersion,
    INLINE_UID(LOOPY_OCTAVER_PROCESSOR_UID_1, LOOPY_OCTAVER_PROCESSOR_UID_2,
               LOOPY_OCTAVER_PROCESSOR_UID_3, LOOPY_OCTAVER_PROCESSOR_UID_4),
    loopy_vst3_octaver::Processor::createInstance,
    INLINE_UID(LOOPY_OCTAVER_CONTROLLER_UID_1, LOOPY_OCTAVER_CONTROLLER_UID_2,
               LOOPY_OCTAVER_CONTROLLER_UID_3, LOOPY_OCTAVER_CONTROLLER_UID_4),
    loopy_vst3_octaver::Controller::createInstance)

END_FACTORY
