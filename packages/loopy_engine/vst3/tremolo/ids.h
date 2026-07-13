/*
 * ids.h — permanent class identity for "Loopy Tremolo" (umbrella D-GUID).
 *
 * Minted once, here, and never regenerated — including across DSP-affecting
 * updates. A `.als` project references this plugin purely by these bytes; if
 * they ever change, every existing export referencing "Loopy Tremolo" silently
 * breaks (see docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md#decisions,
 * D-GUID). A DSP-behavior change that must not silently apply to old renders is
 * versioned internally (a private state flag), never by minting a new GUID.
 *
 * test_vst3_tremolo_ids.cpp independently hardcodes the same 16 bytes as a
 * drift regression test — if this file's literals ever change, that test
 * fails, catching an accidental edit before it ships.
 */
#pragma once

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/vst/vsttypes.h"

namespace loopy_vst3_tremolo {

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
#define LOOPY_TREMOLO_PROCESSOR_UID_1 0x2D8D4187
#define LOOPY_TREMOLO_PROCESSOR_UID_2 0x3BDF8021
#define LOOPY_TREMOLO_PROCESSOR_UID_3 0x0FE2470F
#define LOOPY_TREMOLO_PROCESSOR_UID_4 0xA5D39AA0

#define LOOPY_TREMOLO_CONTROLLER_UID_1 0x419CC1E4
#define LOOPY_TREMOLO_CONTROLLER_UID_2 0x657A3171
#define LOOPY_TREMOLO_CONTROLLER_UID_3 0x7E31B5C5
#define LOOPY_TREMOLO_CONTROLLER_UID_4 0x1B056A8E

DECLARE_UID(kProcessorUID, LOOPY_TREMOLO_PROCESSOR_UID_1, LOOPY_TREMOLO_PROCESSOR_UID_2,
            LOOPY_TREMOLO_PROCESSOR_UID_3, LOOPY_TREMOLO_PROCESSOR_UID_4)
DECLARE_UID(kControllerUID, LOOPY_TREMOLO_CONTROLLER_UID_1, LOOPY_TREMOLO_CONTROLLER_UID_2,
            LOOPY_TREMOLO_CONTROLLER_UID_3, LOOPY_TREMOLO_CONTROLLER_UID_4)
// clang-format on

// Rate/Depth — matches TrackEffectType.tremolo's param order
// (packages/loopy_engine/lib/src/track_effect.dart). Rate is still a plain
// 0..1 normalized value here (D-PARAM's identity mapping, same as every
// other plugin) — fx_tremolo maps it internally to 0.1..12 Hz
// (engine_fx.c); the VST3 RangeParameter range is 0..1, not "0.1..12", so a
// host's generic display shows the same 0..1 slider Loopy's own UI uses
// (track_effect.dart's ParamReadout.none — no Hz readout exists even in the
// app itself). Also part of this plugin's persistent identity once real
// automation is written into a saved project (umbrella D-GUID's spirit
// extends to param tags): stable, never reordered or renumbered.
enum ParamId : Steinberg::Vst::ParamID { kRateId = 0, kDepthId = 1 };

}  // namespace loopy_vst3_tremolo
