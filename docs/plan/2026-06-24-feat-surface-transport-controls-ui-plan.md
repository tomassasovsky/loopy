---
title: Surface keyboard/pedal-only transport controls in the UI
type: feat
date: 2026-06-24
---

## Surface keyboard/pedal-only transport controls in the UI - Standard

## Overview

Add on-screen controls in the Big Picture performance view
([`lib/looper/view/big_picture_view.dart`](../../lib/looper/view/big_picture_view.dart))
for the five transport actions that today can only be invoked by keyboard
shortcut or MIDI pedal. The change is presentation-only — every button reuses an
existing `LooperBloc` event or window helper that the keyboard handler (`_onKey`)
already dispatches. No engine, repository, or bloc-event changes.

The five gap actions (confirmed by cross-referencing `_onKey` in
`big_picture_view.dart` against `PedalCubit` and the existing widget tree):

| Action | Existing trigger | Dispatch | New UI placement |
|--------|------------------|----------|------------------|
| Play All / Stop All | `Space`, pedal Rec/Play | `LooperPlayAllPressed` / `LooperStopAllPressed` | Top bar — single state-aware toggle |
| Clear All | `C`, pedal Clear | `LooperClearAllPressed` | Top bar |
| Fullscreen | `F` | `toggleLoopyFullScreen()` | Top bar (desktop only) |
| Undo (per track) | `U` / `Cmd/Ctrl+Z`, pedal Undo tap | `LooperUndoPressed(channel)` | Selected track column header |
| Redo (per track) | `Cmd/Ctrl+Y` / `Cmd/Ctrl+Shift+Z`, pedal Undo long-press | `LooperRedoPressed(channel)` | Selected track column header |

## Problem Statement / Motivation

Loopy is keyboard- and pedal-first, but a user driving the app with mouse/touch
(or learning it) has no way to undo, redo, clear all, play/stop all, or toggle
fullscreen — those actions are invisible. Surfacing them makes the app fully
operable by pointer and improves discoverability of the shortcuts (via tooltips),
without changing the performance workflow for existing keyboard/pedal users.

## Proposed Solution

### Refactor first: extract shared dispatch+announce helpers (prevents drift)

`_onKey` currently dispatches the event **and** announces the result via
`SemanticsService` (e.g. `_announce(l10n.a11yPlayingAll)`). To keep the new
buttons in lockstep with the keyboard, extract small helpers on
`_BigPictureViewState` that both paths call:

- `_togglePlayAll(BuildContext, {required bool playing})` → dispatch
  `LooperStopAllPressed`/`LooperPlayAllPressed` + announce
  `a11yStoppedAll`/`a11yPlayingAll`.
- `_clearAll(BuildContext)` → dispatch `LooperClearAllPressed` + announce
  `a11yAllCleared`.
- `_undo(BuildContext, int channel)` / `_redo(...)` → dispatch + announce
  `a11yUndone`/`a11yRedone`.
- Extract the "any track active" predicate (currently inline at
  `big_picture_view.dart:200-209`) into a helper, e.g.
  `bool _anyActive(LooperState)`, used by both the `Space` handler and the
  toggle button's icon/label.

Rewire `_onKey` to call these helpers so there is a single source of truth.

### Global transport cluster (top bar)

Insert into the existing top-bar `Row` (`big_picture_view.dart:68-86`), between
the `Spacer` and the `bigpicture_openSignal` `IconButton`, three controls
matching the existing icon-button style (`iconSize: 20`,
`VisualDensity.compact`, `color: Colors.white70`, stable `Key`s, localized
tooltips with shortcut hints):

```dart
// Play/Stop All — state-aware toggle
IconButton(
  key: const Key('bigpicture_playStopAll'),
  tooltip: anyActive ? l10n.stopAllTooltip : l10n.playAllTooltip, // "(Space)"
  icon: Icon(anyActive ? Icons.stop : Icons.play_arrow),
  onPressed: state.status.isConnected && state.hasContent
      ? () => _togglePlayAll(context, playing: anyActive)
      : null, // disabled when disconnected or nothing recorded
),
// Clear All — instant (matches C key); disabled when nothing to clear
IconButton(
  key: const Key('bigpicture_clearAll'),
  tooltip: l10n.clearAllTooltip, // "Clear all (C)"
  icon: const Icon(Icons.delete_sweep_outlined),
  onPressed: state.status.isConnected && state.hasContent
      ? () => _clearAll(context)
      : null,
),
// Fullscreen — desktop only, static icon
if (loopySupportsDesktopWindowing)
  IconButton(
    key: const Key('bigpicture_fullscreen'),
    tooltip: l10n.fullscreenTooltip, // "Fullscreen (F)"
    icon: const Icon(Icons.fullscreen),
    onPressed: () => unawaited(toggleLoopyFullScreen()),
  ),
```

`anyActive` and `state` come from the `LooperBloc` state already available in the
build scope.

### Per-track Undo / Redo (selected column header)

In `_TrackColumn` (`big_picture_view.dart:552-664`), the header `Row`
(`big_picture_view.dart:601-618`) currently holds the track number, a `Spacer`,
and an optional multiple-loop label. When `selected` is true, add a compact
Undo/Redo pair after the `Spacer`:

```dart
if (selected) ...[
  IconButton(
    key: Key('bigpicture_undo_${track.channel}'),
    tooltip: undoTooltip, // platform-branched modifier, see Technical Considerations
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    icon: const Icon(Icons.undo),
    onPressed: track.hasContent ? () => onUndo(track.channel) : null,
  ),
  IconButton(
    key: Key('bigpicture_redo_${track.channel}'),
    tooltip: redoTooltip,
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    icon: const Icon(Icons.redo),
    onPressed: track.canRedo ? () => onRedo(track.channel) : null,
  ),
],
```

`_TrackColumn` is a `StatelessWidget` with no access to `_BigPictureViewState`'s
helpers, so pass `onUndo`/`onRedo` callbacks (e.g.
`void Function(int channel)`) down via its constructor, wired at the call site
(`big_picture_view.dart:106-115`) to `_undo`/`_redo`. This keeps the
dispatch+announce logic in one place. Do **not** add pixel params to the public
API beyond these callbacks (VGV: no pixel params in widget APIs).

### Enable/disable contract (decided)

- **Undo button enabled on `track.hasContent`** (not `canUndo`). The keyboard
  `U` path is tolerant: on a track with only its base loop, `canUndo` is false
  yet the bloc still clears it (`looper_bloc.dart` undo handler). Binding the
  button to `canUndo` would silently drop the "clear lone loop" affordance, so
  mirror the keyboard with `hasContent`.
- **Redo button enabled on `track.canRedo`.**
- **Play/Stop All and Clear All disabled when `!state.hasContent` or
  `!state.status.isConnected`** — avoids dead-feeling controls when the project
  is empty or the engine is stopped (the `_AudioNotRunningBanner` already
  signals the stopped state).
- **Clear All stays instant** (no confirm dialog) per the brainstorm decision —
  consistent with the `C` key and pedal; Undo is the safety net. The
  `!hasContent` disable removes the only true no-op case.

## Technical Considerations

- **Architecture:** Presentation-layer only, in the `loopy` app package. Reuses
  existing `LooperBloc` events; no new events, no repository/engine changes, no
  new package. Matches VGV layered architecture.
- **No keyboard/button drift:** the extracted helpers are the single source of
  truth for dispatch + screen-reader announcement. Buttons announce the same
  `a11y*` strings the keyboard already does (they already exist in the ARBs:
  `a11yPlayingAll`, `a11yStoppedAll`, `a11yAllCleared`, `a11yUndone`,
  `a11yRedone`) — no new announcement strings needed.
- **Fullscreen icon is static this PR.** `toggleLoopyFullScreen()`
  (`lib/window/window_chrome.dart:40`) is fire-and-forget with only an async
  `isFullScreen()` getter and no state stream; the OS can exit fullscreen
  (green button / Esc / F11) without the app knowing. Reflecting live
  enter/exit state would require a `windowManager` listener
  (`onWindowEnterFullScreen`/`onWindowLeaveFullScreen`) + notifier — deferred as
  out of scope (YAGNI). Button is gated on `loopySupportsDesktopWindowing` so it
  does not render on web.
- **Tooltip localization + platform modifier.** New ARB strings go in **both**
  `lib/l10n/arb/app_en.arb` and `lib/l10n/arb/app_es.arb` (with `@`-metadata).
  Undo/Redo tooltips must not hardcode "Cmd" — the app targets Windows/Linux
  too. Branch on `defaultTargetPlatform` (macOS → `⌘Z`/`⌘⇧Z`, else
  `Ctrl+Z`/`Ctrl+Y`) or use neutral phrasing. New keys (suggested):
  `playAllTooltip` "Play all (Space)", `stopAllTooltip` "Stop all (Space)",
  `clearAllTooltip` "Clear all (C)", `fullscreenTooltip` "Fullscreen (F)",
  `undoTooltip` / `redoTooltip` (or `a11y`-style labels with the platform
  modifier interpolated).
- **Focus / Tab order.** `_onKey` deliberately lets `Tab`/`Shift+Tab` fall
  through so focus can traverse interactive elements
  (`big_picture_view.dart:191-194`). New top-bar `IconButton`s join that
  traversal naturally; verify they don't disrupt the documented flow into
  tiles/mode/bank. The header Undo/Redo appear/disappear with selection — confirm
  this does not cause a focus jump (they are not focused by default; selection is
  driven by tap/number keys).
- **Selected-channel invariant.** Undo/Redo render only inside the selected
  column, so the "no track selected" case is structurally avoided. Confirm
  `BigPictureCubit` always has a valid `selectedChannel` within the visible bank
  (the keyboard path reads it unconditionally, implying it is always valid).
- **Theming/a11y:** use `LooperTheme` tokens for any color; `IconButton`
  tooltips provide the accessible label and are keyboard-operable out of the box
  (same pattern as `_SessionMenu` / `bigpicture_openSignal`). Keep tap targets at
  the existing compact icon-button size used in the top bar.

## Acceptance Criteria

- [ ] Top bar shows a **Play/Stop All** toggle whose icon/tooltip reflects
      whether any track is playing/overdubbing/recording; tapping it dispatches
      `LooperPlayAllPressed`/`LooperStopAllPressed` and announces
      `a11yPlayingAll`/`a11yStoppedAll`.
- [ ] Top bar shows a **Clear All** button that fires `LooperClearAllPressed`
      instantly (no dialog) and announces `a11yAllCleared`.
- [ ] Both Play/Stop All and Clear All are **disabled** when `!state.hasContent`
      or `!state.status.isConnected`.
- [ ] Top bar shows a **Fullscreen** button on desktop only
      (`loopySupportsDesktopWindowing`) that calls `toggleLoopyFullScreen()`.
- [ ] The **selected** track column header shows **Undo** and **Redo** buttons;
      Undo enabled when `track.hasContent`, Redo enabled when `track.canRedo`;
      they dispatch `LooperUndoPressed`/`LooperRedoPressed` for that channel and
      announce `a11yUndone`/`a11yRedone`. Non-selected columns show neither.
- [ ] All new buttons have stable `Key`s (`bigpicture_playStopAll`,
      `bigpicture_clearAll`, `bigpicture_fullscreen`, `bigpicture_undo_<ch>`,
      `bigpicture_redo_<ch>`) and localized tooltips containing the shortcut hint.
- [ ] `_onKey` is refactored to call the same shared helpers as the buttons; the
      keyboard behavior (dispatch + announce) is unchanged.
- [ ] New ARB strings added to **both** `app_en.arb` and `app_es.arb` with
      `@`-metadata; Undo/Redo tooltip modifier adapts to platform (no hardcoded
      "Cmd").
- [ ] **Tests** (`test/looper/view/big_picture_view_test.dart`): each new button
      renders; tapping dispatches the expected `LooperBloc` event (mock bloc,
      `verify`); Undo/Redo appear only on the selected column; disabled states
      hold when empty/disconnected; Play/Stop icon flips with play state.
- [ ] `flutter analyze` clean; `dart format` applied; existing big_picture tests
      still pass.

## Success Metrics

- Every action previously reachable only by keyboard/pedal is now reachable by
  pointer in the Big Picture view.
- No regression in keyboard/pedal behavior (verified by existing + refactored
  tests).
- Screen-reader users hear the same announcements whether they use a key or a
  button.

## Dependencies & Risks

- **No external dependencies.** Uses existing events, helpers, and ARB
  infrastructure.
- **Risk — accidental Clear All by pointer.** A visible always-tappable wipe is
  easier to mis-hit than the `C` key. Mitigated by disabling when there is
  nothing to clear and by relying on per-track Undo. Re-evaluate a confirm/Undo
  SnackBar if it proves a problem in use (deferred, not in scope).
- **Risk — fullscreen icon staleness** if live-state reflection were attempted;
  avoided by shipping a static icon this PR.
- **Risk — focus/Tab order regression** from new top-bar buttons; covered by the
  focus-traversal check in acceptance criteria.
- **Note — CI runs no Dart unit-test job** (per project memory); run
  `flutter test` locally before opening the PR.

## References & Research

- Brainstorm: [docs/brainstorm/2026-06-24-surface-transport-controls-ui-brainstorm-doc.md](2026-06-24-surface-transport-controls-ui-brainstorm-doc.md)
- Keyboard handler / dispatch+announce source: `lib/looper/view/big_picture_view.dart:188-335`
- Top-bar Row insertion point: `lib/looper/view/big_picture_view.dart:68-86`
- `_TrackColumn` header insertion point: `lib/looper/view/big_picture_view.dart:601-618`
- Events: `lib/looper/bloc/looper_event.dart:59` (Undo), `:65` (Redo), `:352` (PlayAll), `:358` (StopAll), `:364` (ClearAll)
- State flags: `packages/looper_repository/lib/src/models/looper_state.dart:40` (`hasContent`); `packages/looper_repository/lib/src/models/track.dart:79` (`hasContent`), `:86` (`canUndo`), `:89` (`canRedo`)
- Fullscreen helper + desktop guard: `lib/window/window_chrome.dart:33` (`loopySupportsDesktopWindowing`), `:40` (`toggleLoopyFullScreen`)
- Existing announce strings: `lib/l10n/arb/app_en.arb:73-79`
- Tooltip-with-shortcut precedent: `lib/l10n/arb/app_en.arb:287` (`"signalTooltip": "Signal flow (G)"`)
- Existing widget tests: `test/looper/view/big_picture_view_test.dart`
