# Control Center consolidation, and what a footswitch can point at

- **Date:** 2026-08-03
- **Status:** brainstorm
- **Related:** #442 (console UI redesign), #490, #492, #493

## What We're Building

Two changes that turned out to share a cause.

**One place for config.** Settings and the Signal/Routing page still push
full-screen routes, so they sit outside the tray that everything else moved
into. Both become in-tray rail destinations. The rail's existing rule — only
surfaces that render *inside* the tray get an entry, because "a rail item that
navigated away would lie about what the rail is" — stops being a caveat and
becomes absolute.

**A pedal picker you can read.** The footswitch assignment list is unusable:
roughly fifty entries on a modest rig, each labelled by its position in the
signal graph. It will offer named racks as its primary target and reach slots
underneath them, and it will stop offering targets that cannot do anything.

## Why This Approach

**Consolidation is about discoverability, not screen space.** The motivation
given was "too many places to look" — not that full-screen routes lose the
stage view. That distinction changes the design: the goal is one honest answer
to "where do I change things", so a partial move (routing in, settings out)
would leave exactly the ambiguity being complained about. Hence all of it.

The cost is real and should be stated: audio setup and MIDI learn are dense
surfaces, and the tray sheet has to hold them. This is only affordable because
in-tray faces now fill the sheet beside the rail (#493) instead of being pinned
to a 520×680 box — a near-fullscreen face can carry a settings page; a small
centred panel could not.

**The pedal picker's problem is addressing, not sorting.**
`availableBindingTargets()` walks the signal graph and emits, for every
configured input, loop lane, track channel and master, the whole chain plus one
target per effect slot inside it. Each is identified by an `FxAddress` (stage,
index, lane) and a `slotId`.

So the list addresses things by **their position in the signal graph**, while a
performer thinks about them by **the sound they change**. `loop 2 lane 1 slot 3`
is a coordinate; "Dirty rhythm" is a thing you made. No amount of grouping or
sorting fixes a coordinate — which is why this is not a picker problem.

Three problems were tangled together here, and separating them is most of the
work:

| Problem | Fix | Already decided? |
| --- | --- | --- |
| Coordinates instead of names | named racks | **yes** — #442, part 3 |
| Chain vs slot granularity | see below | no |
| Targets that cannot do anything | filter | no |

**Both granularities are needed.** Asked what a switch changes mid-song, the
answer was "depends on the song" — sometimes a whole sound in or out, sometimes
kicking one effect on for a solo. So slot targets cannot be dropped, and the
design question is how they coexist without the slot list swamping the rack
list. That is the only genuinely open question here; the other two have obvious
answers.

**Relevance is free.** The list offers every configured chain whether or not it
holds anything. An empty lane chain is a valid, bindable, silent target. Nothing
is lost by omitting targets that cannot produce an audible change, and it
shortens the list before any other work.

## Key Decisions

- **All of Settings and Routing become in-tray rail destinations.** No
  exceptions, no "reached from the tray but rendered elsewhere". Depends on
  #493's fill behaviour to be usable.
- **Named racks are the pedal picker's primary target.** This is not new work —
  it falls out of part 3, already planned. The picker is a consumer of that
  decision rather than a separate feature.
- **Slot targets stay reachable but stop being peers of racks.** Both gestures
  are real; the list length should scale with the number of racks, not with the
  number of effects inside them.
- **Targets that cannot change anything are not offered.** Empty chains, and
  anything whose toggle is inaudible.

## Open Questions

- **How slots are reached.** The natural shape is a two-level picker — choose a
  rack, optionally drill into a slot inside it — so list length tracks racks
  rather than effects. Alternatives are a flat list with slots indented under
  their rack, or a filter-first picker. Not decided; worth mocking before
  choosing, given how badly the flat list read.
- **Where "Custom mode" assignment lives** once Settings is in the tray, since
  part 8 adds a per-switch assignment surface that overlaps this picker.
- **Whether the rail can hold every destination** once Settings and Routing join
  fx, routing, pedal, loop, tuner and the radios. The mockups show five entries
  plus a pinned control; this could reach nine or ten. May need grouping, which
  would be the launcher-home idea returning through the back door — worth
  watching rather than pre-solving.
- **Migration for existing bindings.** A binding stored against an `FxAddress`
  has to keep working, or be visibly broken, when the picker starts speaking in
  racks. The resolver already treats a stale binding as a no-op that the
  assignment screen shows as broken (R25), so the machinery exists.

## Not Doing

- **Dropping slot targets.** Tempting — it would make racks a complete answer —
  but "kick the boost on for the solo" is a real gesture and removing it to
  simplify a list would be solving our problem, not the user's.
- **Redesigning the picker before racks land.** Grouping the current list by
  stage would improve it, but the entries would still be coordinates. Better to
  fix the addressing once than to style the symptom twice.
