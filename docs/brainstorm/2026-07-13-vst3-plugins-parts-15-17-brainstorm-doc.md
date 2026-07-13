# Brainstorm: loopy-fx-vst3-plugins parts 15–17 (undefined tail)

**Date:** 2026-07-13 · **Status:** needs a decision (which options become 15/16/17)

The `loopy-fx-vst3-plugins` series shipped parts 1–14: the seven FX plugins
(Delay, Reverb, Echo, Drive, Filter, Tremolo, Octaver) as real `.vst3` on
**macOS + Windows + Linux**, with a per-OS CTest gate (GUID + golden-parity +
wrapper + load-smoke) in CI, plus `.als` device-chain export. **Part 12** (macOS
notarization) is dropped — not needed absent a paid Apple Developer Program
(ad-hoc signing loads locally; distribution documents `xattr -dr
com.apple.quarantine`).

**Parts 15–17 were never specified** — no breadcrumb exists in code or docs. This
doc proposes candidates so you can pick. None is committed; I did not build any
(inventing unspecified product scope isn't safe to ship blind).

## Candidate parts (ranked by value × fit)

### A. `pluginval` / validator CI gate  — *recommended first*
Run a real host-grade validator against each built bundle in the
`vst3-plugins-*` CI jobs, beyond today's `dlopen`+`GetPluginFactory` load-smoke.
- **Why:** cheapest, highest-confidence quality win. Catches real-host issues the
  load-smoke can't — state save/restore, parameter bounds, thread-safety,
  bus/channel arrangements, allocation-on-audio-thread. Pure CI, no product design.
- **How:** vendor/download `pluginval` (a free, cross-platform plugin validator)
  and run `pluginval --validate "Loopy Delay.vst3"` per plugin per OS. Gate on
  strictness level. macOS/Windows binaries exist; Linux builds from source.
- **Size:** small–medium (CI + a script). Self-contained.

### B. CLAP builds of the seven plugins
The CLAP SDK is **already vendored** (`third_party/clap/include`), and the DSP is
shared portable C++ — so a second entry point per plugin yields CLAP `.clap`
artifacts.
- **Why:** CLAP is the modern open plugin format with broad host support; MIT,
  no Steinberg agreement, cleaner threading model. Broadens host reach for free-ish.
- **How:** mirror the `vst3/` project — a `clap/` CMake building each plugin's
  processor against the CLAP entry API + a per-OS `.clap` bundle; reuse
  `loopy_dsp_core`; add golden-parity + load-smoke CTests + CI jobs. The engine
  already scans CLAP (`src/host/scan_clap.cpp`), so there's precedent.
- **Size:** medium–large (a parallel plugin project). High value, self-contained.

### C. Release-artifact packaging pipeline
A CI release job that bundles the built `.vst3` (and `.clap`, if B lands) into
per-OS download artifacts on tag: a macOS zip (ad-hoc signed + a README noting
the quarantine-clear step), a Windows zip, a Linux tarball.
- **Why:** turns "it builds in CI" into "users can install it." Natural capstone.
- **How:** a `workflow_dispatch`/tag-triggered job that `cmake --install`s or zips
  the `Contents/…` bundles + a per-OS INSTALL note. No notarization (dropped).
- **Size:** small–medium. Depends on nothing but the built bundles.

### Also considered (lower fit)
- **Custom plugin editor GUI** — the plugins ship the generic host parameter view.
  A branded editor is a large native-UI effort per format; low ROI vs. A/B/C.
- **Factory presets** — small, but the FX are simple (2–3 params); marginal value.
- **More DAW export targets** (Reaper `.rpp`, etc.) — belongs to the *daw_export*
  package's roadmap, not the plugin series.

## Recommendation
**15 = A (pluginval gate)**, **16 = B (CLAP builds)**, **17 = C (release
packaging)** — an order that compounds: A hardens what exists, B widens format
reach, C ships it. A is a safe immediate start; B is the biggest feature and
would get its own plan; C is the capstone.

**Decision needed:** confirm the pick (or redefine 15–17 entirely). Once chosen,
each becomes a plan → build, same as parts 13–14
(`docs/plan/2026-07-13-feat-vst3-plugins-windows-linux-ports-plan.md`).
