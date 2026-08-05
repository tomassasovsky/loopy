---
title: "chore(design): reconcile the segno-ui.pen design system with the shipped theme"
type: chore
date: 2026-08-05
issue: 499
---

## chore(design): reconcile segno-ui.pen with SurfaceTheme/LooperTheme

> Issue: [#499](https://github.com/tomassasovsky/segno/issues/499)
> Direction: **decided 2026-08-05 — option (a), prototype wins wholesale;
> the waveform goes state-coloured.** Every conflict row below resolves to
> the DS value, type included (Inter + JetBrains Mono migrate in; the
> Helvetica/Arial legend face is common to both sides and stays). The
> per-row recommendations are preserved as the record of the analysis —
> the human overrode the type recommendation, taking (a) over (c).
> Autonomy: was `plan-gate` on that call; with it made, the build is
> `merge-gate` — verifiable here, but it reskins every screen and swaps the
> app's type system, so the result earns a human merge.
> Related: #495 (Figma design-system track, a separate export target).

## What exists on each side

**The design system** (`segno-ui.pen`, above the imported screens at
`y=-4122`): 4 root frames — `DS / masters` (`XJoip`, 22 components),
`DS / 01 Foundations` (`AGXjB`), `DS / 02 Components` (`im3R8`),
`DS / 03 Patterns` (`TrIGV`) — plus ~70 Pencil variables (unprefixed). The 96
imported 1920×1080 screens (`y >= 24`) are the prototype, not the shipped app.
The `.pen` also carries a family of `--*`-prefixed shadcn-style variables
(Light/Dark themed, orange `--primary #FF8400`) left over from the prototype
import; they are **not** part of the DS and are cruft to delete in Stage 0.

**The shipped theme**: `SurfaceTheme`
([surface_theme.dart](../../lib/theme/surface_theme.dart), ~30 tokens, `dark` +
`highContrast` constants), `LooperTheme` + `AppTheme`
([looper_theme.dart](../../lib/theme/looper_theme.dart),
[app_theme.dart](../../lib/theme/app_theme.dart)), and the
`RoutingGraphTheme` contract exported across the package boundary by
`routingGraphThemeFromSurface` ([app_theme.dart:13](../../lib/theme/app_theme.dart)).

**Blast radius, measured:** 19 files under `lib/` and `packages/*/lib` name
`SurfaceTheme`/`LooperTheme` directly, and ~30 more consume tokens through the
`context.surface` getter; 13 golden PNGs under `test/screenshots/goldens/`
(driven by `tracks_screenshots_test.dart`, `settings_screenshots_test.dart`,
`control_center_preview_test.dart`) are invalidated by any neutral or type
change; `test/theme/app_theme_test.dart` (119 lines) and
`looper_theme_test.dart` (346 lines) assert theme structure and invariants;
`routing_graph` is a separate package fed via `routingGraphThemeFromSurface`.

## The decision

The prototype is a **reskin**: identical information architecture and state
semantics, different neutrals and a different type system.

- **(a) prototype wins** — migrate `SurfaceTheme`/`LooperTheme` to the DS
  values wholesale.
- **(b) code wins** — correct the `.pen` to shipped values; DS becomes
  documentation of what ships.
- **(c) reconcile per token** — split by domain.

**Recommendation: (c), split cleanly by domain:**

1. **Colour: prototype wins.** The DS neutral ramp is the freshly designed
   direction, the deltas from shipped are 2–5 RGB points (imperceptible in
   isolation, coherent as a system), and every DS text token meets or beats
   the shipped contrast ratios (numbers below). The DS also brings a richer
   ramp (6 background steps, 4 border steps, `text-muted`, accent/rec
   surfaces) that the code has needed — adopting its values makes the DS
   authoritative instead of a stale mirror.
2. **Type: code wins.** Space Grotesk / Helvetica-legend / IBM Plex Mono is a
   deliberate, documented brand system ("instrument-panel character",
   [surface_theme.dart:119](../../lib/theme/surface_theme.dart)); the legend
   face is hardware-coupled (pedal silkscreen); Space Grotesk and IBM Plex
   Mono are already bundled in `assets/fonts/`. The DS's Inter + JetBrains
   Mono is the prototyping-stack default, not a decision. Correct
   `font-ui`/`font-mono` in the `.pen`.
3. **Hardware-coupled and engine-coupled tokens: code wins by definition**
   (LED palette, legend face, lane palette, wet/dry route) — these are
   *backfilled into the DS*, not reconciled.

One row is genuinely open taste and is called out for an explicit human veto
either way: the **waveform colour** (shipped single cyan `00E5FF` vs the
prototype's state-coloured stage).

## Per-token reconciliation table

Contrast ratios computed per WCAG 2.x relative luminance; "vs card" means
against the same side's card/raised surface.

### Already agreeing — no decision

| Domain | DS token = value | Shipped token = value |
|---|---|---|
| accent | `accent` `#3b82f6` | `SurfaceTheme.accent` `0xFF3B82F6` |
| on-accent | `text-on-accent` `#ffffff` | `onAccent` `0xFFFFFFFF` |
| record (stage) | `signal-rec` `#ff1744` | meter/indicator record `0xFFFF1744` |
| play (stage) | `signal` `#4cda4a` | meter/indicator play `0xFF4CDA4A` |
| stopped (stage) | `signal-stopped` `#ffffff` | meter stopped `0xFFFFFFFF` |
| stage background | `bg-stage` `#000000` | `LooperTheme.tileBackground` `Colors.black` |
| text primary | `text-primary` `#f3f4f7` | `textPrimary` `0xFFF3F4F7` |
| record mode chip | `signal-rec` `#ff1744` | `LooperTheme.recordColor` `0xFFFF1744` — the mode indicator sits on the **stage-red** side of the `rec`/`signal-rec` split, not the UI-chrome side |
| FX mode chip | `accent` `#3b82f6` | `LooperTheme.fxColor` `0xFF3B82F6` |

### Conflicts — recommendation per row

| Token | DS (prototype) | Shipped | Recommend | Why |
|---|---|---|---|---|
| background | `bg-base` `#0b0b0c` | `background` `#08080A` | **DS** | neutral vs blue-tint; delta imperceptible, DS is the designed system |
| surface | `bg-surface` `#141417` | `surface` `#0D0D11` | **DS** | as above; DS lifts surface off base slightly more |
| card | `bg-raised` `#161618` | `card` `#16161B` | **DS** | 3-point blue-channel delta |
| cardHigh | `bg-elevated` `#1e1e21` | `cardHigh` `#1C1C22` | **DS** | as above |
| line | `border-default` `#2a2a2e` | `line` `#272730` | **DS** | decorative hairline both sides (1.26:1 vs 1.22:1 — neither is a 3:1 boundary; HC variant carries that duty) |
| textSecondary | `text-secondary` `#9a9aa2` | `#989AA4` | **DS** | 6.47:1 vs 6.43:1 on card — equal AA headroom |
| textTertiary | `text-tertiary` `#8a8a92` | `#82848E` | **DS** | 5.28:1 vs 4.84:1 — DS *improves* the token that was once lifted for WCAG ([surface_theme.dart:253](../../lib/theme/surface_theme.dart)) |
| warning | `warning` `#e0a94a` | `#F0C97A` | **DS** | 8.56:1 on card — far above the 4.5:1 floor; the HC variant keeps a brightened value (rule below) |
| tile border | `border-track` `#17171b` | `LooperTheme.tileBorder` `#22222E` | **DS** | part of the stage colour family |
| REC pill / UI red | `rec` `#e5484d` (+ `rec-surface` `#e5484d24`) | reuses `#FF1744` | **DS** | DS is finer-grained: stage red (`signal-rec`) ≠ UI chrome red (`rec`); adopt both, map REC pill/banner to `rec` |
| waveform | state-coloured (white/`#4cda4a`/`#ff1744`, alpha-dimmed) | `waveformColor` `#00E5FF` single cyan (+ HC `#4DEEFF`) | **DS, flagged** | the most visible change in the app; prototype is systematic (waveform = state legend), cyan is the "neon" brand quirk — **explicit veto point**. Cost asymmetry: the DS side is a `LooperTheme` **API change** (single `waveformColor` token → per-state colouring through the visualizer, plus an HC counterpart per state), not a hex swap |
| font (UI) | `font-ui` Inter | `Space Grotesk` (bundled) | **code** | documented brand face; DS `.pen` gets corrected |
| font (mono) | `font-mono` JetBrains Mono | `IBM Plex Mono` (bundled, 3 weights) | **code** | as above |
| font (legend) | `font-legend` Arial | `Helvetica` + `[Arial, sans-serif]` fallback | **agree** (already carried forward) | pedal silkscreen legend face ([surface_theme.dart:123](../../lib/theme/surface_theme.dart)); Arial is the documented Pencil-side stand-in — **do not re-normalise to the UI face** |

### DS-only tokens — adopt into `SurfaceTheme` (no conflict, pure additions)

`bg-control` `#26262a`, `bg-control-strong` `#3a3a40`, `bg-scrim` `#08080a6b`,
`border-hairline` `#ffffff0b`, `border-subtle` `#ffffff1f`, `border-strong`
`#3a3a40`, `text-muted` `#6b6b73` (**3.42:1 on raised — large-text /
non-essential use only, never body copy; document that on the token**),
`accent-surface` `#16233d`, `accent-alt` `#738cf2`, `success` `#30a46c`,
`rec` / `rec-surface` / `rec-tint` `#e5484d21` / `rec-line` `#e5484d66` /
`rec-deep` `#2a1214`, plus the number scales (type scale 12–26, radii 2–17 +
pill, spacing 2–25, `row-h` 70, `control-h` 42, `nav-w` 180). Number scales
are adopted as-needed, not as a bulk constant dump: when a widget needs one,
it lands as a field on `SurfaceTheme` itself (the `disabledOpacity`
precedent — same extension, no parallel metrics extension, no pixel params in
widget APIs), and the `.pen` stays the documentation of the full scale.

### Code-only domains — backfill into the DS (values from code, verbatim)

These are domains the DS omits and must document, in both variants:

- **Pedal LED palette**: `ledGreen/ledRed/ledAmber/ledBlue` — hardware
  semantics (`PedalTrackLed`/`GlobalColor`), not restylable. `ledOff`
  (`#23232B`, an unlit dot — same hex as `knobFaceTop`) and `ringGlow`
  (`#3A3A44`, the idle encoder rim) are **panel neutrals wearing LED names**;
  they join the re-tint set below, not the frozen hardware set.
- **Toolbar/misc LooperTheme tokens**: `toolbarIconColor` (`white70` /
  `#D6D8E0` HC), `waveformBackground` (`#06060A` / `#000000` HC) — the DS has
  no counterparts; document both, and `waveformBackground` re-tints with the
  neutrals.
- **Routing roles**: `wetRoute` `#3B82F6`, `dryRoute` `#F59E0B`.
- **Lane palette**: the 8-colour categorical series (blue/amber/teal/violet/
  pink/green/orange/sky) + its HC counterpart.
- **Instrument-panel fills**: `chromeGradientTop/Bottom`, `chromeBar`,
  `meterTrack`, `pageGlow`, `knobFaceTop/Bottom` — re-derived onto the DS
  neutral hue if (a)/(c)-colour is chosen (they are blue-tinted today for
  coherence with the shipped ramp).
- Honesty note: `wetRoute`, `dryRoute`, `lanePalette`, and `meterTrack`
  currently have **zero consumers** outside the theme definition (the graph
  widgets that used them have no live screen; semantic colours cross into
  `routing_graph` as constructor params by design). They stay in the contract
  and get documented, but the DS should mark them *reserved*.
- **Opacities**: `disabledOpacity` 0.4 / 0.62(HC), `traceDimOpacity`
  0.28 / 0.5(HC) — including the multiplication contract documented on
  [surface_theme.dart:112](../../lib/theme/surface_theme.dart).
- **Waveform**: whichever way the veto row lands, the DS documents it.

## Known DS gaps to close (no direction call needed)

1. **High-contrast variant.** The app ships a full HC palette
   (`SurfaceTheme.highContrast`, HC meter/indicator tables in
   `app_theme.dart`), a persisted `HighContrastCubit`, and WCAG 1.4.11
   comments. The DS gets an `HC` theme axis on its variables (Pencil themed
   values), re-derived per the rule below.
2. **Interaction states.** DS documents rest + selected only. The code's
   actual vocabulary, which the DS States section documents as-is:
   - **focus-visible**: `FocusableTapTarget`'s 2px ring
     (`packages/routing_graph/.../focusable_tap_target.dart`), default
     `textPrimary`, overridden to `accent` on signal rows
     ([signal_row_views.dart:453](../../lib/looper/view/signal_graph/signal_row_views.dart));
     the knob recolours its outer ring when focused.
   - **selected**: the accent-alpha recipe — fills at alpha 0.10–0.22 with
     borders at 0.45–0.5 (signal rows, tray rail, tray tiles, FX rack).
   - **disabled**: `disabledOpacity` / `traceDimOpacity` (multiplying, by
     contract).
   - **hover / pressed**: *do not exist* — no hover colours anywhere;
     InkWells ride stock Material ink (nothing set in `AppTheme._themed`).
     The DS proposes them (hover = `border-hairline`/`border-subtle`-class
     white-alpha lift on the hovered surface; pressed = one step deeper),
     wired in Stage 2 by two mechanisms, one per consumer class:
     `ThemeData.hoverColor`/`highlightColor` set once as the app-wide default
     the ~15 stock InkWells inherit, and `WidgetStateProperty.resolveWith`
     mappings on the custom state widgets (`FocusableTapTarget` call sites,
     tray tiles, FX rack) where the tiered per-surface lift applies. This is
     the one place the DS *leads* the code rather than documenting it.
3. **i18n headroom.** DS-side: `ParamSlider`'s label is fixed at 106px and
   its value column at 74px; `NavItem` is fixed 159px. Rebuild those masters
   with min-width + `fit_content` growth and document the longest-`es`
   strings. Scale of the problem (634 strings each in `app_en.arb` /
   `app_es.arb`): by raw character count 136 Spanish strings exceed 1.4×
   English — short strings skew extreme ("On" → "Encendido" is 4.5×) — and
   among strings ≥20 chars ~19 exceed 1.4× with the worst ≈1.9×
   (`refreshRateIntro` 98→146). Code-side the fixed-width risk is real but
   *different* (no literal 106 exists in `lib/`): 54px knob captions already
   truncate Spanish param labels ("Retroalimentación"), the add-device card
   is 104px, the mode switch 88px — all ellipsize rather than break layout.
   That code-side fix is spun off as
   [#500](https://github.com/tomassasovsky/segno/issues/500), not part of
   this reconciliation.
4. **Cruft**: delete the `--*` shadcn variable family from the `.pen` —
   verified unreferenced (a full-document scan finds zero `$--*` bindings on
   any node), so deletion cannot break the imported screens.

## HC re-derivation rule

The HC palette is not regenerated from scratch — it keeps its measured
contrast floors and only re-tints to match the adopted neutral hue:

- For each HC neutral, preserve lightness, drop the blue tint (e.g. `line`
  `#6B6D78` → a neutral grey of equal L*). Verified feasible: neutral
  `#6E6E6E` on black holds 4.12:1 vs the current 4.08:1 — the 3:1 non-text
  floor (1.4.11) survives de-tinting with margin.
- Floors that must hold, asserted in `test/theme/` (relational, not
  hex-literal): HC `line` ≥ 3:1 vs `card`; HC `textSecondary`/`textTertiary`
  ≥ 4.5:1 vs `card`; dark `textSecondary`/`textTertiary` ≥ 4.5:1 vs `card`;
  `warning` ≥ 4.5:1 vs `card` in both variants; HC meter `empty`/indicator
  `idle` ≥ 3:1 vs `tileBackground`.
- HC state colours (`#FF5470`, `#6EE77F`), LED HC palette, and HC opacities
  are untouched — they encode legibility decisions, not the neutral hue.
- `test/theme/app_theme_test.dart` is **already fully relational** (0 hex
  literals): it asserts the 8-token routing-graph anti-drift equality, dark
  `textTertiary` ≥ 4.5:1 vs `card`, HC `line` ≥ 3:1 vs `card`, and
  HC-out-contrasts-dark — so a value migration flows through it with no test
  edits. Stage 1 *adds* the missing floors (warning both variants,
  `textSecondary`, HC meter-`empty`/indicator-`idle` vs `tileBackground`)
  rather than rewriting anything. The only production-hex copy in any test is
  the `routing_graph` fixture
  (`packages/routing_graph/test/helpers/pump_app.dart:6-15` — the *app-level*
  `test/helpers/pump_app.dart` registers `AppTheme.neon` and holds no hexes),
  and it is deliberately decoupled — its `textTertiary` still holds the
  pre-WCAG-lift `0xFF5B5D67` and nothing has ever broken — leave it, or
  refresh it in passing.

## Staged migration sequence (as decided: option (a))

Each stage is its own PR against #499 (or a part-issue if the epic grows),
`stage:*` kept current, goldens regenerated at most once per value-changing
stage.

- **Stage 0 — make the DS authoritative (`.pen` only, no code).** The DS
  fonts stand as designed (`font-ui` Inter / `font-mono` JetBrains Mono —
  under (a) the *code* migrates, not the `.pen`); delete the `--*`
  family; add the HC theme axis; backfill the code-only domains; add
  interaction-state specimens; rebuild `ParamSlider`/`NavItem` for i18n;
  the stage pattern documents the state-coloured waveform (decided). Commit
  `segno-ui.pen` (it is currently untracked).
- **Stage 1 — token layer, colour + type.** `SurfaceTheme.dark`
  neutrals/text/warning take the DS values; new tokens added (control fills,
  border tiers, `text-muted`, accent/rec/success family);
  `LooperTheme.tileBorder` → `#17171b`; the re-tint set moves onto the
  neutral hue: instrument-panel fills (`chromeGradientTop/Bottom`,
  `chromeBar`, `meterTrack`, `pageGlow`, `knobFaceTop/Bottom`), `ledOff`,
  `ringGlow`, `waveformBackground`, the meter `empty` `#2C313A` and
  indicator `idle` `#3A3F49` table entries; **and the hand-copied mirrors in
  `app_theme.dart` that would otherwise silently drift**: `ColorScheme`
  `surface: 0xFF0D0D11` (:94), `scaffoldBackground: 0xFF06060A` (:98), and
  their HC counterparts.
  **Type migration (decided under (a)):** bundle Inter + JetBrains Mono
  (both SIL OFL; `assets/fonts/` holds neither today), declare them in
  `pubspec.yaml`, flip `SurfaceTheme.displayFont` → `'Inter'` and
  `monoFont` → `'JetBrains Mono'` (const names keep their roles);
  `legendFont` and its fallback list are untouched;
  `looper_screen_theme.dart`'s legend override is untouched; the screenshot
  drivers' font-loading blocks switch to the new assets.
  HC re-derived per the rule; the missing relational floors added to
  `test/theme/`; **goldens regenerated once** and eyeballed.
  `routingGraphThemeFromSurface` is untouched (shape-stable).
- **Stage 2 — vertical slice.** One screen adopts the *new* tokens end-to-end
  (settings page: hairline/subtle border tiers, `bg-control` on controls,
  interaction states via `WidgetState` mappings) to prove the extended ramp
  before it spreads.
- **Stage 3 — the rest.** Remaining screens + `signal_graph/`/`fx_editor/`
  consumers; the **state-coloured waveform lands here (decided)** — the
  `LooperTheme` API change from single `waveformColor` to per-state colouring
  with HC counterparts; REC pill moves to `rec`; final golden regen +
  eyeball.

## Golden-regeneration strategy

The screenshot suite self-skips off an absolute path into the author's
Flutter SDK font cache (`hasScreenshotFonts`), so goldens rot silently — the
regen is a deliberate local step on the author machine, not CI. Mechanics:

- 12 of the 13 goldens (9 settings-driver + 3 control-center) render a
  deliberately deterministic `_goldenTheme()` — bare dark
  `ThemeData(fontFamily: 'Roboto')` + `SurfaceTheme.dark` + the routing-graph
  adapter; only `tracks_main_window.png` (the 16" console decal) renders full
  `AppTheme.neon`. But the ambient face is not the whole story:
  `signal_surface` and the 4 `fx_editor_*` goldens pin
  `SurfaceTheme.displayFont`/`monoFont` through `signalLabel()`/`signalMono()`
  ([signal_style.dart](../../lib/looper/view/signal_graph/signal_style.dart)) —
  the settings driver loads Space Grotesk and IBM Plex Mono for exactly this
  reason. So under (c), all 13 diffs are colour-only; under (a), a type
  migration would surface in up to **6** of 13 (tracks decal + those 5), and
  the remaining 7 would under-report it.
- Per value-changing stage, regenerate once and eyeball all 13 against the DS
  frames (that diff *is* the review artifact for the reskin):

```bash
/Users/Tomas/development/flutter/bin/flutter test --tags screenshots --update-goldens
```

```bash
/Users/Tomas/development/flutter/bin/flutter test --tags screenshots --dart-define=SEGNO_CONSOLE=true --update-goldens test/screenshots/tracks_screenshots_test.dart
```

- Layout deltas in a golden diff mean a bug, not a reskin — type is not
  changing under (c).
- Housekeeping while there: `test/screenshots/failures/` holds 44 stale diff
  artifacts (including for a golden that no longer exists).

## routing_graph cross-package story

The package (`packages/routing_graph`, Flutter-SDK-only deps, app → package
one-way) never sees app tokens: `routingGraphThemeFromSurface`
([app_theme.dart:13](../../lib/theme/app_theme.dart)) projects the 8 neutral +
text tokens into `RoutingGraphTheme` (8 required fields, **no defaults, no
presets**), both variants and the golden themes register the result of that
single function, and `app_theme_test.dart` asserts the 1:1 equality — the
mapping cannot drift. A colour migration therefore flows through with **zero
routing_graph change**: the package has **no goldens**, its theme test is
copyWith/lerp mechanics on arbitrary hexes, its widget fixture is
deliberately decoupled, and typography never enters it (text rides the
ambient `ThemeData.fontFamily`).

Two facts to keep in view during Stages 2–3:

- **No live screen uses the graph widgets.** The only routing_graph symbol
  the app consumes today is `FocusableTapTarget` (~12 files: signal rows,
  tray rail, tray tiles, setup surface, wifi), and its focus ring
  bang-reads `context.routingGraph.textPrimary` — so `RoutingGraphTheme`
  **must stay registered** even though no graph is on screen; dropping it
  crashes every focus ring.
- New DS tokens do **not** widen the contract: the package's own stated rule
  is neutrals-in-theme, semantics-as-constructor-params. Nothing in this plan
  adds RoutingGraphTheme fields.

## Verify loop (every stage)

- `/Users/Tomas/development/flutter/bin/flutter test`
- `dart analyze` clean
- `bash packages/segno_engine/src/test/run_native_tests.sh`
- (firmware untouched — the pedal gate does not apply unless LED *values*
  change, which this plan forbids)
- Golden eyeball on the author machine per the strategy above.

## Non-goals

- No LED value changes, no pedal firmware changes, no protocol changes.
- No IA/layout changes — this is a reskin reconciliation; #498 owns the
  console IA reorganisation.
- No light theme. Both sides are dark-only (the DS's `--*` light values are
  prototype cruft).
- No Figma work — #495 is a separate export target and consumes whatever this
  decision produces.
