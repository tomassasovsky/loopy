/*
 * ids.h — permanent class identity for "Loopy Octaver" (umbrella D-GUID).
 *
 * Minted once, here, and never regenerated — including across DSP-affecting
 * updates. A `.als` project references this plugin purely by these bytes; if
 * they ever change, every existing export referencing "Loopy Octaver" silently
 * breaks (see docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md#decisions,
 * D-GUID). A DSP-behavior change that must not silently apply to old renders is
 * versioned internally (a private state flag), never by minting a new GUID.
 *
 * test_vst3_octaver_ids.cpp independently hardcodes the same 16 bytes as a
 * drift regression test — if this file's literals ever change, that test
 * fails, catching an accidental edit before it ships.
 */
#pragma once

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/vst/vsttypes.h"

namespace loopy_vst3_octaver {

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
#define LOOPY_OCTAVER_PROCESSOR_UID_1 0x3D522447
#define LOOPY_OCTAVER_PROCESSOR_UID_2 0x83390B64
#define LOOPY_OCTAVER_PROCESSOR_UID_3 0x15C6CB7A
#define LOOPY_OCTAVER_PROCESSOR_UID_4 0x508CE993

#define LOOPY_OCTAVER_CONTROLLER_UID_1 0x89C9DB02
#define LOOPY_OCTAVER_CONTROLLER_UID_2 0xE3C9041B
#define LOOPY_OCTAVER_CONTROLLER_UID_3 0xF927EC11
#define LOOPY_OCTAVER_CONTROLLER_UID_4 0x70880926

DECLARE_UID(kProcessorUID, LOOPY_OCTAVER_PROCESSOR_UID_1, LOOPY_OCTAVER_PROCESSOR_UID_2,
            LOOPY_OCTAVER_PROCESSOR_UID_3, LOOPY_OCTAVER_PROCESSOR_UID_4)
DECLARE_UID(kControllerUID, LOOPY_OCTAVER_CONTROLLER_UID_1, LOOPY_OCTAVER_CONTROLLER_UID_2,
            LOOPY_OCTAVER_CONTROLLER_UID_3, LOOPY_OCTAVER_CONTROLLER_UID_4)
// clang-format on

// Shift/Tone/Mix/Mode — matches TrackEffectType.octaver's param order
// (packages/loopy_engine/lib/src/track_effect.dart). Also part of this
// plugin's persistent identity once real automation is written into a saved
// project (umbrella D-GUID's spirit extends to param tags): stable, never
// reordered or renumbered.
enum ParamId : Steinberg::Vst::ParamID { kShiftId = 0, kToneId = 1, kMixId = 2, kModeId = 3 };

}  // namespace loopy_vst3_octaver
