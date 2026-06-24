---
title: Per-track status indicators in the Big Picture view (pedal-independent)
type: feat
date: 2026-06-24
---

## Per-track status indicators in the Big Picture view - Standard

## Overview

Add a thin, per-track on-screen **status indicator** to each track tile in the
Big Picture performance view ([`lib/looper/view/big_picture_view.dart`](../../lib/looper/view/big_picture_view.dart)):
a discrete "traffic-light" strip showing the track's **arm/readiness** state —
**idle** (dim), **play** (green: playing or armed-to-play), **record** (red:
recording/overdubbing or armed-to-record). Visibility is a persisted user
preference (Settings → View), **default on**.

This preserves the *concept* of the dropped `_TrackLedBar` (from the stale
`refactor/repository-layer-boundaries` branch) but its name, state enum, colour
token, and driving logic are **fully decoupled from the hardware loop-pedal
LEDs** — no `PedalTrackLed` / `PedalCubit` imports. The indicator state is a pure
function of data `_TrackColumn` already receives.

Brainstorm: [docs/brainstorm/2026-06-24-track-status-indicators-brainstorm-doc.md](../brainstorm/2026-06-24-track-status-indicators-brainstorm-doc.md)

## Problem Statement / Motivation

The per-track level meter (`_PeakBar`) conveys signal level (fill height tracks
momentary peak) and a transport-state colour — but a playing-but-quiet track
reads as nearly empty, and the meter cannot show a track that is **selected/armed
but not yet active**. A constant, discrete status strip gives an at-a-glance read
of each track's readiness that doesn't flicker with the audio, and surfaces the
"armed" state the meter can't. Making it pedal-independent means it's correct
whether or not the hardware pedal is connected.

## Proposed Solution

Build in dependency order: **Data → Domain/State → Theme → Presentation →
Settings UI → l10n**. Each layer is small; together they form one coherent PR.

### 1. Data — `SettingsRepository` (package `settings_repository`)

Add a persisted bool mirroring the `showWaveformWindow` accessor pattern
([`settings_repository.dart:305`](../../packages/settings_repository/lib/src/settings_repository.dart)):

```dart
static const String _showTrackIndicatorsKey = 'big_picture.track_indicators';

/// Whether per-track status indicators show on the Big Picture tiles.
/// Defaults to `true` when unset.
Future<bool> loadShowTrackIndicators() async =>
    await _store.getBool(_showTrackIndicatorsKey) ?? true;

Future<void> saveShowTrackIndicators({required bool value}) =>
    _store.setBool(_showTrackIndicatorsKey, value: value);
```

### 2. State — `TrackIndicatorsCubit` (`Cubit<bool>`)

New `lib/looper/cubit/track_indicators_cubit.dart`, modelled on
[`high_contrast_cubit.dart`](../../lib/looper/cubit/high_contrast_cubit.dart) —
**but seeded `super(true)`**, not `super(false)`:

```dart
class TrackIndicatorsCubit extends Cubit<bool> {
  // Seed `true` so a default-on feature does not flash absent -> present on
  // launch before `load()` restores the saved value. (HighContrastCubit seeds
  // `false` because its default is off, so the asymmetry is intentional.)
  TrackIndicatorsCubit({required SettingsRepository settings})
    : _settings = settings,
      super(true);

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _restore();
  Future<void> _restore() async {
    final on = await _settings.loadShowTrackIndicators();
    if (!isClosed) emit(on);
  }

  Future<void> setEnabled({required bool value}) async {
    if (value != state) emit(value);
    await _settings.saveShowTrackIndicators(value: value);
  }

  Future<void> toggle() => setEnabled(value: !state);
}
```

Export it from the looper barrel ([`lib/looper/looper.dart`](../../lib/looper/looper.dart),
add `export 'cubit/track_indicators_cubit.dart';`). Provide it app-wide in
[`lib/app/view/app.dart`](../../lib/app/view/app.dart) next to `HighContrastCubit`
(~line 113), eager `load()`:

```dart
BlocProvider(
  create: (context) {
    final cubit = TrackIndicatorsCubit(
      settings: context.read<SettingsRepository>(),
    );
    unawaited(cubit.load());
    return cubit;
  },
),
```

### 3. Theme — `TrackIndicator` enum + `LooperTheme.indicatorColor` token

In [`lib/theme/looper_theme.dart`](../../lib/theme/looper_theme.dart), alongside
`LooperMeterState`, add the **pedal-independent** enum and its pure mapping. This
is the single source of the indicator's state logic:

```dart
/// The discrete arm/readiness appearance of a track's status indicator —
/// independent of the meter palette and of the hardware pedal LEDs.
enum TrackIndicator {
  /// Inactive / not armed. Dim.
  idle,

  /// Playing, or armed to play (selected in play mode). Green.
  play,

  /// Recording/overdubbing, or armed to record (selected in record mode). Red.
  record;

  /// Indicator state for a track. Transport state wins over the
  /// selected/armed derivation; `muted` reads as [idle] (matching the meter's
  /// muted-first precedence on the same tile).
  factory TrackIndicator.of(
    TrackState state, {
    required bool muted,
    required bool selected,
    required bool playMode,
  }) {
    if (muted) return TrackIndicator.idle;
    return switch (state) {
      TrackState.recording || TrackState.overdubbing => TrackIndicator.record,
      TrackState.playing => TrackIndicator.play,
      TrackState.empty || TrackState.stopped =>
        selected
            ? (playMode ? TrackIndicator.play : TrackIndicator.record)
            : TrackIndicator.idle,
    };
  }
}
```

Add the token to `LooperTheme` (a new field + lookup + `copyWith` + `lerp`):

```dart
final Map<TrackIndicator, Color> indicatorColors;

Color indicatorColor(TrackIndicator indicator) =>
    indicatorColors[indicator] ?? Colors.transparent;
```

- `copyWith`: add `Map<TrackIndicator, Color>? indicatorColors` param.
- `lerp`: lerp `indicatorColors` too. Generalize the existing private
  `_lerpMeters` into a generic `_lerpColorMap<K>(a, b, t)` and use it for both
  meter maps and the indicator map (avoids a near-duplicate helper).

### 4. Theme instances — [`lib/theme/app_theme.dart`](../../lib/theme/app_theme.dart)

Provide `indicatorColors` for **every** `LooperTheme` instance — the normal
big-picture theme **and** the high-contrast variant (mirroring the
`_hcRecordMeterColors` / `_hcPlayMeterColors` precedent). Reuse the meter
green/red hues; pick a dim `idle` distinguishable from `tileBackground`:

```dart
// normal
indicatorColors: const {
  TrackIndicator.idle: Color(0xFF3A3F49),   // dim, above tileBackground
  TrackIndicator.play: Color(0xFF4CDA4A),   // meter green
  TrackIndicator.record: Color(0xFFFF1744), // meter red
},
// high-contrast (idle reuses the brighter HC "empty" tone so it stays visible)
indicatorColors: const {
  TrackIndicator.idle: Color(0xFF6B6D78),
  TrackIndicator.play: <hc green>,
  TrackIndicator.record: <hc red>,
},
```

### 5. Presentation — `_TrackIndicator` strip in `_TrackColumn`

A static, full-width rounded strip below the track name. **`ExcludeSemantics`**
— the tile (`bigpicture_tile_<ch>`) already exposes its state via
`a11yTrackTile(name, stateWord)` plus a `selected` semantic, so a second label
here would make screen readers announce two conflicting state words per tile. The
indicator is a visual aid; WCAG 1.4.1 is already met by the tile's text. No
animation (state is a static colour — nothing to reduce-motion).

```dart
class _TrackIndicator extends StatelessWidget {
  const _TrackIndicator({required this.status, super.key});
  final TrackIndicator status;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: looper.indicatorColor(status),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const SizedBox(height: 5, width: double.infinity),
      ),
    );
  }
}
```

Render it at the end of the `_TrackColumn` column, gated on the cubit. When the
pref is **off the widget is absent** (the tile reflows; `bigpicture_indicator_<ch>`
is not in the tree):

```dart
if (context.watch<TrackIndicatorsCubit>().state) ...[
  const SizedBox(height: 6),
  _TrackIndicator(
    key: Key('bigpicture_indicator_${track.channel}'),
    status: TrackIndicator.of(
      track.state,
      muted: track.muted,
      selected: selected,   // already a _TrackColumn field
      playMode: playMode,   // already a _TrackColumn field
    ),
  ),
],
```

### 6. Settings UI — [`big_picture_settings_page.dart`](../../lib/looper/view/big_picture_settings_page.dart)

Add a `SetupToggleRow` in `_viewSection` right after the high-contrast switch
(~line 141):

```dart
final showIndicators = context.watch<TrackIndicatorsCubit>().state;
// ...
SetupToggleRow(
  toggleKey: const Key('bpSettings_trackIndicators_switch'),
  title: l10n.trackIndicatorsTitle,
  subtitle: l10n.trackIndicatorsSubtitle,
  value: showIndicators,
  onChanged: (on) =>
      unawaited(context.read<TrackIndicatorsCubit>().setEnabled(value: on)),
),
```

### 7. l10n — both ARBs

Add only the toggle strings (no a11y state strings needed, given
`ExcludeSemantics`) to **both** [`app_en.arb`](../../lib/l10n/arb/app_en.arb) and
[`app_es.arb`](../../lib/l10n/arb/app_es.arb) with `@`-metadata, then `flutter
gen-l10n`:

- `trackIndicatorsTitle` — en "Track indicators" / es "Indicadores de pista"
- `trackIndicatorsSubtitle` — en "Show a status light on each track"
  / es "Mostrar una luz de estado en cada pista"

## Technical Considerations

- **Pedal-independent by construction.** `TrackIndicator.of` takes only
  `TrackState` + `muted` + `selected` + `playMode`; nothing imports
  `PedalTrackLed`/`PedalCubit`. The hardware pedal LEDs are untouched.
- **Mapping precedence (locked):** `muted` → `idle` first (consistent with the
  meter's muted-first rule on the same tile); then live transport
  (recording/overdubbing → record, playing → play) **wins over** the armed
  derivation; only `empty`/`stopped` consult `selected` + `playMode`. An empty
  **selected** track therefore arms (green/red) with no content — intended (you
  are about to record into it). `stopped` and `empty` both collapse to `idle`
  when unselected — the indicator deliberately does not distinguish them (the
  meter does).
- **Selected-channel is global (0–7); tiles are banked (4 shown).** `selected`
  is computed per tile as `track.channel == big.selectedChannel`, so only the
  truly-selected tile arms; if the selected channel is in the hidden bank, no
  visible tile arms. Covered by a bank-switch test.
- **No launch flicker.** `TrackIndicatorsCubit` seeds `super(true)` so the
  default-on indicators are present from first paint; `load()` only changes
  state if the user previously turned them off.
- **Live update.** The cubit is provided above `BigPictureView`; `_TrackColumn`
  `watch`es it, so toggling in Settings reflects on return without restart and
  without disturbing recording/playback.
- **Accessibility.** Indicator is `ExcludeSemantics` (no double-announcement);
  the screen-reader experience is identical whether the visual pref is on or
  off. Static colour ⇒ no motion to gate.
- **Theme plumbing checklist (silent-bug risk).** Adding `indicatorColors` means
  touching `LooperTheme` constructor, `copyWith`, `lerp`, **and** every const
  instance in `app_theme.dart` (normal + high-contrast). Missing one drops the
  token on theme transitions — verified by a `lerp`/`copyWith` test.
- **Architecture/VGV.** Presentation + a tiny `Cubit<bool>` + one repository bool,
  all mirroring existing precedents (`HighContrastCubit`, `meterColor`,
  `SetupToggleRow`). No pixel params in widget public APIs. `LooperTheme` tokens
  for all colour.

## Acceptance Criteria

- [ ] Each **visible** track tile shows a `bigpicture_indicator_<channel>` strip
      when the pref is on; the colour reflects `TrackIndicator.of(...)`.
- [ ] **Mapping truth table** holds (unit-tested over
      `{TrackState × muted × selected × playMode}`): muted → idle;
      recording/overdubbing → record; playing → play; transport beats armed;
      empty/stopped + selected → record (rec mode) / play (play mode);
      empty/stopped + unselected → idle.
- [ ] Only the tile where `channel == selectedChannel` arms; after a bank switch
      the newly-selected visible tile arms and previously-armed (now hidden) one
      is gone; selecting an off-bank channel arms no visible tile.
- [ ] Settings → View shows a **Track indicators** toggle
      (`bpSettings_trackIndicators_switch`), **default on**, persisted; toggling
      it live-updates the performance view (indicators appear/disappear) without
      restart and without affecting transport.
- [ ] When the pref is **off**, `bigpicture_indicator_<channel>` is **absent**
      from the tree (not merely transparent).
- [ ] No launch flicker: with the pref unset/true, indicators are present on the
      first frame (cubit seeded `true`).
- [ ] Indicator carries **no** semantics of its own (`ExcludeSemantics`); the
      tile’s existing accessible label/selected state is unchanged; SR experience
      is identical with the pref on or off.
- [ ] `LooperTheme.indicatorColor` returns a colour for all three states in the
      **normal and high-contrast** palettes; `idle` is distinguishable from
      `tileBackground` in both; `copyWith`/`lerp` carry `indicatorColors`.
- [ ] New ARB strings (`trackIndicatorsTitle`, `trackIndicatorsSubtitle`) in
      **both** `app_en.arb` and `app_es.arb` with `@`-metadata.
- [ ] `flutter analyze` clean; `dart format` applied; full `flutter test` green.

## Tests

- **`packages/settings_repository/test/settings_repository_test.dart`** — default
  `loadShowTrackIndicators()` is `true` when unset; save/load round-trip.
- **`test/looper/cubit/track_indicators_cubit_test.dart`** (new, `bloc_test`) —
  initial state is `true` (seeded); `load()` restores a persisted `false`;
  `setEnabled`/`toggle` emit and persist.
- **`test/theme/looper_theme_test.dart`** (new or extend) — `TrackIndicator.of`
  truth table; `indicatorColor` lookup; `copyWith`/`lerp` cover `indicatorColors`.
- **`test/looper/view/big_picture_view_test.dart`** (extend) — add
  `TrackIndicatorsCubit` to the `pump` providers; indicator renders per visible
  tile when on and is absent when off; colour matches status for representative
  states (read the `DecoratedBox` colour); armed only on the selected tile;
  bank-switch reassignment; `ExcludeSemantics` (no extra state node on the
  indicator).
- **`test/looper/view/big_picture_settings_page_test.dart`** (extend if present,
  else add) — the toggle row renders, reflects cubit state, and flips it.

## Dependencies & Risks

- **No external dependencies.** Reuses existing `SettingsRepository`,
  `SetupToggleRow`, `LooperTheme`, and the `HighContrastCubit` cubit pattern.
- **Risk — default-on launch flicker:** mitigated by seeding the cubit `true`
  (AC + test).
- **Risk — screen-reader double-announcement:** mitigated by `ExcludeSemantics`
  (AC + test); the tile already names state for SR.
- **Risk — dropped token on theme transition** if `copyWith`/`lerp`/an instance
  is missed: mitigated by the theme test.
- **Risk — visual redundancy with the meter colour** for active tracks: accepted;
  the indicator’s distinct value is the constant discrete state and the
  armed-but-idle case. (Open: whether "armed" should light only the selected
  tile — current design — vs. not at all; settle in review if it feels noisy.)
- **Note — CI runs no Dart unit-test job** (project memory); run `flutter test`
  locally before opening the PR. Use the absolute Flutter path
  (`/Users/Tomas/development/flutter/bin/flutter`).

## References

- Old `_TrackLedBar` (origin/refactor/repository-layer-boundaries):
  `lib/looper/view/big_picture_view.dart` — pedal-coupled original being reframed.
- Cubit precedent: [`high_contrast_cubit.dart`](../../lib/looper/cubit/high_contrast_cubit.dart)
- Repo bool precedent: [`settings_repository.dart:305`](../../packages/settings_repository/lib/src/settings_repository.dart) (`showWaveformWindow`)
- Theme token precedent: [`looper_theme.dart:83-93`](../../lib/theme/looper_theme.dart) (`meterColor`)
- Settings toggle precedent: [`big_picture_settings_page.dart:125-141`](../../lib/looper/view/big_picture_settings_page.dart) (`_viewSection`)
- App provider wiring: [`app.dart:113`](../../lib/app/view/app.dart) (`HighContrastCubit`)
- `TrackState` enum: `packages/loopy_engine/lib/src/engine_snapshot.dart:42`
