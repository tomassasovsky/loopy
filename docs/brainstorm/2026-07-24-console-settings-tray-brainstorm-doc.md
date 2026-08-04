---
date: 2026-07-24
topic: console-settings-tray
---

# Console Settings Tray

## What We're Building

A slide-down quick-access tray on the console's main 15.6in touchscreen, in the
style of iOS/Android Control Center: swipe down from the top edge to reveal a
panel of shortcut buttons, swipe/tap to dismiss. The tray gives faster access
to a handful of destinations without leaving the main tracks/looper view.

Tray contents:

- **Settings** — opens the existing `SettingsPage` (same destination as the
  `S` key / gear icon today)
- **Signal/FX graph** — opens the existing graph page (same destination as the
  `G` key today)
- **WiFi** — new, stubbed as "coming soon" (used later for firmware updates)
- **Bluetooth** — new, stubbed as "coming soon" (used later for a sidecar app)
- **Tuner** — new, stubbed as "coming soon"
- **Brightness** — an inline slider in the tray itself (not a navigation
  destination), UI-only for now — moves and holds local state but does not
  yet dim the physical display

No new keyboard shortcuts are introduced. `S` and `G` keep their current
bindings; the tray buttons for Settings and Signal/FX graph are just
additional entry points to those same existing destinations.

## Why This Approach

Research into the existing app found no slide-down/overlay precedent at all —
navigation is plain `Navigator`/`MaterialPageRoute` pushes via a global
`segnoNavigatorKey`, and the only sheet-like precedent is a single
`showModalBottomSheet` call. This interaction has to be built from scratch
regardless of approach.

Three approaches were considered for the tray mechanism:

- **A — Local Stack overlay with drag-following animation.** A drag detector
  on the top edge of `TracksChrome` reveals a panel in a `Stack`, tracking the
  finger during the drag and snapping open/closed on release.
- **B — Custom modal route** pushed through the existing `segnoNavigatorKey`
  pattern (same shape as `openSegnoSettings()`), with a barrier and slide
  transition.
- **C — Global `SettingsTrayCubit`** mounted above the `Navigator` in
  `app.dart`, making the tray reachable from every screen.

B was ruled out: routes are discrete open/close, and a route push can't
naturally track a continuous drag gesture — you'd still need raw drag
detection on the base screen before pushing the route, so you end up building
most of Approach A's gesture code anyway, on top of route machinery, while
losing the "follows your finger" feel.

C's global reach was ruled out as unnecessary scope — the tray is only needed
on the 15.6in main touchscreen, not from Settings or the graph page.

Landed on a **hybrid of A and C**: a `SettingsTrayCubit` (matching this
project's established bloc/cubit convention for state management) drives
open/closed state, drag progress, and the brightness slider value, but the
Cubit and its overlay widget are scoped to the console screen
(`TracksChrome`), not mounted globally in `app.dart`. The UI/gesture behavior
is Approach A's drag-follows-finger Stack overlay; only the state container
changes from local `State` to a `Cubit`.

## Key Decisions

- **Tray shell only, this round.** WiFi, Bluetooth, and Tuner get stub
  ("coming soon") destinations. Their real functionality is separate,
  later work.
- **No new keyboard shortcuts.** `G` stays bound to the signal/FX graph page;
  `S` stays bound to Settings. The tray's Settings and Signal/FX graph buttons
  are additional entry points to those same existing routes, not new
  destinations.
- **Brightness is UI-only for now.** The slider lives in the tray and holds
  local/Cubit state, but doesn't wire into real display dimming yet — no
  wlr-randr or platform-channel work in this round. That's separate follow-up
  work once the tray shell exists.
- **Trigger gesture: swipe down from the top edge**, tracking the finger
  during the drag (not a discrete tap-to-open), matching the iOS/Android
  Control Center feel.
- **Scoped to the 15.6in main touchscreen only.** Not the 7in secondary panel,
  not desktop/dev builds specifically (though nothing prevents mouse-drag
  testing incidentally).
- **State management: `SettingsTrayCubit`**, scoped to the console screen
  (mounted within/near `TracksChrome`), not globally in `app.dart`. Chosen
  over plain widget-local `State` to match the project's established
  bloc/cubit convention, and over a global mount because no other screen
  currently needs the tray.

## Open Questions

- Exact stub UI for WiFi/Bluetooth/Tuner — a shared "coming soon" placeholder
  widget, or per-destination placeholders with distinct icons/copy?
- Does the brightness slider need to persist its value across app restarts
  (even though it doesn't dim anything yet), or is it fine to reset each
  session until real dimming is wired up?
- Any accessibility/reduced-motion consideration for the drag animation?
- Icon/visual design for the tray panel and its buttons — not explored here,
  left for planning/implementation.
