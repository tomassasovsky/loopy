# Release notes — FX system v3

Epic [#351](https://github.com/tomassasovsky/loopy/issues/351). This is the
user-facing summary of what changed, written for someone upgrading an existing
install: what is new, what moved, and — the part worth reading twice — the
handful of places where something you already relied on now behaves
differently.

## What's new

**Effects have four stages now, in signal order.**

| Stage | What it colors |
|---|---|
| **Input** | one chain per hardware input, heard live, never recorded |
| **Loop** | one chain per lane, on that lane's playback |
| **Track** | one chain per track's stereo bus, downstream of its lanes |
| **Master** | one insert on the master bus, last before the outputs |

Previously only the Input and Loop stages existed. The Signal surface shows all
four, and each has its own bypass.

**Bypass is universal, at two levels.** Every chain has an on/off flag and
every slot inside it has its own. A bypassed slot is bit-exact passthrough (not
a zero-mix), and flips crossfade over about 5 ms so stomping mid-performance
doesn't click.

**The pedal has an FX mode.** The mode cycle now reaches FX, where each
footswitch toggles a bound chain or slot. Bindings can be momentary — held
engages, released restores — and a session can carry its own remap that
overrides the global one.

**External MIDI can drive the same targets.** Continuous CCs map onto a
parameter range (inverted ranges are allowed); discrete CCs map onto a
threshold with hysteresis. Both resolve to the same targets the pedal uses.

**Loop-stage effects are cached automatically.** Once a lane's chain has been
stable for about 250 ms, a background worker renders that lane's whole loop and
playback switches to the rendered result at zero effects CPU. Any change drops
straight back to live. You are not meant to notice this — see the caveats
below for the two places you might.

**Exports report the bus stages.** `fx-chains.txt` in a performance capture now
lists the Track and Master chains after the per-lane Loop ones, marking
disabled slots and disabled chains. The Input stage is not listed — a monitor
chain is heard live and never recorded, so it describes none of the audio a
capture contains.

## Upgrading: sessions and settings

**Session files migrate automatically, and old ones keep working.** Saved
sessions moved from schema v4 to **v5** (bus stages) and then **v6** (pedal
remap). Every step is presence-keyed, so nothing needs converting:

- A **v4** session loads with the Track and Master stages **empty** — it never
  described them. Its existing Input and Loop chains load unchanged.
- Every chain level defaults to **enabled**. A pre-v3 session could not bypass
  anything, so nothing loads bypassed.
- A **v5** session loads with **no session pedal remap**, so your global pedal
  bindings apply.

Sessions saved by this version are **not** readable by older builds.

## Behavior changes worth knowing

These are deliberate, and each one is somewhere you could otherwise be
surprised.

**An overdub never re-inherits the input's chain.** When you record a lane, it
takes a *copy* of the chain you were monitoring through — it sounds identical
the moment it lands, but it is a copy, not a live link. Editing that input
afterwards does not rewrite the take, and overdubbing onto the lane later does
**not** pull the input's current chain in. If the two have drifted apart, the
Signal surface says so rather than silently picking one.

**Adding Track FX to a track whose lanes route to different outputs changes
where it is heard.** While a track's own chain is empty — the default, and what
every migrated session starts as — routing is bit-identical to before. As soon
as you put an effect on the track bus, its audible lanes sum into one stereo
bus, the chain runs once, and the result goes to the **union** of those lanes'
enabled output masks. If your lanes deliberately went to *different* outputs,
adding track FX will now feed all of them. Nothing changes until you add that
first track effect.

**Bypassing a chain does not spill its tail.** Switching an effect off cuts its
reverb/delay tail with it rather than letting it ring out. This is the same
rule at both levels, and it is what makes a stomp predictable.

**Editing a cached lane drops the current tail at that instant.** When a change
knocks a lane off the cache, playback falls back to live processing on the same
frame, which resets the effect's DSP state — so a delay or reverb tail that was
sounding stops rather than decaying through the edit. Accepted deliberately:
the alternative is a lag between the edit and hearing it.

**Muting during cached playback behaves slightly differently from live.**
Muting a cached lane routes nothing at all; unmuting resumes from the cached
render, still cached. Because tails are baked into the periodic render rather
than produced moment to moment, what you hear on unmute can differ slightly
from the same gesture on a live lane.

## Known limits

- Only the **Loop** stage is cached. Chains hosting a VST3/CLAP plugin are
  never cached, because an offline render would pass the plugin dry.
- **Track and Master chains are recorded in the export manifest, not rendered
  into stems** and not emitted as devices in the `.als`. Stems stay per-stage
  dry-of-downstream. `fx-chains.txt` is where you read those stages back.
- **Undo does nothing in FX mode.** What a stomp's undo should even mean —
  one toggle, a whole gesture, a momentary hold — is
  [#219](https://github.com/tomassasovsky/loopy/issues/219). Until that lands,
  FX-mode undo is deliberately inert rather than guessing.
- Track **pan** is not a MIDI target (the engine has no pan), and hosted plugin
  parameters are not offered as targets yet.
