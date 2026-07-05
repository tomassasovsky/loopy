# feat: retire the instrument-panel aesthetic (FX redesign, part 1)

- Type: enhancement (UI, presentational)
- Status: planned
- Branch: `feat/fx-screen-redesign`
- Date: 2026-07-03

## Dependencies

None. PR 1 is standalone and can merge first.

## Context (shared)

Part 1 of the FX-screen redesign. Full rationale, research synthesis, and
current-state map are in the overview:
[2026-07-03-feat-fx-screen-redesign-plan.md](2026-07-03-feat-fx-screen-redesign-plan.md).

Aesthetic thesis: retire the "instrument-panel" look — mono "machine voice",
letter-spaced uppercase labels, neon glow, colored card rails, `LIVE`/`OFF` gate
pills — for a calm, native look: mono only for genuine numerics, **color = state
only**, tokens only (`SurfaceTheme`/`LooperTheme`). No new screens, no structural
change; this PR is purely presentational.

The three "screams AI" tells, mapped to code:
- **fingernail** → the 3px colored left rail on `_RowCard`
  (`signal_row_views.dart:453`), only on output cards.
- **eyebrow** → letter-spacing via `signalMono`'s `tracking`
  (`signal_style.dart:49`).
- **live indicator** → `SignalGatePill` `LIVE`/`OFF` (`signal_style.dart:80`).
- Connective tissue: `signalGlow()` (`signal_style.dart:65`) + `_RowCard`'s
  selected `boxShadow` (blur 26, `signal_row_views.dart:423`); IBM Plex Mono on
  every label.

## Tasks

- [ ] `lib/looper/view/signal_graph/signal_style.dart`
  - [ ] Remove `signalGlow()`; strip neon halos from focused rings, gate dots,
        selected chips.
  - [ ] Replace `SignalGatePill` (`LIVE`/`OFF`) with a minimal lit-vs-dim state
        (filled dot when open, dimmed row/opacity when closed) — no capsule, no
        caption. **Preserve the semantic state for assistive tech**: the pill
        currently carries a `LIVE`/`OFF` label for a11y (`signal_style.dart:80`);
        the replacement must still expose on/off via `Semantics`, not by
        color/opacity alone.
  - [ ] `signalMono` → keep one mono style for **numerics only** (dB, `%`,
        counts); drop the `tracking` parameter. Labels move to the app's sans
        text styles.
  - [ ] Replace hardcoded neon consts (`kSignalSnapshotBg/Line/Ink`,
        `kSignalInset`, `kSignalMenu`, `kSignalLine2`) with `SurfaceTheme` tokens
        (`card`, `cardHigh`, `line`, `accent`, `ledBlue`, …). **Sweep all
        consumers** — `signalMenuShape()` uses `kSignalLine2`, and dropdown call
        sites in `signal_dock.dart` reference these; leave no dangling helper.
  - [ ] Rewrite the file's aesthetic-declaring doc comment.
- [ ] `lib/looper/view/signal_graph/signal_row_views.dart`
  - [ ] Remove `_RowCard.rail` param + the `Stack`/`ClipRRect` rail paint
        (`:442-463`). Collapse the `railColor == null ? 13 : 14` padding to a
        constant. Output enabled/routed state reads via text + opacity.
  - [ ] Drop the selected `boxShadow` glow (`:423-431`); selection = accent
        border only.
- [ ] Color de-rainbowing: stop using `outputColor()`/`lanePalette` for per-output
      identity (blue/gold/green/purple dots). Neutral resting state; a single
      `accent` only for the actively traced path. (Keep `lanePalette` in the
      theme; just stop wearing four hues at rest.) Output identity comes from the
      `Out 1`/`Out 2` label.
- [ ] `lib/looper/view/signal_graph/signal_list_view.dart` — remove the two
      instruction bars ("Tap any row to trace its signal…" / "Tap an input to
      dial its tone…").

## Tests

- [ ] Update `test/looper/view/signal_graph/signal_fx_rack_test.dart` and
      `signal_dock_test.dart` for removed pill/rail semantics; assert the gate
      state is still exposed semantically (no a11y regression).
- [ ] Regenerate `test/screenshots/goldens/signal_surface.png` and any dock/rack
      goldens; review the diff.

## Acceptance criteria (checkable)

- Grep: no `signalGlow`, no `SignalGatePill`, no `_RowCard.rail`, no
  `letterSpacing`/`tracking` on labels under `lib/looper/view/signal_graph/`.
- Grep: no hardcoded `Color(0x…)` in `signal_style.dart`; the `kSignal*` consts
  are gone with no dangling `signalMenuShape()`/`signal_dock.dart` references.
- Grep: `outputColor(`/`lanePalette` no longer color output rows at rest.
- The two instruction bars are removed from `signal_list_view.dart`.
- Gate on/off state remains exposed to assistive tech.
- `flutter analyze` clean; widget tests + goldens pass.
