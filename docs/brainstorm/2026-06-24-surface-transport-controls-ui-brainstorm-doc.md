---
date: 2026-06-24
topic: surface-transport-controls-ui
---

# Surface Keyboard/Pedal-Only Transport Controls in the UI

## What We're Building

A small set of on-screen controls in the Big Picture performance view for the
handful of actions that today can *only* be invoked by keyboard shortcut or MIDI
pedal — they have no widget. Research across `lib/looper/view/big_picture_view.dart`
and `lib/pedal/cubit/pedal_cubit.dart` confirmed the gap is narrow: nearly every
action (mode toggle, bank switch, track select, record, stop, mute, settings,
signal graph, session save/load/export) already has both a shortcut and a button.
Only five actions are input-method-exclusive.

The work adds **global transport buttons** (Play All / Stop All, Clear All,
Fullscreen toggle) to the top bar, and **per-track Undo / Redo** controls on the
currently-selected track's column. Each reuses the existing `LooperBloc` events
and cubit calls the keyboard handler already dispatches — this is a presentation-
layer change with no engine or repository work.

## Why This Approach

Three approaches were considered for placement:

1. **All in a global transport bar** — simplest, but misrepresents Undo/Redo,
   which are per-track operations bound to the selected channel. A global undo
   button would hide which track it acts on.
2. **Split: global + per-track (chosen)** — global actions (Play/Stop All, Clear
   All, Fullscreen) live in the top bar next to the existing signal/session
   controls; Undo/Redo attach to the selected track column, matching their
   actual semantics (`LooperUndoPressed(selectedChannel)`).
3. **Overflow menu** — keeps the view uncluttered but buries performance-critical
   actions behind a tap, defeating the point of surfacing them for live use.

The split approach was chosen because it keeps each control's placement honest to
what it operates on, and the global cluster sits naturally beside the existing
top-bar icon buttons (`bigpicture_openSignal`, `_SessionMenu`).

All buttons dispatch the **same events the keyboard map already uses**, so
behavior is identical across input methods — no new business logic, no
divergence to keep in sync.

## Key Decisions

- **Scope = 5 actions:** Play All / Stop All (one toggle button), Clear All,
  Fullscreen toggle, and per-track Undo + Redo. Everything else already has a
  widget; surfacing more would be redundant.
- **Split placement:** Global transport (Play/Stop All, Clear All, Fullscreen) in
  the top-bar Row at `big_picture_view.dart:68`, beside the signal button and
  session menu. Undo/Redo on the selected track's `_TrackColumn` header
  (`big_picture_view.dart:601`), shown only when that column is `selected`.
- **Clear All fires instantly** (no confirmation dialog), matching the existing
  `C` key and pedal Clear behavior; users rely on Undo. Keeps all three input
  methods consistent rather than making the button a special, safer case.
- **Tooltips expose the shortcut** (e.g. "Clear All (C)", "Play All (Space)") for
  discoverability — consistent with the existing `signalTooltip` pattern and the
  WCAG-labelled `_SessionMenu`/`FocusableTapTarget` widgets.
- **Reuse existing events/cubits:** `LooperPlayAllPressed` / `LooperStopAllPressed`,
  `LooperClearAllPressed`, `LooperUndoPressed(channel)` / `LooperRedoPressed(channel)`,
  and `toggleLoopyFullScreen()`. No new bloc events.
- **Theme + a11y conventions:** use `LooperTheme` tokens and `FocusableTapTarget`
  / `IconButton` with semantic labels and `Key`s, matching the surrounding
  top-bar and track-column widgets (per VGV architecture standards — extracted
  widget classes, no pixel params in public APIs).

## Open Questions

- **Play/Stop All as one toggle vs two buttons?** The keyboard `Space` is a single
  toggle keyed off "is anything playing." A single state-aware button mirrors that;
  two separate buttons are more explicit but take more top-bar space. Lean: single
  toggle button reflecting current play state. (Resolve in planning.)
- **Undo/Redo visibility:** show only on the selected column (less clutter) vs on
  every column (any track reachable in one tap). Selected-only matches the
  keyboard semantics (acts on selected channel) and is the leaning default.
- **Disabled states:** should Undo/Redo/Clear All grey out when there's nothing to
  undo / no content? Nice-to-have; depends on whether the bloc exposes that state
  cheaply. Confirm during planning.
- **Fullscreen icon state:** reflect enter/exit fullscreen with a changing icon, or
  a static toggle icon? Minor; planning detail.
