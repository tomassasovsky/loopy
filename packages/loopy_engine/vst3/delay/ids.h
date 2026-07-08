/*
 * ids.h — permanent class identity for "Loopy Delay" (umbrella D-GUID).
 *
 * Minted once, here, and never regenerated — including across DSP-affecting
 * updates. A `.als` project references this plugin purely by these bytes; if
 * they ever change, every existing export referencing "Loopy Delay" silently
 * breaks (see docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md#decisions,
 * D-GUID). A DSP-behavior change that must not silently apply to old renders is
 * versioned internally (a private state flag), never by minting a new GUID.
 *
 * test_vst3_delay_ids.cpp independently hardcodes the same 16 bytes as a
 * drift regression test — if this file's literals ever change, that test
 * fails, catching an accidental edit before it ships.
 */
#pragma once

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/vst/vsttypes.h"

namespace loopy_vst3_delay {

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
#define LOOPY_DELAY_PROCESSOR_UID_1 0x153409AB
#define LOOPY_DELAY_PROCESSOR_UID_2 0xA7B2437F
#define LOOPY_DELAY_PROCESSOR_UID_3 0x83B5A2A6
#define LOOPY_DELAY_PROCESSOR_UID_4 0xC60EF9B6

#define LOOPY_DELAY_CONTROLLER_UID_1 0x0B3FA021
#define LOOPY_DELAY_CONTROLLER_UID_2 0x75864776
#define LOOPY_DELAY_CONTROLLER_UID_3 0xBF60F8D9
#define LOOPY_DELAY_CONTROLLER_UID_4 0x838C33C8

DECLARE_UID(kProcessorUID, LOOPY_DELAY_PROCESSOR_UID_1, LOOPY_DELAY_PROCESSOR_UID_2,
            LOOPY_DELAY_PROCESSOR_UID_3, LOOPY_DELAY_PROCESSOR_UID_4)
DECLARE_UID(kControllerUID, LOOPY_DELAY_CONTROLLER_UID_1, LOOPY_DELAY_CONTROLLER_UID_2,
            LOOPY_DELAY_CONTROLLER_UID_3, LOOPY_DELAY_CONTROLLER_UID_4)
// clang-format on

// Time/Feedback/Mix — matches TrackEffectType.delay's param order
// (packages/loopy_engine/lib/src/track_effect.dart). Also part of this
// plugin's persistent identity once real automation is written into a saved
// project (umbrella D-GUID's spirit extends to param tags): stable, never
// reordered or renumbered.
enum ParamId : Steinberg::Vst::ParamID { kTimeId = 0, kFeedbackId = 1, kMixId = 2 };

}  // namespace loopy_vst3_delay
