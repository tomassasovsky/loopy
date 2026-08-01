# FX toggle undo/redo — the contract #219 has to satisfy

Written by FX system v3 part 9 ([#351](https://github.com/tomassasovsky/loopy/issues/351))
as a hand-off to [#219](https://github.com/tomassasovsky/loopy/issues/219),
which owns undoable/redoable clear "incl. FX + mutes". **Nothing here is
implemented.** FX-mode undo is deliberately inert today, and part 5b's negative
tests are the guard that keeps it that way until #219 decides.

This note exists so #219 does not have to rediscover the constraints v3 has
already pinned.

## Why v3 stopped short

Universal bypass made a toggle a first-class performance gesture: a footswitch
in FX mode, an expression pedal, or an external CC can flip a chain or a slot
mid-take. That immediately raises "what does undo do now?" — and every
plausible answer is a product decision, not an implementation detail:

- Does one undo revert **one slot flip**, or the **whole stomp** that flipped
  several bindings at once?
- Is a **momentary** hold (engage on press, restore on release) even in the
  history, or is it transient by nature?
- Does an FX undo compete with the track-content undo stack the same button
  drives elsewhere, or is it a separate history?

Guessing would have shipped a behavior users then depend on. So v3 shipped the
toggles and left undo inert.

## Constraints #219 must respect

These are already load-bearing in v3. An undo design that breaks one of them
breaks something that currently works.

### 1. A toggle must not bump `a_audio_rev`

`a_audio_rev` is the track's **content** revision, and it is part of the wet
cache's key. Enable flips deliberately do not bump it: that is what makes
stomping a chain off and back on **cache-hot** (both entries of a toggled pair
are retained, part 2 [B2]). If an undo implementation routes a toggle through
a content-revision bump — for instance by treating "restore previous FX state"
as a content mutation — every stomp becomes a cache miss and the Pi's xrun
budget pays for it.

Undo of a toggle should write the same enable flags the toggle wrote, by the
same path, and nothing else.

### 2. Momentary capture is first-press-only, and release is centralized

Momentary bindings capture the target's pre-press state on the **first** press
only (`putIfAbsent`) — a repeated press with no release between them, which a
dropped NoteOff produces, must never re-capture the state the binding itself
just enabled, or the target strands on. `releaseAllMomentary()` is the single
enforcement point for restoring held bindings; the pedal path and the external
MIDI/CC path both funnel through it.

An undo that restores FX state while a momentary is **held** is the sharp edge
here: the held binding's captured "restore to" value is now stale, and its
eventual release would undo the undo. The two mechanisms have to agree on who
owns the target — the simplest safe rule is that undo either refuses while a
binding is held, or releases held momentaries first (against the outgoing
state) exactly as a session load does.

### 3. Session load already splits its seam for the same reason

`SessionCubit.applySession` releases held momentaries **before** applying, and
commits the new binding set **after** the apply succeeds. Undo is the same
shape of problem — a state swap underneath possibly-held bindings — and should
reuse that ordering rather than invent a second one.

### 4. Bypass has a ramp, and no tail spill

A flip crossfades over ~5 ms (`LE_FX_ENABLE_RAMP_MS`) and does **not** let the
disabled chain's tail ring out. An undo that flips several slots at once
inherits both properties for free if it goes through the normal setters — and
loses them if it reaches past them.

## Questions #219 should answer explicitly

1. **Granularity.** One slot per undo entry, or one entry per user gesture
   (a stomp that flips a whole bound set)? The binding model makes the gesture
   knowable, so either is implementable; the question is which one a performer
   expects.
2. **Are momentary holds undoable at all?** A held-then-released momentary
   leaves no net change. Recording it in history means undo can resurrect a
   state the user already let go of.
3. **One history or two?** FX toggles and track content currently share an undo
   button but not a stack. Merging them means an undo after a stomp might clear
   a loop; keeping them separate means the button's meaning depends on mode
   (which FX mode already establishes).
4. **What happens to redo when a binding is remapped?** A history entry
   addresses a slot by its stable id (A9), which survives reorders — but not
   deletion of the slot it names.

## Testing note

Part 5b's negative tests assert FX-mode undo does nothing. They are the
tripwire: whichever answer #219 picks, those tests must be **replaced
deliberately**, not deleted because they started failing.
