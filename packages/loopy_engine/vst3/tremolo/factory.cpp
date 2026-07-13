/*
 * factory.cpp — "Loopy Tremolo" plug-in factory + module init/deinit.
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

#define kLoopyTremoloVersion "1.0.0"

// Called by the platform entry point (macmain.cpp) when the bundle is
// loaded/unloaded. Nothing to set up beyond static factory registration
// below.
bool InitModule() { return true; }
bool DeinitModule() { return true; }

BEGIN_FACTORY(/*vendor=*/"Loopy", /*url=*/"https://loopy.audio",
              /*email=*/"mailto:support@loopy.audio", Steinberg::PFactoryInfo::kNoFlags)

DEF_VST3_CLASS(
    "Loopy Tremolo", "Fx|Modulation", Steinberg::Vst::kDistributable,
    kLoopyTremoloVersion,
    INLINE_UID(LOOPY_TREMOLO_PROCESSOR_UID_1, LOOPY_TREMOLO_PROCESSOR_UID_2,
               LOOPY_TREMOLO_PROCESSOR_UID_3, LOOPY_TREMOLO_PROCESSOR_UID_4),
    loopy_vst3_tremolo::Processor::createInstance,
    INLINE_UID(LOOPY_TREMOLO_CONTROLLER_UID_1, LOOPY_TREMOLO_CONTROLLER_UID_2,
               LOOPY_TREMOLO_CONTROLLER_UID_3, LOOPY_TREMOLO_CONTROLLER_UID_4),
    loopy_vst3_tremolo::Controller::createInstance)

END_FACTORY
