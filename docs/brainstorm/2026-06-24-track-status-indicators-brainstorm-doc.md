---
date: 2026-06-24
topic: track-status-indicators
---

# Per-track status indicators (decoupled from the pedal LEDs)

## What We're Building

A thin, per-track on-screen **status indicator** in the Big Picture performance
view — a discrete "traffic-light" strip on each track tile that shows the
track's **arm/readiness** state at a glance: **idle** (dim), **play**
(green — playing or armed to play), and **record** (red — recording/overdubbing
or armed to record).

It complements the existing analog level meter (`_PeakBar`) rather than
duplicating it. The meter's **fill height tracks the momentary peak level**, so
a playing-but-quiet track reads as nearly empty and the colour only registers
when there's signal. The indicator is instead a **constant, discrete state**
that doesn't flicker with the audio — and it can show the one thing the meter
cannot at all: a track that is **selected/armed but not yet active**.

This preserves the *concept* of the dropped `_TrackLedBar` (from the stale
`refactor/repository-layer-boundaries` branch) but reframes it as a first-class
UI element. Its **name, state enum, colour token, and driving logic are fully
independent of the loop pedal's hardware LEDs** — it derives purely from looper
transport state plus the selected channel and performance mode, never from
`PedalTrackLed` / `PedalCubit`. Visibility is a persisted user preference
(Settings → View), **on by default**.

## Why This Approach

The original `_TrackLedBar` was literally a screen mirror of the hardware pedal
LED: it read `PedalCubit.trackLedFor(channel)` (`PedalTrackLed{off,green,red}`)
and only appeared when no pedal was bound (`bindStatus != bound`). The user
wants to keep the visual but sever the pedal coupling — the indicator should be
a property of the *app's* track state, correct whether or not a pedal is
attached, with its own vocabulary.

**Chosen: a dedicated presentation indicator with its own theme token.** A new
`TrackIndicator` enum + a pure mapping function, a new pedal-independent
`LooperTheme.indicatorColor(...)` token, a `_TrackIndicator` strip widget, and a
tiny `TrackIndicatorCubit` (`Cubit<bool>`) for visibility — modelled exactly on
the existing `HighContrastCubit` + Settings → View toggle precedent.

Alternatives rejected:
- **Reuse `meterColor`/`LooperMeterState` for the colour** — the six meter
  states can't express "armed-but-idle" (selected, not yet playing/recording),
  which is the whole point of an arm/readiness signal. Reusing them would lose
  the chosen semantics.
- **Rename the pedal mirror only** — keeps `PedalTrackLed`/`PedalCubit` as the
  source, contradicting the decision to decouple the logic.

## Key Decisions

- **What it represents:** arm/readiness as a 3-state traffic light
  (`idle` / `play` / `record`), *not* the 6-state transport/meter palette and
  *not* the pedal LED. Rationale: it surfaces the one piece of state the meter
  can't (armed but inactive) without duplicating the meter.
- **State source (decoupled — and no new dependency):** a pure function of the
  data `_TrackColumn` is *already* passed — `track` (its `state`/`muted`),
  `selected`, and `playMode`. It needs **no pedal types** (`PedalTrackLed` /
  `PedalCubit` / pedal channel maps) **and no new cubit** for the mapping; it is
  indexed by the looper `track.channel` directly. (The `TrackIndicatorCubit`
  below is only for the visibility toggle, not the colour.) Mapping (final
  wording in /plan):
  - `muted` → `idle` (matches the old LED "off on muted")
  - `recording` or `overdubbing` → `record`
  - `playing` → `play`
  - else if `selected` → `record` when `playMode` is false, `play` when true
    (armed)
  - else → `idle`
- **Visibility:** persisted user preference, **default on**. New
  `SettingsRepository` bool (`loadShowTrackIndicators()` defaulting `true` /
  `saveShowTrackIndicators`), surfaced by a new `TrackIndicatorCubit`
  (`Cubit<bool>`, mirrors `HighContrastCubit`: `load`/`setEnabled`/`toggle`),
  provided app-wide in `app.dart`, watched by `_TrackColumn`. Toggle lives in
  the **View** group of `big_picture_settings_page.dart`, beside the
  waveform-window and high-contrast switches
  (`bpSettings_trackIndicators_switch`).
- **Colour:** new `LooperTheme.indicatorColor(TrackIndicator)` token (its own
  map, wired through `copyWith`/`lerp` and the high-contrast palette), *not* a
  reuse of `meterColor` and *not* a `pedalLedColor`. Hues may visually echo the
  meter green/red but are an independent token so they can diverge.
- **Naming:** widget `_TrackIndicator`; enum `TrackIndicator`; per-tile key
  `bigpicture_indicator_<channel>`; settings toggle key
  `bpSettings_trackIndicators_switch`. The word "LED" appears nowhere in the new
  public surface.
- **Placement:** a thin full-width rounded strip below the track name (where the
  old `_TrackLedBar` sat), small fixed height (~4–6px).
- **Accessibility:** colour-only state (WCAG 1.4.1) must be named for screen
  readers — wrap in `Semantics` with a localized label per state
  (e.g. idle / ready-to-play / recording). New ARB strings for the toggle
  title/subtitle and the a11y state names, in both `app_en.arb` and
  `app_es.arb` with `@`-metadata.
- **Scope boundary:** independent PR off `master` (branch
  `feat/track-status-indicators`); does **not** revive the pedal mirror, the
  per-track routing button, or the pedal-arming tile gestures from the old
  branch. The hardware pedal LEDs remain a separate concern, untouched.
- **Scope/size note (for /plan):** small per layer but spans several — the
  `settings_repository` package (new bool + its test), a new
  `TrackIndicatorCubit` (+ test), `app.dart` wiring, the `LooperTheme` token in
  `app_theme.dart` (`copyWith`/`lerp`/high-contrast palette), the
  `_TrackIndicator` widget + its mapping (+ widget tests), the settings-page
  toggle, and l10n in both ARBs. Still a single coherent PR, but each layer
  needs its own test.

## Open Questions

- **Indicator vs. selected-border redundancy:** the selected track already shows
  a white border. Confirm in /plan that the indicator's *armed* colour (per
  mode) adds enough beyond the border to be worth it, or whether "armed" should
  only light for the selected track (current proposal) vs. not at all.
- **Exact indicator hues + high-contrast values:** pick concrete colours for
  `indicatorColor` (and the high-contrast variant) during /plan; decide whether
  `idle` is fully transparent or a dim token (e.g. `tileBorder`).
- **Strip vs. dot:** full-width strip (like the original) vs. a small dot/pill in
  the header row — a visual-polish call to settle in /plan.
