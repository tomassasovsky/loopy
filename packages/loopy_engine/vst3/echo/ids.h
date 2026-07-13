/*
 * ids.h — permanent class identity for "Loopy Echo" (umbrella D-GUID).
 *
 * Minted once, here, and never regenerated — including across DSP-affecting
 * updates. A `.als` project references this plugin purely by these bytes; if
 * they ever change, every existing export referencing "Loopy Echo" silently
 * breaks (see docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md#decisions,
 * D-GUID). A DSP-behavior change that must not silently apply to old renders is
 * versioned internally (a private state flag), never by minting a new GUID.
 *
 * test_vst3_echo_ids.cpp independently hardcodes the same 16 bytes as a
 * drift regression test — if this file's literals ever change, that test
 * fails, catching an accidental edit before it ships.
 */
#pragma once

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/vst/vsttypes.h"

namespace loopy_vst3_echo {

// The single literal source for both GUIDs, one word per macro (the C
// preprocessor cannot pre-expand a single object-like macro standing in for
// several comma-separated tokens before an outer function-like macro counts
// its arguments, so a single 4-word macro can't be reused as one argument).
// DEF_VST3_CLASS (factory.cpp) needs a brace-init-list expression, not a
// named TUID array (its macro body does `const TUID lcid = processorCID;`,
// which cannot copy-construct one C array from another) — so factory.cpp
// re-invokes INLINE_UID on these same four-word macros rather than passing
// kProcessorUID/kControllerUID directly, keeping one literal source instead
// of two copies that could drift apart.
// clang-format off
#define LOOPY_ECHO_PROCESSOR_UID_1 0xD771158E
#define LOOPY_ECHO_PROCESSOR_UID_2 0x80027D4E
#define LOOPY_ECHO_PROCESSOR_UID_3 0x96FA4568
#define LOOPY_ECHO_PROCESSOR_UID_4 0xE993192E

#define LOOPY_ECHO_CONTROLLER_UID_1 0x7469D86F
#define LOOPY_ECHO_CONTROLLER_UID_2 0x85B43ED3
#define LOOPY_ECHO_CONTROLLER_UID_3 0xF723FA0B
#define LOOPY_ECHO_CONTROLLER_UID_4 0x2F1863C4

DECLARE_UID(kProcessorUID, LOOPY_ECHO_PROCESSOR_UID_1, LOOPY_ECHO_PROCESSOR_UID_2,
            LOOPY_ECHO_PROCESSOR_UID_3, LOOPY_ECHO_PROCESSOR_UID_4)
DECLARE_UID(kControllerUID, LOOPY_ECHO_CONTROLLER_UID_1, LOOPY_ECHO_CONTROLLER_UID_2,
            LOOPY_ECHO_CONTROLLER_UID_3, LOOPY_ECHO_CONTROLLER_UID_4)
// clang-format on

// Time/Feedback/Mix — matches TrackEffectType.echo's param order
// (packages/loopy_engine/lib/src/track_effect.dart). Also part of this
// plugin's persistent identity once real automation is written into a saved
// project (umbrella D-GUID's spirit extends to param tags): stable, never
// reordered or renumbered.
enum ParamId : Steinberg::Vst::ParamID { kTimeId = 0, kFeedbackId = 1, kMixId = 2 };

}  // namespace loopy_vst3_echo
