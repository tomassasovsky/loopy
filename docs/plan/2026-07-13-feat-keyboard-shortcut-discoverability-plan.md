# feat: keyboard-shortcut discoverability (Big Picture)

**Status:** Planned · **Date:** 2026-07-13 · **Type:** enhancement (a11y / UX)

The Big Picture performance surface has a rich keyboard map (`lib/looper/view/
tracks_commands.dart` `handleKey`), wired via one top-level `Focus` in
`tracks_view.dart:92`. But **only undo/redo surface their shortcut** (in the
IconButton tooltips) — the other ~15 shortcuts are invisible to a new user and to
a screen reader. This plan adds a discoverable, accessible shortcut legend.

> Scoped out of the a11y follow-up PR (which shipped the `SignalKnob` accessible
> name (#164) + `labeledTapTargetGuideline` nets on both surfaces) because it is a
> design + bilingual-i18n feature that benefits from a quick design call — noted
> below — rather than a blind build.

## Design (proposed — one small decision to confirm)

- **Trigger:** a visible `Icons.keyboard` **help IconButton** in the chrome
  (`tracks_chrome.dart`, next to Settings) — the primary discoverability win, and
  screen-reader-findable — **plus** the `?` key (`Shift`+`/`) in `handleKey`.
- **Surface:** an `AlertDialog` (matches `rename_track_dialog.dart`) titled
  "Keyboard shortcuts", scrollable, dismiss on Esc/tap-outside. *(Alt: a
  `showModalBottomSheet` like `performance_completion_sheet.dart`.)*
- **Rows:** each = a shortcut chip + a description. **Platform-correct modifiers**
  — `⌘` on macOS, `Ctrl` elsewhere (`Theme.of(context).platform` /
  `defaultTargetPlatform`). Group as *Transport* / *Tracks* / *Navigation*.
- **a11y:** each row a single merged `Semantics(label: "<keys>: <description>")`
  so a screen reader reads "R, record or overdub the selected track", not two
  loose nodes. The dialog is a `Semantics(namesRoute)` route.

## Shortcut inventory (from `handleKey`)

| Keys | Description | l10n |
|------|-------------|------|
| `Space` | Play / stop all | new `shortcutPlayStopAll` |
| `C` | Clear all | reuse `clearAllTooltip` |
| `M` | Switch record / play mode | new `shortcutMode` |
| `1`–`8` | Select a track (mute it in play mode) | new `shortcutSelectTrack` |
| `B` | Switch bank A / B | new `shortcutBank` |
| `U` | Undo the last overdub pass | new `shortcutUndoOverdub` |
| `A` | Arm / disarm performance recording | new `shortcutArm` |
| `R` *(record mode)* | Record / overdub the selected track | new `shortcutRecord` |
| `P` *(record mode)* | Play / pause the selected track | new `shortcutPlayPause` |
| `G` | Open the Signal view | reuse `signalTooltip` |
| `F` | Toggle fullscreen | reuse `fullscreenTooltip` |
| `S` | Open settings | reuse `settingsTooltip` |
| `⌘/Ctrl`+`Z` / `Y` | Undo / redo | new `shortcutUndo` / `shortcutRedo` |
| `⌘/Ctrl`+`S` | Save the open session | new `shortcutSaveSession` |
| `Tab` | Move focus between controls | new `shortcutFocusTraverse` |

~11 new l10n keys + a title (`a11yShortcutsHelp`) — **in both `app_en.arb` and
`app_es.arb`** (the repo keeps locale parity; run `flutter gen-l10n`).

## Tasks
- [ ] `lib/looper/view/shortcuts_help_sheet.dart`: `showShortcutsHelp(context)` +
      the dialog widget (platform modifier helper, grouped rows, merged Semantics).
- [ ] `tracks_chrome.dart`: add the `Icons.keyboard` IconButton
      (`tooltip: l10n.a11yShortcutsHelp`, `key: Key('tracks_shortcutsHelp')`).
- [ ] `tracks_commands.dart` `handleKey`: `?` (Shift+Slash) → `showShortcutsHelp`.
      Return `handled`. Keep it out of the "swallow plain keys" fallthrough only
      for `?`.
- [ ] `app_en.arb` + `app_es.arb`: the ~12 new keys (with `@`-metadata for any
      placeholders — none needed here).
- [ ] Tests (`tracks_view_test.dart`): the help button opens the dialog; the `?`
      key opens it; the dialog lists a known shortcut; each row is a labeled
      Semantics node; the modifier shows `⌘` on macOS vs `Ctrl` elsewhere
      (`debugDefaultTargetPlatformOverride`).

## Acceptance
- [ ] Help button + `?` both open the legend; Esc closes it.
- [ ] Every `handleKey` shortcut appears with a correct, platform-aware chip.
- [ ] Each row is one accessible Semantics node; dialog is a named route.
- [ ] en + es parity; `flutter analyze` + `dart format` clean; existing
      `tracks_view` tests stay green.
