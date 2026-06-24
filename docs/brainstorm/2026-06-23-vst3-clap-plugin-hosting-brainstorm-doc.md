---
date: 2026-06-23
topic: vst3-clap-plugin-hosting
---

# VST3 & CLAP Audio Plugin Hosting

## What We're Building

Make Loopy **host third-party VST3 and CLAP audio plugins** as effects inside the
existing lane and input-monitor FX chains. A hosted plugin appears as just another
effect "type" alongside the built-in DSP kernels (drive, filter, delay, reverb…),
slotting into the engine's existing `le_fx_vtable` as a new row whose `process`
callback drives the plugin host. Users can scan for installed plugins, insert one
into any FX slot, tweak its parameters, and open the plugin's **own native editor
window**.

The hosting work targets **all three platforms** (macOS, Windows, Linux) and **both
formats simultaneously** behind one unified host abstraction. A later, separate phase
will explore the inverse direction — exporting Loopy's looper engine *as* a VST3/CLAP
plugin that loads inside a DAW — but that is explicitly out of scope for this effort.

## Why This Approach

The engine was deliberately designed for this from day one. The FX vtable
(`packages/loopy_engine/src/core/engine_fx.c:904`) and the `le_fx_type` enum
(`packages/loopy_engine/src/core/loopy_engine_api.h:169`) both carry comments stating
that "a hosted VST3/CLAP plugin can later slot in as just another row whose `process`
calls the plugin host." The UI layer (`SignalFxRack` / `EffectChainCard`) is already
abstracted over `TrackEffectType`, so a hosted-plugin card renders with minimal new
UI. The VST3 SDK relicensed to MIT (VST 3.8, Oct 2025) and CLAP is MIT, so neither
format is a licensing blocker for the MIT engine core.

Three host architectures were considered:

- **A — In-process host behind the FX vtable (CHOSEN).** Plugins run inside the audio
  callback via a new `LE_FX_PLUGIN` row; the native editor opens as a host-owned
  top-level OS window. Smallest delta to the current architecture; fastest path to a
  plugin making sound. Trade-off: a misbehaving plugin can stall Loopy's audio thread,
  and the strict RT contract (no alloc/lock/syscall in the callback) becomes
  "best effort" for plugin slots.
- **B — Out-of-process sandbox.** Each plugin runs in a child process with audio over
  a shared-memory ring and the editor owned natively by the child. Best stability and
  RT purity, but a major upfront cost (IPC, SHM audio transport, process lifecycle)
  before the first plugin sounds. **Rejected for the MVP; noted as a future hardening
  phase.**
- **C — Adopt JUCE's host framework.** Battle-tested, but JUCE is GPLv3/commercial,
  conflicting with the MIT engine core and cutting against the project's hand-rolled,
  FFI-by-hand grain. **Rejected on licensing/fit.**

Approach A follows the grain of everything already in the engine (hand-rolled C core,
miniaudio, hand-authored FFI) and reaches an end-to-end pipeline — scan → load →
process → native editor — in the fewest PRs.

## Key Decisions

- **Direction: host-first.** Host third-party plugins now; exporting Loopy *as* a
  plugin is a later, separate brainstorm. Rationale: all existing code/design notes
  target hosting; it reuses the current engine wholesale.
- **Formats: VST3 + CLAP together** behind one format-agnostic `IPluginHost` C++
  interface with per-format backends. Rationale: one unified plugin layer avoids
  reworking the Dart/repository surface when the second format lands; both SDKs are
  MIT.
- **GUI: native plugin window.** Open the plugin's own editor as a **host-owned
  top-level OS window** (NSWindow / HWND / X11), *not* embedded in the Flutter widget
  tree. Rationale: full-fidelity UX users expect, while host-ownership sidesteps the
  Flutter child-window limitation that PROGRESS.md flags as the hard part.
- **Platforms: all three** (macOS, Windows, Linux), but **sequenced macOS-first** in
  implementation since it is the only production-validated platform. Rationale: prove
  the full pipeline on Core Audio + NSView, then port scanning and window embedding.
- **Architecture: A (in-process), MVP scope.** Plugin slots are explicitly documented
  as exempt from the strict RT no-alloc contract. Out-of-process sandboxing (B) is a
  deferred hardening phase, not MVP. Rationale: fastest correct path; matches existing
  architecture.
- **Insertion point: a new `LE_FX_PLUGIN` row** in `le_fx_vtable` / `le_fx_type`,
  mirrored as a new `TrackEffectType` in both the engine package and `looper_repository`
  (plus the `fromCode` factory and the engine↔repo mapper). Rationale: this is the
  documented, lowest-friction hook; UI already renders over `TrackEffectType`.

## Open Questions

These are the hard problems to resolve during `/plan`:

- **Parameter model.** `LE_FX_PARAMS` is hardcoded to 4 normalized floats per slot.
  Real plugins expose arbitrary parameter counts. Need a dynamic per-slot parameter
  block plus new ABI calls (`le_plugin_param_count` / `_info` / `_get` / `_set`) and a
  thread-safe param-change queue into the RT callback. How do plugin slots coexist with
  the fixed 4-float surface of built-in effects?
- **Native window embedding & lifecycle.** Host owns the editor window — but how does
  Flutter trigger open/close, track the window's lifecycle, and keep it in sync with
  Loopy's session state? Platform channel + a native window controller per platform
  (NSWindow / HWND / X11). Linux X11 embedding is the least standardized; many plugins
  ship no Linux build at all — confirm Linux GUI expectations.
- **Plugin scanning ABI.** No `le_plugin_scan` exists. Need a new ABI section + C
  scanning per platform (VST3 bundle walk on macOS/Linux, registry on Windows; CLAP
  `~/.clap`, `/usr/lib/clap`, etc.) and Dart domain models for plugin descriptors.
  Sync vs. async scan? Cache results? Where do descriptors persist?
- **RT safety boundary.** Plugins alloc/lock on the audio thread. Document plugin slots
  as RT-exempt, or add a guard/timeout? Where exactly is the line drawn, and how is it
  communicated so the rest of the engine keeps its guarantees?
- **SDK vendoring & build wiring.** Vendor the VST3 SDK + CLAP headers under
  `third_party/`; wire into SPM (macOS), CMake (Windows/Linux). Note the repo is
  already GPLv3 on Windows due to the vendored ASIO SDK; confirm VST3/CLAP (MIT) don't
  worsen that and document the license posture.
- **State persistence.** Plugins carry opaque state (presets/patches) beyond exposed
  parameters. How is a hosted plugin's full state saved/restored in a Loopy session?
  The recording-is-always-dry invariant must hold — confirm plugin state lives with the
  FX chain, not the captured audio.
- **PR sequencing.** This is a large effort (host module, ABI, scanning, params, native
  windows × 3 platforms, persistence, UI). Expect a multi-PR stack — to be split in
  `/plan`, plausibly: (1) host module + ABI scaffold + scanning, (2) load/process a
  plugin (no GUI), (3) dynamic parameters + knob UI, (4) native editor window per
  platform, (5) state persistence, then Windows/Linux ports.
