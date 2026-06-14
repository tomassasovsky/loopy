---
title: "fix: process the effect chain in full stereo"
type: fix
date: 2026-06-14
---

## fix: process the effect chain in full stereo — Standard

> No source brainstorm; design settled in discussion. Native-only DSP change to
> the shared FX chain ([packages/loopy_engine/src/engine.c](../../packages/loopy_engine/src/engine.c)),
> used by **both** track lanes and monitor lanes. Builds on the multi-lane
> monitoring work ([docs/plan/2026-06-14-feat-multi-lane-input-monitoring-plan.md](./2026-06-14-feat-multi-lane-input-monitoring-plan.md),
> PR [#29](https://github.com/tomassasovsky/loopy/pull/29)) — it relies on the
> shared `le_fx_entry_reset` and `le_monitor_lane_reset` helpers introduced
> there, so this branch stacks on `feat/multilane-monitoring`.

## Overview

Make the per-lane / per-monitor-lane effect chain **fully stereo**: carry a
left/right pair through every effect instead of treating most effects as mono
and only the reverb as a stereo "spreader" that must sit last. A mono source
seeds `l == r`, so symmetric chains are audibly unchanged; the change only
matters once a chain produces `l != r` (a reverb, or any future stereo source) —
every later effect then colors both channels symmetrically instead of dropping
the right.

## Problem Statement / Motivation

`fx_apply_chain` ([engine.c:602](../../packages/loopy_engine/src/engine.c)) carries a
single value `x` and only sets a right channel `r` (and `stereo = 1`) when
`LE_FX_REVERB` runs. Every other effect is mono — it processes only `x` (the
left). The right channel a reverb produced then **passes through any later
effect unprocessed**. The code documents the limitation:

> "A spreader should be LAST in the chain — any later entry processes only the
> left channel (the right passes through)."

The UI lets the user violate that rule. With **Reverb → Drive** the engine
yields `out1 = drive(revL)` and `out2 = revR` (clean, undriven) — the left's
reverb tail is saturated into distortion while the right passes through
untouched, so the result is lopsided (the user heard the reverb only on the
left). The "spreader must be last" constraint is fragile and unenforced.

Decision (see memory `effects-always-stereo`): **handle all effects as stereo
for consistency and simplicity — no juggling between mono and stereo.**

## Proposed Solution

Carry `(l, r)` through the whole chain. Every effect processes both channels;
stateful effects get a per-channel copy of their DSP state; the reverb feeds its
two banks from `l` and `r` (today both banks get the same mono input). Drop the
`out_stereo` flag and the spreader-last rule — `le_fx_route` always routes the
pair.

### Per-channel DSP state — `le_fx_state` (engine_private.h)

Add a `[2]` channel dimension to every per-slot, per-channel field. The reverb's
`rev_*` state already carries two banks (`LE_REV_BANKS == 2`) and is left as-is.

```c
typedef struct le_fx_state {
  float svf_ic1[LE_FX_MAX][2];          // was [LE_FX_MAX]
  float svf_ic2[LE_FX_MAX][2];
  float lfo[LE_FX_MAX][2];
  float* delay[LE_FX_MAX][2];           // two rings per slot
  int32_t delay_pos[LE_FX_MAX][2];
  float fx_lp[LE_FX_MAX][2];
  float grain_phase[LE_FX_MAX][2];
  int32_t rev_comb_pos[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS]; // unchanged
  float rev_comb_lp[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS];    // unchanged
  int32_t rev_ap_pos[LE_FX_MAX][LE_REV_APS * LE_REV_BANKS];     // unchanged
} le_fx_state;
```

**Ring ownership per slot** (a slot is only ever one type at a time):
- `LE_FX_DELAY` / `LE_FX_ECHO` / `LE_FX_OCTAVER` → use `delay[slot][0]` (left) and
  `delay[slot][1]` (right).
- `LE_FX_REVERB` → packs both its banks into the single ring `delay[slot][0]`
  (as today); `delay[slot][1]` stays `NULL`.

### Per-channel effect functions (engine.c)

Add an `int chan` index to the stateful effects so they select `[slot][chan]`;
the stateless drive needs no change. The reverb takes both inputs and returns
both outputs.

```c
static float fx_drive(float x, const float* p);                  // unchanged (stateless)
static float fx_filter (le_fx_state* fx, int slot, int chan, int sr,          float x, const float* p);
static float fx_delay  (le_fx_state* fx, int slot, int chan, int cap,         float x, const float* p);
static float fx_tremolo(le_fx_state* fx, int slot, int chan, int sr,          float x, const float* p);
static float fx_octaver(le_fx_state* fx, int slot, int chan, int cap,         float x, const float* p);
static float fx_echo   (le_fx_state* fx, int slot, int chan, int sr, int cap, float x, const float* p);
// stereo in / stereo out: left bank fed by xl, right bank by xr
static void  fx_reverb (le_fx_state* fx, int slot, int sr, int cap,
                        float xl, float xr, const float* p,
                        float* out_l, float* out_r);
```

Each stateful body changes only its state indexing, e.g. `fx->svf_ic1[slot]` →
`fx->svf_ic1[slot][chan]`, `fx->delay[slot]` → `fx->delay[slot][chan]`,
`fx->delay_pos[slot]` → `fx->delay_pos[slot][chan]`, etc.

**`fx_reverb`**: compute the bank input per bank (`const float in = (bank == 0 ?
xl : xr) * 0.015f;` inside the bank loop, instead of one shared `in`) and read
the ring through `fx->delay[slot][0]`. **Out-param aliasing:** the call site
passes `&xl, &xr` as the out-params while `xl, xr` are also the inputs, so
compute **both** `wet[0]` and `wet[1]` (the full bank loop) *before* writing
either out-param:
`*out_l = xl * (1 - mix) + wet[0] * mix; *out_r = xr * (1 - mix) + wet[1] * mix;`
— never read `xl`/`xr` after the first store. The **null-guard** (`buf == NULL ||
cap <= 1`) must write both passthroughs: `*out_l = xl; *out_r = xr;` (not the old
single `*out_r = x; return x;`). When `xl == xr` (a mono source with reverb
first) both banks get the same input, exactly as today — that invariant is *why*
`test_fx_reverb_is_stereo` / `test_fx_reverb_builds_a_tail` keep holding.

### Stereo chain — `fx_apply_chain` (engine.c)

Rename/retype to carry the pair in place and drop the `out_stereo` out-param:

```c
static void fx_apply_chain(le_fx_state* fx, int sr, int cap,
                           float* l, float* r, int count,
                           const int32_t* types,
                           const float params[LE_FX_MAX][LE_FX_PARAMS]) {
  float xl = *l, xr = *r;
  for (int s = 0; s < count; ++s) {
    switch (types[s]) {
      case LE_FX_DRIVE:
        xl = fx_drive(xl, params[s]); xr = fx_drive(xr, params[s]); break;
      case LE_FX_FILTER:
        xl = fx_filter(fx, s, 0, sr, xl, params[s]);
        xr = fx_filter(fx, s, 1, sr, xr, params[s]); break;
      case LE_FX_DELAY:
        xl = fx_delay(fx, s, 0, cap, xl, params[s]);
        xr = fx_delay(fx, s, 1, cap, xr, params[s]); break;
      case LE_FX_TREMOLO:
        xl = fx_tremolo(fx, s, 0, sr, xl, params[s]);
        xr = fx_tremolo(fx, s, 1, sr, xr, params[s]); break;
      case LE_FX_OCTAVER:
        xl = fx_octaver(fx, s, 0, cap, xl, params[s]);
        xr = fx_octaver(fx, s, 1, cap, xr, params[s]); break;
      case LE_FX_ECHO:
        xl = fx_echo(fx, s, 0, sr, cap, xl, params[s]);
        xr = fx_echo(fx, s, 1, sr, cap, xr, params[s]); break;
      case LE_FX_REVERB:
        fx_reverb(fx, s, sr, cap, xl, xr, params[s], &xl, &xr); break;
      default: break;
    }
  }
  *l = xl; *r = xr;
}
```

### Always-stereo router — `le_fx_route` (engine.c)

Minimal edit: **delete the `if (!stereo) { ... return; }` early-return block and
the `stereo` parameter** — the existing stereo body already handles every mask
shape and is left untouched. Always route the pair (`l` → first masked output,
`r` → second, `(l+r)/2` for a lone or extra masked channel). For a mono source
`l == r`, so the result equals today's mono routing on every mask shape (single
channel → `(l+r)/2 == l`; two channels → `l, r == l`; more → extras get the mid
`== l`).

```c
static void le_fx_route(float* out, int f, int ch_out, uint32_t mask,
                        float l, float r) { /* the existing stereo body, verbatim */ }
```

### Process-loop call sites (engine.c)

Both the lane-playback pass and the monitor-lane pass change from the
`wet`/`wet_r`/`wet_stereo` triple to an `(l, r)` pair:

```c
// lane playback (and likewise the monitor-lane pass)
float wl = audible ? loopsample * vol[t][l] : 0.0f;
float wr = wl;
if (has_fx[t][l]) {
  fx_apply_chain(&ln->fx, sr, fx_cap, &wl, &wr,
                 fx_count[t][l], fx_type[t][l], fx_params[t][l]);
}
if (audible) le_fx_route(out, f, ch_out, out_mask[t][l], wl, wr);
```

### Allocation / reset (control thread)

The existing model **keeps a slot's ring once allocated and reuses it across
type changes** (`le_fx_prepare_entry` allocates only when `== NULL` and never
frees on a type change; the ring is only released in the reset/destroy paths).
The two-ring version preserves that philosophy *per channel*:

- **`le_fx_prepare_entry`** — allocate **per channel, only the rings this call
  needs and that are still `NULL`**:
  - delay-ringed type (delay/echo/octaver/reverb) → ensure `delay[index][0]`.
  - non-reverb delay-ringed type (delay/echo/octaver) → also ensure
    `delay[index][1]`.
  - reverb → ensure only `[0]`; leave `[1]` as-is (a prior delay-type's `[1]`
    stays **retained, not leaked** — `fx_reverb` ignores it, and the reset path
    frees it. This mirrors the existing "keep the ring for reuse" behavior, so a
    later reorder back to a delay-type reuses it.).
  - Transition correctness: a slot that was reverb (so `[1] == NULL`) and becomes
    a delay-type allocates `[1]` here; a slot that was a delay-type and becomes
    reverb keeps both rings (harmless). A reused `[0]` may hold stale samples from
    a prior type — same as today; `le_fx_entry_reset` zeros `delay_pos` so the
    read head restarts and the algorithm overwrites.
  - **Partial-OOM:** free **only the ring(s) this call newly allocated** (track a
    local `allocated0 = (delay[index][0] was NULL && we allocated it)` /
    `allocated1` and free just those, nulling them), then return
    `LE_ERR_INVALID`. Never free a pre-existing `[0]` that the slot legitimately
    owned from a prior type.
- **`le_fx_entry_reset`** (non-freeing clear, called on the audio thread from the
  `SET_*_FX` ring handlers and on the control thread): its body changes from the
  scalar clears (`fx->svf_ic1[slot] = 0.0f`, …) to clearing **both channels** —
  loop `chan` over `{0, 1}` for `svf_ic1/2`, `lfo`, `delay_pos`, `fx_lp`,
  `grain_phase`; reverb state via `le_fx_clear_reverb` (unchanged). Stays
  allocation-free.
- **`le_lane_reset`** (~engine.c:1521) / **`le_monitor_lane_reset`**
  (~engine.c:1540): free `delay[s][0]` **and** `delay[s][1]`, null both, then
  `le_fx_entry_reset`.
- **`le_engine_destroy`**: free `delay[s][0]` and `delay[s][1]` in **both** loops
  — the per-track lane loop (~engine.c:2095) and the per-monitor-lane loop
  (~engine.c:2102). `le_engine_configure`'s reset path is covered transitively
  via `le_lane_reset`.

### Public surface

No FFI / Dart change — effect types and params are identical. Only the
`loopy_engine_api.h` doc comment that states the spreader-last rule is removed,
and the `fx_apply_chain` header comment is rewritten to describe the stereo
contract.

## Technical Considerations

- **Real-time safety:** unchanged discipline. The control thread still
  pre-allocates the (now two) delay rings in `le_fx_prepare_entry` before
  publishing the type via the ring; the audio callback only reads the rings and
  resets DSP state (`le_fx_entry_reset`) — no allocation, locks, or syscalls.
- **Mono == stereo equivalence:** before any decorrelating effect `l == r`, so
  every existing mono FX test (drive/filter/delay/tremolo/echo/octaver on a mono
  input, routed to any mask) produces identical output. Only reverb-then-effect
  (and future `l != r` sources) change.
- **CPU:** the previously-mono effects (drive/filter/delay/tremolo/octaver/echo)
  now run a second cheap per-channel pass (~2× their cost); the **reverb is
  unchanged** (it already ran two banks). So the chain does not double uniformly
  — only the mono effects do. Acceptable for the clarity/correctness win; the
  user explicitly chose simplicity over skipping the redundant right pass.
- **Memory:** delay/echo/octaver slots now hold two `fx_delay_frames`-sample
  rings (~2× their ring memory), still lazily allocated only for slots that
  actually use a delay-ringed type. Reverb is unchanged (one ring). Worst case
  is bounded by the same `LE_MAX_*` ceilings as today.
- **Shared surface:** one `fx_apply_chain` serves track lanes and monitor lanes,
  so the fix lands on both — including already-shipped track effects.

## Implementation Order

1. `engine_private.h`: add the `[2]` channel dimension to `le_fx_state`.
2. `engine.c`: per-channel effect signatures + bodies (state indexing); stereo
   `fx_reverb`.
3. `engine.c`: stereo `fx_apply_chain` (drop `out_stereo`) and always-stereo
   `le_fx_route` (drop `stereo`); update both process-loop call sites.
4. `engine.c`: per-channel `le_fx_entry_reset` body (loop `chan`); two-ring
   `le_fx_prepare_entry` (per-channel allocate, retained `[1]` across reverb,
   free-only-what-this-call-allocated on OOM); both-channel frees in
   `le_lane_reset` / `le_monitor_lane_reset` / `le_engine_destroy` (both destroy
   loops).
5. `loopy_engine_api.h` + `fx_apply_chain` header comment: drop the
   spreader-last note, document the stereo contract.
6. `test_engine_core.c`: keep the existing FX tests (verify still green); add
   the new stereo-chain tests below.
7. Verify: mingw gcc native test (ALL PASSED) + `flutter build windows --debug
   --target lib/main_development.dart`.

## Acceptance Criteria

- [ ] A mono effect after a reverb (e.g. **Reverb → Drive**) colors **both**
      output channels symmetrically — no lopsided/clean side.
- [ ] A mono input through any symmetric chain is bit-for-bit unchanged from
      today on every mask shape (`l == r`).
- [ ] Reverb still produces a decorrelated stereo tail from a mono input
      (`test_fx_reverb_is_stereo` green, unchanged).
- [ ] No `out_stereo` flag or "spreader must be last" rule remains in the engine
      or its docs.
- [ ] Each delay/echo/octaver slot maintains independent left/right ring state;
      reverb still uses a single ring.
- [ ] Switching one slot's type across a chain reorder (e.g. DELAY → REVERB →
      DELAY within one slot lifetime) neither leaks nor misreads rings — the
      retained `[1]` is reused, never double-allocated or freed mid-flight.
- [ ] All gates green: native test ALL PASSED, `flutter analyze` clean,
      `flutter test` green, `flutter build windows --debug` compiles.

## Testing

All in `packages/loopy_engine/src/test/test_engine_core.c` (mingw gcc):

- **Unchanged (must stay green):** `test_fx_bypass_is_transparent`,
  `test_fx_count_gates_the_chain`, `test_fx_drive_saturates`,
  `test_fx_filter_attenuates_low_cutoff`, `test_fx_delay_is_silent_until_time`,
  `test_fx_reverb_builds_a_tail`, `test_fx_reverb_is_stereo`,
  `test_fx_tremolo_modulates_amplitude`, `test_fx_chain_applies_in_order`,
  `test_fx_nondestructive_and_colors_playback`, `test_fx_muted_track_is_silent`,
  `test_fx_rejects_invalid_args` — these run on mono inputs (`l == r`) so their
  asserted values do not move.
- **New `test_fx_reverb_then_mono_effect_is_stereo`** (regression guard for the
  reported bug): Reverb → Drive (high pre-gain) on a constant mono input routed
  to outs 0+1. Assert **both** channels are saturated — i.e. each output differs
  clearly from its *undriven* reverb value (capture the reverb-only output first
  in a separate run, then assert the drive moved **both** L and R toward the
  saturation level). Do **not** assert `|out0 - out1|` is small: reverb
  legitimately decorrelates L/R, so the channels may differ post-drive; the bug
  condition is specifically "one side driven, the other passed through clean,"
  which the both-sides-saturated check pins directly.
- **New `test_fx_stereo_chain_independent_lr_state`** (proves the `[slot][1]`
  ring is wired and not shared): a `DELAY` slot fed an **impulse on L only** (R
  silent). Assert that at the delay time a tap appears on **L** and **R stays
  silent** at that tap (and symmetrically an R-only impulse taps only R). Channel
  cross-talk would mean a shared/interleaved ring; per-channel rings keep L and R
  fully independent.
- The existing monitor/track lane tests added in PR #29 (e.g.
  `test_monitor_two_lanes_wet_and_clean`, the per-lane mute/volume/route tests)
  use mono effects and stay green.

## Dependencies & Risks

- **Touches shipped track-effect DSP** (shared `fx_apply_chain`). Mitigated by
  the mono==stereo equivalence (existing tests pin the mono behavior) and the
  new reverb-then-effect guard.
- **Partial OOM on the second ring** — handled by freeing the first and failing
  the entry, so a slot never half-initialises (mirrors the existing single-ring
  OOM path).
- **Stacks on `feat/multilane-monitoring`** (PR #29): relies on
  `le_fx_entry_reset` / `le_monitor_lane_reset` from that branch. Land #29 first,
  or target this PR at that branch.
- **Reverb ring offset budget** unchanged — both banks still pack into one ring
  with the same `LE_REV_SPREAD` offset; only the per-bank input feed changes.

## References & Research

- Effect functions + chain + router: [engine.c:322-677](../../packages/loopy_engine/src/engine.c)
  (`fx_drive`/`fx_filter`/`fx_delay`/`fx_tremolo`/`fx_octaver`/`fx_echo`/`fx_reverb`,
  `fx_apply_chain`, `le_fx_route`).
- DSP state struct: `le_fx_state` in
  [engine_private.h:72](../../packages/loopy_engine/src/engine_private.h).
- Alloc / reset: `le_fx_prepare_entry`, `le_fx_entry_reset`, `le_lane_reset`,
  `le_monitor_lane_reset`, `le_engine_destroy` in
  [engine.c](../../packages/loopy_engine/src/engine.c).
- FX tests: [test_engine_core.c](../../packages/loopy_engine/src/test/test_engine_core.c).
- Design principle: memory `effects-always-stereo`.
- Related PR: multi-lane input monitoring [#29](https://github.com/tomassasovsky/loopy/pull/29).
```
