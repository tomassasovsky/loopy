/*
 * factory.cpp — "Segno Tremolo" plug-in factory + module init/deinit.
 *
 * The vendored SDK has no CMake helper modules or sample template
 * (packages/segno_engine/third_party/vst3sdk has no *.cmake files) — this
 * shape (BEGIN_FACTORY/DEF_VST3_CLASS/END_FACTORY, split AudioEffect +
 * EditController) matches Steinberg's own reference adelay sample, not a
 * vendored template.
 */
#include "public.sdk/source/main/pluginfactory.h"

#include "controller.h"
#include "ids.h"
#include "processor.h"

#define kSegnoTremoloVersion "1.0.0"

// Called by the platform entry point (macmain.cpp) when the bundle is
// loaded/unloaded. Nothing to set up beyond static factory registration
// below.
bool InitModule() { return true; }
bool DeinitModule() { return true; }

BEGIN_FACTORY(/*vendor=*/"Segno", /*url=*/"https://segno.audio",
              /*email=*/"mailto:support@segno.audio", Steinberg::PFactoryInfo::kNoFlags)

DEF_VST3_CLASS(
    "Segno Tremolo", "Fx|Modulation", Steinberg::Vst::kDistributable,
    kSegnoTremoloVersion,
    INLINE_UID(SEGNO_TREMOLO_PROCESSOR_UID_1, SEGNO_TREMOLO_PROCESSOR_UID_2,
               SEGNO_TREMOLO_PROCESSOR_UID_3, SEGNO_TREMOLO_PROCESSOR_UID_4),
    segno_vst3_tremolo::Processor::createInstance,
    INLINE_UID(SEGNO_TREMOLO_CONTROLLER_UID_1, SEGNO_TREMOLO_CONTROLLER_UID_2,
               SEGNO_TREMOLO_CONTROLLER_UID_3, SEGNO_TREMOLO_CONTROLLER_UID_4),
    segno_vst3_tremolo::Controller::createInstance)

END_FACTORY
