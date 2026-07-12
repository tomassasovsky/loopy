# Session bundle format (`.loopy`)

A saved session is a directory (a `.loopy` **bundle**) holding a JSON manifest,
one WAV per audio layer, and a flattened mixdown. This document describes the
**v3** schema and how legacy bundles migrate.

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

## Manifest schema (v3)

```jsonc
{
  "version": 3,
  "sampleRate": 48000,
  "channels": 1,
  "baseLengthFrames": 96000,
  "tracks": [
    {
      "channel": 0,
      "multiple": 1,
      "lengthFrames": 96000,
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
  "laneChains": [ /* opaque encodeTrackEffects strings, per (channel, lane) */ ],
  "monitors":   [ /* per-input live-monitor config + chain */ ]
}
```

Audio never appears in the manifest; it lives in the referenced WAVs. Effect
chains are stored as the same opaque wire string settings persist, so the data
package never depends on the effect model.

## Backward compatibility

`Session.fromJson` is **presence-keyed** (it branches on which fields exist, not
on a version `switch`), matching how v1→v2 was handled:

| Bundle | Detected by | Loads as |
|--------|-------------|----------|
| **v1** | no `laneChains` / `monitors`, `stem` per track | one lane-0 live layer, empty chains |
| **v2** | `laneChains` / `monitors` present, `stem` per track | one lane-0 live layer + chains |
| **v3** | `lanes` per track | full multi-lane, multi-layer |
| **> v3** | `version` greater than supported | `SessionUnsupportedVersion` |

A legacy `stem` migrates to a single `SessionLane`(lane 0) holding one live
`SessionLayer`, with the old track-level `volume`/`muted` mapped onto lane 0 and
`inputChannel = -1` (unbound). Writing is always v3.

## History

- **v1** — transport + one mono stem per track.
- **v2** — added per-lane and per-monitor effect chains.
- **v3** — per-lane audio (multi-lane) and per-lane overdub-layer stacks with
  undo/redo restore. Shipped as the session overdub-fidelity initiative
  (parts 1–4).
