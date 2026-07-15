---
date: 2026-07-08
topic: all-effects-vst3-plus-daw-export
---

# All 7 Loopy Effects as VST3 Plugins + Real-Plugin `.als` Export

## What We're Building

Extends the Loopy FX VST3 pilot (parts 2-4: Delay, Reverb, golden-parity
harness) to all 7 built-in effect types — Drive, Filter, Delay, Tremolo,
Octaver, Echo, Reverb — each shipped as its own real VST3 plugin, following
the now-proven `AudioEffect`+`EditController` wrapper/CMake/golden-parity
pattern. `daw_export`'s `.als` builder then gains the ability to export a
track's actual effects chain as real-plugin device references (by permanent
class GUID), so a project opened in Ableton Live with Loopy installed shows
the exact same effects that were played, as live/editable devices — not
just baked-in audio.

This supersedes the original part 5 plan
(`docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-part-5-plan.md`), which
assumed a stock-Ableton-device approximation system (`_devicesXml`,
`_delayDeviceXml`/`_reverbDeviceXml`) already existed in `als_builder.dart`
to extend. It doesn't — the separate, parallel `performance-recording-daw-export`
plan (which actually built `daw_export`) made an explicit, different design
call: FX chains are rendered as a human-readable text summary
(`fx-chains.txt`) only, never as `.als` device XML ("no `.als` annotation
mirroring"). `DawTrack` currently has no effects/device-chain field at all.

## Why This Approach

**Originally scoped as**: build device-XML export for all 7 effects using
Ableton's own stock devices as approximations (Delay→Delay, Reverb→Reverb,
Echo→Echo, Filter→Auto Filter, Drive→Overdrive, Tremolo→Auto Pan @ 0° phase,
Octaver→Shifter/Pitch mode — all verified against the real Ableton Live 12
device browser during this brainstorm), with the two already-built real VST3
plugins (Delay, Reverb) as an alternate, higher-fidelity path selected by a
`useLoopyPlugins` toggle.

**Reframed to**: since Delay/Reverb already proved the VST3-wrapper pattern
is fast and mechanical to replicate (part 3 was essentially a copy-adapt of
part 2), just build real VST3 plugins for the remaining 5 effects too and
drop the stock-device-approximation path entirely. This is a strictly better
outcome for the primary use case (exact parity vs. musically-similar-at-best
approximations — Octaver's phase-vocoder/PSOLA algorithm in particular has
no honest Ableton equivalent), and it eliminates the largest and riskiest
chunk of the original scope: 7 stock-device corpus captures plus per-effect
param-range translation guesswork (e.g. Drive's "Level" output-trim param
has no analog on Ableton's Overdrive, which only exposes Dry/Wet).

The fallback for recipients without Loopy installed (D-FALLBACK) simplifies
to **today's existing behavior**: the wet-bounced audio, no device chain —
already musically correct (the effect is baked into the audio) and requires
zero new code, since that's exactly what `als_builder.dart` already does
before any of this work lands.

**Alternative considered and rejected**: keep the stock-device-approximation
system as originally scoped, layering real-plugin export as a preferred
default on top. Rejected because it triples the corpus/research surface (9
device shapes instead of 7) for marginal benefit — the approximations would
rarely be used in practice (most Loopy users exporting to Ableton will have
Loopy installed) and several are genuinely lossy in ways that could mislead
a user into thinking they got an accurate device (Octaver especially).

## Key Decisions

- **All 7 built-in effects get real VST3 plugins**, not just Delay/Reverb —
  supersedes the umbrella's original D-SCOPE pilot boundary ("remaining 5
  effects are an explicit named follow-up"); this work *is* that follow-up.
- **No stock-device approximation system.** The only export paths are (a)
  real Loopy VST3 plugin device references, when the exporting/importing
  workflow has Loopy's plugins available, and (b) today's existing
  wet-bounce-only export, unchanged, as the sole fallback.
- **One VST3 plugin per part**, matching parts 2/3's established
  granularity (5 new parts: Drive, Filter, Tremolo, Octaver, Echo), each
  reusing the proven wrapper/CMake/golden-parity-harness pattern rather than
  inventing a new one.
- **Per-lane effects vs. per-track Ableton device chain**: a Loopy channel
  can have multiple lanes with independently different effects chains, but
  Ableton has exactly one device chain per track. Resolution: only export a
  device chain when every lane on a channel shares the identical effects
  chain; otherwise fall back to the existing wet-bounce/no-devices behavior
  for that whole track. Same "honest degrade" principle applied to two other
  edge cases:
  - A chain containing a third-party hosted plugin (not one of Loopy's own
    effects) — out of scope per D-SCOPE, so the whole track falls back
    rather than emitting a chain silently missing a step.
  - Any effect entry we can't confidently represent (extension point for
    future effect types beyond the 7 built-ins, if any are ever added)
    triggers the same fallback.
- **Wet vs. dry arrangement clip**: when a device chain is exported, the
  arrangement clip switches from the wet bounce (`stems/wet/`) to the dry
  stem — otherwise Ableton would apply the effects twice (once baked into
  the wet audio, once again via the live device chain). This makes the live
  device chain the single source of truth for the sound, matching what a
  DAW user expects from "real, editable effects," at the cost of losing the
  exact pre-rendered wet audio for the arrangement view specifically (the
  golden-parity harness already proves the live device reproduces the same
  DSP, so this is not expected to be an audible regression).
- **GUID/param corpus methodology unchanged**: reuse the existing "save from
  Live 12, diff the XML" process (`test/corpus/README.md`) for the 7
  real-plugin device captures. Since all 7 are Loopy's own plugins sharing
  the same wrapper shape, the first capture likely reveals most of the
  `<VstPluginInfo>`-equivalent XML shape needed for the rest.

## Open Questions

- Exact `.als` XML element names/structure for a real hosted VST3 device
  (`<PluginDevice>`? something else?) — genuinely unknown until the first
  real corpus capture; not guessable from documentation alone (same caveat
  `als_builder.dart`'s own doc comment already carries for its un-corpus-verified
  schema).
- Whether `DawManifestReader` should read a lane's effects chain from
  `armSnapshot` only (matching `fx_chains.dart`'s existing precedent — chain
  changes during a performance are logged to `events.log`, not
  re-snapshotted at disarm) or needs its own reconciliation — needs
  confirming against the manifest format doc during planning, not assumed
  here.
- Whether FX-parameter automation (a user riding a Delay's Feedback knob
  mid-performance) is in scope for this work or a further follow-up — the
  existing `events.log`/automation-thinning infrastructure (volume/mute)
  could in principle extend to FX params, but nothing in this brainstorm
  scoped that explicitly; default assumption is chain-state-at-arm-time
  only, same as `fx-chains.txt` today, deferred to a future part if wanted.
- Order of the 5 new plugin parts (by kernel complexity, alphabetical, or
  something else) — pick during planning, not architecturally significant.
- Whether this becomes a new umbrella plan (given it materially changes and
  extends `2026-07-08-feat-loopy-fx-vst3-plugins-plan.md`'s own D-SCOPE and
  Part Sequence) or an amendment to the existing one — a planning-phase
  decision, not resolved here.
