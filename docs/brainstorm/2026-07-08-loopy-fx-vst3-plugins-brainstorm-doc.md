---
date: 2026-07-08
topic: loopy-fx-vst3-plugins
---

# Loopy's Built-in FX as Real VST3 Plugins

## What We're Building

Package Loopy's 7 built-in effects (Drive, Filter, Delay, Tremolo, Octaver, Echo, Reverb —
currently native DSP kernels in `packages/loopy_engine/src/core/engine_fx.c`) as 7 separate,
real, standalone VST3 plugin bundles ("Loopy Drive", "Loopy Filter", etc.), each wrapping the
exact same DSP source Loopy's own audio engine already uses. These ship bundled with the Loopy
app installer (macOS, Windows, and Linux), installing to the OS's standard VST3 folder
automatically.

`packages/daw_export` then references these real plugins by default when exporting a
performance to Ableton (`.als`), instead of the current closest-stock-Ableton-device
approximation (D-FXDEVICES) — giving bit-exact parity between what a user heard in Loopy and
what plays back in Ableton, once the plugins are installed. The current stock-device mapping
is kept as an explicit export-time fallback option, for sharing projects with people who don't
have Loopy's plugins installed.

Loopy's own live signal path is **unchanged** — the app never hosts its own plugin at runtime.
`engine_fx.c`'s kernels keep running exactly as they do today, directly, with the same
allocation-free/lock-free real-time guarantees. The VST3 build is a second, independent
consumer of the same DSP source, produced purely as a distributable artifact.

The first effort is a **pilot covering only Reverb and Delay** — proving the wrapper, build,
signing, and `daw_export` wiring pipeline end-to-end (including a real-Ableton load/playback
verification) before repeating the now-established pattern across the remaining 5 effects.

## Why This Approach

### The core architectural fork, and why "shared DSP core, dual path" won

Two ways to interpret "convert built-in FX to our own VST3s, as Loopy's default FX library"
were considered:

1. **Full conversion** — replace `engine_fx.c`'s direct calls in the live signal path with
   plugin instances loaded through Loopy's existing `IPluginHost`/`le_plugin_slot` mechanism
   (the same path third-party VST3/CLAP plugins already use). This unifies the effect chain
   onto one code path, but every built-in effect would inherit the hosting path's weaker
   "best-effort" real-time contract instead of the native kernels' guaranteed one.
2. **Shared DSP core, dual path (chosen)** — `engine_fx.c` keeps running unchanged in Loopy's
   live signal path; the VST3 build wraps the identical DSP source as a separate,
   independently-built artifact, used only when exporting to (or otherwise interoperating
   with) another DAW.

Research into the existing plugin-hosting stack (`docs/brainstorm/2026-06-23-vst3-clap-plugin-hosting-brainstorm-doc.md`,
`packages/loopy_engine/src/host/*`) confirmed this tradeoff is real, not hypothetical: the
in-process host's RT contract is explicitly documented as "best effort" — a one-block latency
adapter (`slot.cpp`'s `le_plugin_slot_process`) and a misbehaving/stalled plugin can stall the
audio callback, versus `engine_fx.c`'s guaranteed allocation-free, lock-free, per-sample
kernels (confirmed via direct code inspection — no `malloc`/`mutex`/`lock` in any per-sample
path). Converting Loopy's own always-on default effects to the weaker contract, purely to gain
architectural uniformity, was judged not worth that regression. The dual-path approach gets
100% of the DAW-export-fidelity goal with zero risk to the live app, at the cost of one small
duplication: the VST3 wrapper is a second entry point into the same kernels, not the single
code path a "full conversion" would have produced.

This is also consistent with the interesting fact — surfaced during research — that the
plugin-hosting brainstorm doc from 2026-06-23 explicitly deferred this exact idea: *"exporting
Loopy's own DSP/looper as a VST3/CLAP plugin is a later, separate brainstorm... out of scope
for this effort."* This document is that later brainstorm.

### Packaging: one plugin per effect, not one multi-mode plugin

Ableton's own stock devices are one-plugin-per-effect, so a lane's exported `.als` device chain
reads naturally (distinct named devices, not one generic device with an internal mode
selector). It also means each plugin's parameter set is exactly that effect's own (2-4 params),
rather than a superset switched by a mode parameter.

### DAW export: default to the real plugin, keep stock-device mapping as a fallback

Defaulting to the real plugin is what actually delivers the feature's value (bit-exact
parity). Keeping the current stock-device approximation as an explicit alternate export option
protects the use case of sharing a project with someone who hasn't installed Loopy's plugins —
without that fallback, every effect in a shared project would show as an offline/missing
plugin instead of at least approximating the sound.

### Platform scope: all three (macOS, Windows, Linux) from the start

The existing third-party plugin-*hosting* stack was rolled out macOS-first, with Windows and
Linux as later follow-up parts (Linux VST3 hosting isn't even finished yet). Building this
*plugin-authoring* effort was still chosen to target all three platforms from the outset,
rather than mirroring that phased rollout — noting this as a real scope increase over the
hosting precedent, to be sequenced explicitly at plan time (see Open Questions).

### GUI: generic host-rendered parameters, not custom editors

Ableton (and most VST3 hosts) auto-generate a plain parameter list for any plugin that doesn't
supply its own editor view. Shipping without a custom editor initially matches how the existing
third-party-hosting stack already leans on host/SDK facilities rather than custom UI, and avoids
a large amount of per-plugin design and native-GUI-toolkit work that doesn't block the core
value proposition (bit-exact sound).

### Rollout: pilot with Reverb + Delay before the remaining 5

Reverb is `engine_fx.c`'s most structurally complex kernel (8 comb filters + 4 allpass filters
× 2 banks of internal state); Delay is simple and well-understood. Proving the wrapper +
build/sign/package + `daw_export` + real-Ableton-verification pipeline against one hard case
and one easy case first means any needed changes to the *approach* get caught before they'd
have to be repeated across all 7 effects.

## Key Decisions

- **`engine_fx.c` is not modified or replaced.** The VST3 wrapper must compile/link against the
  exact same kernel source Loopy's engine already uses (not a reimplementation), so bit-exact
  parity is structurally guaranteed rather than maintained by manual diligence. This is what
  makes "shared DSP core" actually true.
- **One VST3 bundle per effect** (7 total for the full rollout; 2 for the pilot) — each wraps
  exactly one `engine_fx.c` kernel and exposes only that effect's own params (2-4, matching
  `TrackEffectType.params` metadata already defined in
  `packages/looper_repository/lib/src/models/track_effect.dart:70-113`).
- **Loopy's live signal path is unchanged.** No use of `IPluginHost`/`le_plugin_slot` for
  built-in effects at runtime — those remain called directly from `fx_apply_chain`
  (`engine_fx.c`, `engine_process.c:1473-1474`/`1675-1676`), exactly as today.
- **`daw_export` defaults to the real plugin, with the current stock-device mapping
  (D-FXDEVICES) retained as an explicit alternate/fallback export option** — not deleted.
- **Target all three platforms (macOS, Windows, Linux)** in this effort's overall scope,
  acknowledging this is broader than the phased rollout the third-party hosting stack used —
  actual build/sign/verify sequencing across platforms is a plan-time decision, not resolved
  here.
- **Distribution is via the Loopy app installer** — plugins install to the OS's standard VST3
  folder (e.g. `~/Library/Audio/Plug-Ins/VST3` on macOS) automatically as part of
  installing/updating the app, always version-matched to the app's own DSP. No separate
  installer/download path.
- **No custom plugin GUI initially** — rely on the host's (Ableton's) generic auto-generated
  parameter list.
- **Pilot scope is Reverb + Delay only.** The remaining 5 effects (Drive, Filter, Tremolo,
  Octaver, Echo) are explicitly out of scope until the pilot's pipeline is proven working end
  to end, including a real-Ableton load/playback check (following this repo's established
  "verify against a real Ableton load" discipline from the D-FXDEVICES work).

## Open Questions

- **Build mechanics**: how exactly does a VST3 plugin target share `engine_fx.c` with the main
  `loopy_engine` CMake target without duplicating the source file or fighting the existing
  `LOOPY_ENABLE_PLUGINS` gating (`packages/loopy_engine/src/CMakeLists.txt`)? Needs a concrete
  CMake target design at plan time.
- **Plugin identity/versioning**: what VST3 vendor name, plugin IDs/GUIDs, and version scheme
  should "Loopy FX" plugins use, and how do these interact with the existing `PluginRef`
  (`format`, stable `id`, `version`) model already used for third-party hosted plugins
  (`packages/loopy_engine/lib/src/track_effect.dart:181-221`)? Should exported `.als` files
  reference a plugin version compatible with the D-MISS-style
  `unavailable`/`unsupported`/`versionChanged` handling that already exists for hosted plugins,
  in case a captured performance predates a later plugin DSP change?
  - Note: because these are *our own* plugins wrapping the same DSP as the always-current app,
    this is a smaller concern than for third-party plugins — but old exported performance
    captures could still reference a Loopy plugin version older than what's currently
    installed, and that interaction hasn't been designed yet.
- **Cross-platform build/sign sequencing**: given all three platforms are targeted but the
  hosting-stack precedent went macOS-first, should the pilot itself target all three platforms,
  or build/verify on macOS first (matching how the rest of this repo's native work has been
  sequenced) and treat Windows/Linux as fast-follow parts once the pilot's approach is proven?
- **`daw_export` UX for the fallback toggle**: what does the "use Loopy plugins vs. use stock
  Ableton devices" choice look like in the app's export flow (a setting, a per-export prompt, a
  toggle in `PerformanceCompletionSheet`)? Not designed yet.
- **CLAP**: this effort is VST3-only (Ableton doesn't host CLAP), but the existing hosting stack
  supports both formats — worth a explicit decision at plan time on whether a CLAP build is ever
  wanted, or genuinely out of scope (YAGNI) since no target host needs it.
- **VST3 SDK plugin-authoring helpers**: `third_party/vst3sdk/public.sdk/source/vst/` is
  vendored primarily for hosting, but includes the SDK's standard plugin-building helper
  sources — needs a closer read at plan time to confirm what's usable as-is vs. what a from-
  scratch VST3 plugin target actually needs.
