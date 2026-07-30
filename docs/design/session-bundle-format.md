# Session bundle format (`.loopy`)

A saved session is a directory (a `.loopy` **bundle**) holding a JSON manifest,
one WAV per audio layer, and a flattened mixdown. This document describes the
**v5** schema and how legacy bundles migrate.

Related: the performance-capture path stores retiring layers with its own
numbered files + sidecar (see [performance-manifest-format](performance-manifest-format.md)
and [performance-event-log-format](performance-event-log-format.md)); the session
bundle reuses the *shape* (numbered per-lane layer WAVs) but is written
synchronously on the control thread, not streamed from a live capture.

## Layout

```
sessions/<slug>/
  session.json            # the manifest (source of truth)
  mixdown.wav             # flattened preview: every unmuted lane's live buffer summed
  track0_lane0_L0.wav     # per (track, lane, layer-ordinal) mono 32-bit-float WAV
  track0_lane0_L1.wav
  track0_lane0_L2.wav
  track0_lane1_L0.wav
  track1_lane0_L0.wav
  ...
```

The **manifest is the only source of truth**. WAV files are opaque and named
purely by index (`track{channel}_lane{lane}_L{ordinal}.wav`); a file the
manifest does not reference is ignored on load and pruned on the next save.

## Layers, ordinals, and undo/redo

A track's undo history is not a set of deltas — each overdub pass snapshots the
**whole loop** before it writes, so a lane's complete state is an ordered list of
full-length buffers. A save persists every one:

```
ordinal:   0 .. undoCount-1     undoCount        undoCount+1 .. undoCount+redoCount
buffer:    undo snapshots       live (playing)   redo snapshots (newest last)
```

- `liveIndex == undoCount`; `layers.length == undoCount + 1 + redoCount`.
- The ordering is the linear timeline oldest→newest, matching the engine's
  `le_engine_export_layer` walk (`undo_stack[0..) → a_live → redo stack`,
  newest-adjacent first). On load, `le_engine_import_layer` + `finalizeLayers`
  rebuild the pool + undo/redo stacks so `undo`/`redo` reproduce every take.
- The undo/redo depths are **track-wide** (the stacks are shared across lanes in
  lockstep), so every lane of a track carries the same layer count.
- Capacity: a track cannot exceed `LE_POOL_SLOTS` (256) total layers; the engine
  rejects an over-cap import.

## The four FX stages

Since v5 the manifest persists all four stages of the FX v3 signal path
(#351), in signal order:

| Stage | Manifest field | Keyed by | Notes |
|---|---|---|---|
| **Input** | `monitors[].encoded` | hardware input | The live-monitor chain, pre-record. Rides the monitor record that also carries its routing/mix. |
| **Loop** | `laneChains[]` | `(channel, lane)` | A lane's record-route chain. |
| **Track** | `trackChains[]` | track channel | The per-track stereo-bus insert, downstream of that track's lanes. |
| **Master** | `masterChain` | — | The single insert on the summed mix, before gain/limiter. A bare string, not a list; `""` when the rig has no Master state at all. |

The Input and Loop fields keep the key names v2 gave them (`monitors`,
`laneChains`); renaming them to match the stage vocabulary would be churn with
no compatibility payoff.

Every chain — all four stages — is stored as **one opaque encoded string**, so
this data package never depends on the effect model. It is the same string
settings persist, which is what makes a chain round-trip byte-for-byte between
the two.

## Chain envelope

The string's content is the looper domain's chain **envelope** (`encodeFxChain`
in `looper_repository`, decoded by `decodeFxChain`). Only the app-side mapper
(`lib/session/session_mapping.dart`) and `looper_repository` ever look inside
it; `session_repository` treats it as an opaque blob.

```jsonc
{
  "chainEnabled": true,          // the whole chain engaged? (R15)
  "meta": { "inheritedFrom": [0, 1] },   // Loop stage only; omitted when never inherited
  "entries": [
    { "type": 3, "params": [0.35, 0.35, 0.35, 0.0], "slotId": "3f2a91c7-4" },
    { "type": 3, "params": [0.5, 0.2, 0.1, 0.0], "enabled": false, "slotId": "3f2a91c7-5" }
  ]
}
```

- `chainEnabled` — the per-chain bypass. A disabled chain renders dry while
  every per-entry flag stays intact.
- `meta.inheritedFrom` — the hardware inputs whose monitor chains were
  snapshot-copied onto this lane at record time, in input order (A8). Present
  on Loop-stage chains only; omitted entirely when a chain was never inherited.
- `entries[]` — the engine's own entries array, embedded verbatim, so the entry
  wire format has exactly one definition. Per entry:
  - `enabled` — written **only when `false`** (absent = audible).
  - `slotId` — the entry's stable per-slot identity (A9), minted once by the
    repository's chain write boundary and never reused within a session. Pedal
    bindings and expression mappings address slots by this id.

Both omissions matter for migration: a pre-FX-v3 chain string is a **bare
entries array** (no envelope object at all), and `decodeFxChain` accepts it as
`chainEnabled: true`, no meta, every entry `enabled: true`, every `slotId`
null — "migration defaults every level to enabled" (R15).

Note what is *not* here: there are no per-flag manifest fields, and no per-flag
settings keys either. Every enable bit and every slot id lives inside the one
string per chain.

## Manifest schema (v5)

```jsonc
{
  "version": 5,
  "sampleRate": 48000,
  "channels": 1,
  "baseLengthFrames": 96000,
  "tracks": [
    {
      "channel": 0,
      "multiple": 1,
      "lengthFrames": 96000,
      "lengthPresetBars": 0,        // v4: 0 = AUTO
      "oneShot": false,             // v4
      "lanes": [
        {
          "lane": 0,
          "volume": 0.8,
          "muted": false,
          "outputMask": 3,
          "inputChannel": 0,
          "undoCount": 1,
          "redoCount": 1,
          "layers": [
            { "file": "track0_lane0_L0.wav" },
            { "file": "track0_lane0_L1.wav" },
            { "file": "track0_lane0_L2.wav" }
          ]
        }
      ]
    }
  ],

  // --- FX: the four stages, each an opaque envelope string ---
  "monitors": [                     // Input stage (+ routing/mix), v2+
    { "input": 0, "enabled": true, "outputMask": 3, "volume": 1.0, "muted": false, "encoded": "{…}" }
  ],
  "laneChains": [                   // Loop stage, v2+
    { "channel": 0, "lane": 0, "encoded": "{…}" }
  ],
  "trackChains": [                  // Track stage, v5
    { "channel": 0, "encoded": "{…}" }
  ],
  "masterChain": "{…}",             // Master insert, v5; "" = none

  // --- tempo grid / click / count-in (v4) ---
  "tempoBpm": 0.0,
  "tempoSource": "none",
  "tsNum": 4,
  "tsDen": 4,
  "quantizeDiv": "off",
  "clickMode": "off",
  "clickOutputMask": 0,
  "clickVolume": 1.0,
  "countInBars": 0,

  // --- looper mode / crown / One Shot (v4, B5c) ---
  "looperMode": "multi",
  "primaryTrack": -1,
  "oneShotChannels": []
}
```

Audio never appears in the manifest; it lives in the referenced WAVs.

Chains exist **independently of audio**: a `laneChains`/`trackChains` entry may
name a channel or lane with no `tracks` entry at all, and it still loads. The
same holds in reverse for state that has no audio to hang on —
`oneShotChannels` is session-level precisely so a flag armed on an empty
channel survives a save.

## Backward compatibility

`Session.fromJson` is **presence-keyed** (it branches on which fields exist, not
on a version `switch`), the way every rung since v1→v2 was handled:

| Bundle | Detected by | Loads as |
|--------|-------------|----------|
| **v1** | no `laneChains` / `monitors`, `stem` per track | one lane-0 live layer, empty chains |
| **v2** | `laneChains` / `monitors` present, `stem` per track | one lane-0 live layer + chains |
| **v3** | `lanes` per track | full multi-lane, multi-layer |
| **v4** | tempo-grid / click / count-in / B5c fields present | + tempo grid, mode, crown, One Shot |
| **v5** | `trackChains` / `masterChain` present, envelope chain strings | + the two bus stages, per-chain + per-slot enable, slot ids, inheritance provenance |
| **> v5** | `version` greater than supported | `SessionUnsupportedVersion` |

A legacy `stem` migrates to a single `SessionLane`(lane 0) holding one live
`SessionLayer`, with the old track-level `volume`/`muted` mapped onto lane 0 and
`inputChannel = -1` (unbound). Every field a newer rung added defaults to the
value that reproduces the older behavior exactly: grid-off for the tempo
fields, `multi`/no-crown for B5c, and — for v5 — **both bus stages empty and
every enable flag true**. Writing is always the current version (v5); this code
never writes an older schema.

### Migration invariants

Three properties are pinned by tests, because a regression in any of them is
silent:

1. **A v4 load is fingerprint-identical.** `fxChainFingerprint` folds params
   plus the real enable bits and deliberately excludes `slotId`, so a v4
   chain — whose entries decode `enabled: true` and whose ids are minted fresh
   — produces the same fingerprint as it did before the migration. The engine's
   published fingerprint and the repository cache still agree after a load.
2. **Save → load → save is byte-idempotent.** Slot ids are minted **exactly
   once**, at the repository write boundary that first sees an id-less entry,
   and then persisted. A build that re-minted per load would keep the
   fingerprint identical (see 1) while quietly dangling every stored pedal
   binding — only the idempotence test catches that.
3. **A stage the manifest does not define is reset, never inherited.** Loading
   a session resets every remembered chain and chain-enabled flag of all four
   stages that the loaded rig leaves undefined, in the engine *and* the
   repository caches, so a previous session's leftovers can never sound under
   the loaded one (R17). The Master insert therefore has no "absent" state on a
   v5 write: the field is always present, empty (`""`) when the rig has no
   Master chain, and an empty Master is applied — i.e. it wipes a leftover —
   exactly like a populated one.

## History

- **v1** — transport + one mono stem per track.
- **v2** — added per-lane and per-monitor effect chains.
- **v3** — per-lane audio (multi-lane) and per-lane overdub-layer stacks with
  undo/redo restore. Shipped as the session overdub-fidelity initiative
  (parts 1–4).
- **v4** — the Phase-A tempo grid (`tempoBpm`, `tempoSource`, `tsNum`, `tsDen`,
  `quantizeDiv`), the click (`clickMode`, `clickOutputMask`, `clickVolume`),
  count-in (`countInBars`), and B5c's looper mode / crowned primary track /
  One Shot (`looperMode`, `primaryTrack`, `oneShotChannels`, per-track
  `oneShot`, per-track `lengthPresetBars`). Shipped as the tempo-aware
  looper-modes initiative; every field defaults to the tempo-free, grid-off
  value, so a v3 bundle loads as "Multi, grid off".
- **v5** — the four-stage FX model (#351): the Track-stage (`trackChains`) and
  Master (`masterChain`) inserts, and the chain envelope for every stage —
  per-chain `chainEnabled`, per-entry `enabled`, stable `slotId`s, and Loop-stage
  inheritance provenance. A v4 bundle loads with both bus stages empty and
  everything enabled.
