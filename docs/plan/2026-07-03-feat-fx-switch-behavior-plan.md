# feat: FX switch behavior — bypass, single/multi, toggle/momentary

- Type: enhancement (engine + FFI + persisted model + UI)
- Status: planned (future — split out of the FX-screen redesign)
- Branch: TBD (own branch)
- Date: 2026-07-03

## Dependencies

Depends on the FX editor screen shipping first
([2026-07-03-feat-fx-screen-redesign-part-2-plan.md](2026-07-03-feat-fx-screen-redesign-part-2-plan.md)) —
the inspector is where these controls surface.

## Why this is its own plan

This was PR 4 of the FX-screen redesign. It was cut out because — unlike the
presentational parts 1–3 — **it crosses the data/domain layer and the FFI/engine
boundary**. `encode/decodeTrackEffects` delegate to the native C engine
(`track_effect.dart:323`), so every persisted chain field (a bypass `enabled`
flag, `engage`, `bankMode`) requires a **C-engine change + FFI binding + `ffigen`
regen** (run `dart format` after regen, per the ffigen drift gotcha) plus a
persistence migration. It needs an engine/persistence review lens, not a
widget/golden one, so it ships and bakes independently.

Scenes / snapshot recall remain out of scope (a separate future plan).

## Scope

Three behaviors from the Boss/Helix research (see the FX-redesign overview:
[2026-07-03-feat-fx-screen-redesign-plan.md](2026-07-03-feat-fx-screen-redesign-plan.md)):

- **Bypass** — a uniform per-block `enabled` flag (the deferred "keep-the-effect,
  disable-it" toggle; covers built-in + plugin). `TrackEffectType.none` stays the
  distinct "empty built-in slot" concept.
- **Single vs multi** — per-chain `bankMode`: `single` (radio — one block on at a
  time) vs `multi` (independent on/off).
- **Toggle vs momentary** — per-block `engage`: `toggle` (latch) vs `momentary`
  (on-while-held).

## Split: 4a (engine/model) then 4b (UI + pedal)

### 4a — model + persistence + migration (engine/FFI)

- [ ] `packages/looper_repository` + native engine + FFI:
  - [ ] Add per-block `enabled` (default `true`), per-block `engage`
        (`toggle`/`momentary`), per-chain `bankMode` (`single`/`multi`).
  - [ ] Extend the engine struct + FFI binding for `encode/decodeTrackEffects`;
        regen `ffigen`; `dart format` after.
  - [ ] Migration: default `enabled=true` / `toggle` / `multi` for existing
        persisted chains.
- [ ] Tests: encode/decode round-trip + migration (existing data loads unchanged).
- [ ] Apply `enabled`/`bankMode` in the engine's playback path (bypassed blocks
      pass through; single-mode enforces one active block).

Acceptance (4a): existing persisted chains load unchanged; bypass/single-mode take
audible effect through the engine; `ffigen` output formatted.

### 4b — inspector UI + pedal wiring

- [ ] Editor inspector exposes the `enabled` (bypass) dot, `engage`, and
      `bankMode` toggles; single-mode enforces radio behavior in the chain strip;
      bypassed blocks render dimmed in place.
- [ ] **Touch momentary gesture (define explicitly):** long-press-and-hold a chip
      → engaged while the finger is down, released on lift, **cancelled if the
      finger slides off**; distinct pressed-visual from a latched toggle.
      Alternative: scope momentary to **pedals only** in v1 — decide at 4b start.
- [ ] Pedal wiring: pedals emit raw press/release with tap/hold derived by timing
      (`pedal_codec.dart:186`) but have no existing FX momentary binding. Wire
      momentary/hold into the footswitch handling (`pedal_repository`),
      coordinating with the existing pedal FX toggle path.
- [ ] l10n for any new labels (en + es).
- [ ] Tests: editor single-vs-multi / toggle-vs-momentary; bloc/state test for the
      pedal→FX momentary seam (engage-on-hold / release-on-lift; single-mode radio
      enforcement through the bloc).

Acceptance (4b): momentary engages only while held; single mode enforces
one-active-at-a-time; bypass toggles audibly and shows dimmed.

## Open question

- Touch momentary vs pedals-only for v1 (see 4b).
