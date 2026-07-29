---
date: 2026-07-28
topic: fx-system-v3
---

# FX System v3 — four-stage chains, auto-cache, pedal FX mode, expression

> Supersedes the discarded Sheeran-parity experiment (#351 / PR #352, closed
> unmerged 2026-07-28). That design is explicitly **not** the baseline here; the
> user asked for an original model. References studied: Boss RC-600, HeadRush
> Looperboard, Sheeran Looper X manuals.

## What We're Building

A ground-up redesign of how FX attach, run, persist, and are performed:

1. **Four first-class FX stages** — **Input** (live signal, feeds recording),
   **Loop** (each loop slot's own chain — today's engine-native lane chain),
   **Track** (one chain over everything a track plays — new engine insert),
   **Master** (whole-mix glue — new engine insert). All four get real UI.
2. **Nothing is ever baked.** Capture stays dry (source of truth). Recording a
   loop *inherits* the active input chain onto the loop, visibly (today's
   snapshot mechanic, made first-class). Every effect everywhere is editable
   and toggleable at any time, including on already-recorded material.
3. **Automatic wet cache ("invisible freeze") at the Loop stage.** A loop's
   dry PCM + chain is a recipe; a background render produces the wet result
   once, and playback serves the cache at zero FX CPU. Any edit invalidates
   the cache → playback instantly falls back to live processing while a fresh
   render happens behind the scenes. When in doubt (miss, memory cap, plugin
   entry, render pending) the engine **always plays live** — the fallback is
   always correct, just costlier. Typical CPU ≈ baked hardware; worst case =
   today.
4. **Universal bypass.** Per-slot `enabled` flag (built-ins and plugins
   uniformly) + per-chain enable, native, atomic, click-free (short gain
   ramp). This is the keystone for pedal toggling: flipping it is
   allocation-free and lock-free. Today the only "off" is deleting the effect.
5. **Pedal FX mode (3rd interaction mode).** MODE cycles REC → MUTE → FX.
   Contextual default with zero setup: track buttons toggle each track's
   Track-chain on/off, LEDs mirror state. Optional per-session **remap**: any
   button → any {stage, chain-or-single-effect}, **toggle or momentary**.
   Requires pedal protocol v3 (mode is 1 wire bit today) in both firmware
   trees + codec.
6. **Expression pedals: USB MIDI first, hardware jack later.** Revive the
   dormant `controller_repository` mapping layer with a continuous-CC branch +
   MIDI-learn UI; map CC → any continuous target (FX param at any address,
   track volume/pan, master gain) with LO/HI range scaling. Hardware
   follow-up phase: **stereo TRS jack** on the Pro Micro board — supports an
   expression pedal (wiper on tip) *or* dual-footswitch accessories (Boss
   FS-6: tip + ring switches), jack type selectable; pin budget (A2 + one
   more) verified in that phase.

## Why This Approach

- **Why not bake (RC-600 Input FX / Sheeran Pre)?** Hardware prints because
  its DSP budget forces it — a resource decision, not a UX ideal. Baking makes
  the headline live feature (stomping FX on recorded loops) impossible on
  recorded material and complicates undo. The discarded #352 build implemented
  true Pre-bake; discarded.
- **Why not plain always-dry (status quo)?** CPU scales with playing lanes ×
  chains forever; the user asked for a model that beats today's CPU while
  staying editable. The auto-cache gives baked-level CPU in the steady state
  with zero new user-facing concepts.
- **Why a real Track insert?** Today "track FX" is a fiction — chains are
  duplicated per lane by snapshot. A genuine track-stage chain is cheaper
  (≤ 8 chains instead of ≤ 64), and is the natural pedal-stomp target.
- **Why contextual-plus-remap for the pedal?** Ease-of-use goal: FX mode must
  do something useful with zero configuration; complex setups get the
  assignment screen (progressive disclosure). References: RC-600 pedal modes
  (assignable sets), Sheeran Toggle/Hold per-pedal binding.

## Key Decisions

- **Capture: dry + inheritance + auto-cache** — reversible everything;
  cached playback locks one steady-state pass (render-twice-keep-second for
  tails), which is the same determinism the baked model has. Lanes containing
  plugin entries stay live for now (offline renderer passes plugins through
  dry); a later capture-based cache (record the live wet output of one clean
  pass) can lift that.
- **Stages: all four first-class** (user call; references stop at
  input + track). Cache applies to the Loop stage only; Input/Track/Master
  always live (Track is the performance surface; Master is one chain).
- **Bypass: per-slot + per-chain enabled flags in the native structs**, read
  in the existing per-buffer snapshot, with a few-ms ramp to avoid clicks.
  Momentary = same flag driven by press/release. DSP state reset on re-enable
  already exists (`le_fx_entry_reset`).
- **Pedal: 3rd `InteractionMode` (fx)** added to the existing three
  mode-switch sites in `ControlCubit` (`recPlay`, `stop`, `trackPressed`) —
  consistent with the "ONE control-surface interpreter" principle. Wire:
  protocol v3 widens the mode field; both firmware trees + `pedal_codec` +
  contract tests bump together. Console shares this stack 1:1 (no GPIO path).
- **Expression: target-agnostic continuous mapping layer** (works for any CC
  source now, the TRS jack later). LO/HI range per binding; linear curve
  first.
- **UX: evolve the shipped design system, no new visual language.** Keep the
  Signal page + FX dock pattern (`SignalFxRack`, `SignalKnob`, `signalMono`/
  `signalLabel`, `surface` tokens; calm/native, color = state only). Add: an
  FX overview surface organized by the four stages, per-card + per-chain
  enable toggles, stomp/LED state chips, pedal-assignment screen (reuse the
  on-screen pedal faceplate), expression-assignment screen with LO/HI range
  rows. Delete confirmed-dead FX code (`fx_inspector`, `fx_chain_strip`,
  `fx_param_control`, `effect_params_editor`, dead `routing_graph` effect
  widgets) as part of the epic.
- **Reliability contracts:** cache never a source of truth (dry PCM + chain
  is); "when in doubt play live"; bypass flip is atomic and click-free; pedal
  FX actions ride the existing debounced press path (dominant latency is the
  known ~8 ms firmware debounce, separately tracked).
- **Fix the `PerformanceRepository.arm()` gap in passing** — arm() is never
  given real chains today, so exported wet stems ≡ dry and device chains are
  empty; the new stage model's session mapping wires it (near-drop-in per the
  code audit).

## Open Questions

- **Persistence split:** pedal FX-mode bindings per session (Sheeran-style)
  with global defaults; expression mappings global or per session? Lean:
  both in session + a global default set. Decide in plan.
- **Cache swap policy:** crossfade to cache at the loop boundary vs immediate
  ramped swap. Lean: loop boundary (inaudible by construction). Decide in
  plan with the render pipeline design.
- **Track-stage inheritance interplay:** when a track chain and an inherited
  loop chain both exist, order is Loop → Track (loop = its own sound, track =
  performance layer). Any UI affordance to "promote" a loop chain to the
  track? Nice-to-have, plan decides.
- **Pin budget for the stereo jack** (A2 + one more digital pin for ring) and
  jack-type selection UX (firmware setting vs app setting) — verify in the
  hardware phase; the pinmap is user-verified, do not assume.
- **Master-chain export semantics** for performance capture / DAW export
  (master FX in the chain manifest vs rendered into the master stem).
