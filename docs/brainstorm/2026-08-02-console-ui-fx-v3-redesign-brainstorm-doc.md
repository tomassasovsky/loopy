---
date: 2026-08-02
topic: console-ui-fx-v3-redesign
---

# Console UI redesign for the FX v3 four-stage system

## What We're Building

A redesign of the floor-console UI around the FX v3 four-stage model (Input →
Loop → Track → Master), so the system's capabilities are discoverable and
configurable without a manual. The trigger: on real hardware, a working feature
set proved unusable — the pedal-assignment surface was unreachable, the
input-vs-track FX distinction was invisible, and there was no way to audition a
track's FX while recording into it.

The shape: the 16″ panel keeps a **clean stage view** with config living in a
**drawer that carries its own navigation rail**; the 7″ panel becomes a
**permanent performance readout** so configuring never blinds the performer.
Effects become **named, assignable racks** rather than anonymous per-stage
chains. The pedal keeps its predictable built-in modes and gains one fully
user-defined **Custom** mode.

Inspiration: the Sheeran Looper X (manual v1.0.0), which solves several of these
problems on a single small screen. Where its constraints do not apply to loopy —
notably screen size and count — its solutions were deliberately not copied.

## Why This Approach

**Navigation.** Four structures were mocked: a persistent rail, a Sheeran-style
launcher home, stage-first navigation, and a perform/edit split. The chosen shape
came from the user and beats all four: keep the existing drawer (which already
protects a clean stage view) and put the rail *inside* it. Config then never
routes you away from the performance surface — it is an overlay you drop out of
with one gesture. Sheeran's launcher was rejected as inheriting a small-screen
constraint loopy does not have: two taps to anywhere is a tax for a ~5″ display.

**Stage visibility.** Stage-first navigation was rejected as a *top-level*
structure (a poor home for performing) but adopted *inside* the FX and Routing
panels, where signal order is the thing being manipulated. This makes the four
stages visible furniture exactly where they matter, without forcing the model
onto the performance view.

**Racks over chains.** Sheeran's most valuable idea is not a layout — it is that
an FX Rack is a *named, saveable, transferable object*. Loopy's chains are
anonymous lists that exist only where they were built, so a sound must be rebuilt
from scratch every time. Racks also solve a legibility problem for free: loopy
already copies the input chain onto a take by value at record time, but that
inheritance is invisible today. With named racks, a take can show which rack it
inherited.

**Monitoring.** The user asked to build both a per-rack monitor flag and
Sheeran's per-track Live Signal, governed by a mode toggle, while flagging a
complexity worry. That worry was correct, and the two options turned out not to
be different models at all: a track holds one chain per stage, so both land on
the same object at the same granularity — one control wearing two hats, with a
meta-toggle deciding which. Rejected. Sheeran's real contribution is the **Auto**
state, which is smarter than on/off because it needs no attention; the rack
flag's contribution is *location*. Merged into one three-state control.

## Key Decisions

- **16″ stays a clean stage; config lives in the drawer, which carries its own
  navigation rail.** The user's synthesis, not one of the offered options.
  Preserves the reason the drawer exists while fixing that it currently only
  launches you elsewhere.
- **The 7″ panel becomes a permanent performance readout** (track states, loop
  position, tempo, what is armed). This is what makes a near-fullscreen drawer
  acceptable — you can configure mid-set without losing sight of the loop. It is
  also the one design question the Sheeran material cannot answer, since they
  have a single screen.
- **The four stages appear as tabs inside FX and Routing panels**, not as
  top-level navigation.
- **Effects become named, assignable racks** with their own presets, loadable
  onto any input or track and transferable. Replaces anonymous per-stage chains
  as the central object of the FX page.
- **One three-state live-monitor control per rack placement: off / auto / on.**
  Semantics from Sheeran's Live Signal, location from the rack model. `auto`
  (heard while the track is armed or selected) is the default. Explicitly
  **provisional**: the state lives on the rack placement regardless, so moving
  the control to a Routing page later is a view change with no migration, no
  protocol change, and no engine work — among the cheapest decisions here to get
  wrong.
- **Pedal keeps fixed built-in modes (REC / MUTE / FX) and gains one Custom
  mode** where every switch is a blank slot assigned from a function list.
  Predictability under the foot, blank canvas when wanted, without making
  existing modes ambiguous. A full remap matrix was rejected: overriding REC and
  STOP invites collisions with the long-press system gestures.

## Open Questions

- **Does the zero-config FX-mode layout keep binding Track chains?** For a
  guitarist the input chain *is* the pedalboard, so needing a remap for it may be
  backwards. But a button whose meaning depends on rig state is exactly what you
  do not want under a foot mid-set. Unresolved; carried from the session that
  triggered this work.
- **Rack persistence and scope.** Are racks global, per-session, or both? Does a
  take's inherited rack become a rack in its own right (editable, saveable) or a
  frozen copy? The existing by-value inheritance says frozen; the rack model
  invites editable.
- **Does `auto` follow armed, selected, or either?** They differ while stopped
  with a track selected but nothing recording.
- **Where does the tuner live** now that the drawer holds a rail — a rail
  destination, or a full-screen takeover as on Sheeran, given it mutes inputs?
- **Migration.** What happens to existing sessions' anonymous chains when racks
  land? Auto-name them, or leave them unnamed until touched?
- **7″ readout under the drawer.** Does it change at all while the drawer is
  open (e.g. showing the pedal map while on the Pedal page), or stay rigidly
  fixed? Rigid was chosen for the stage; the exception may be worth it during
  setup.
