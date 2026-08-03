# Corpus: `performance.json` manifest fixtures

Unlike the Live 12 `.als` corpus described in [the parent README](../README.md)
— which still needs a real Ableton install to populate — these fixtures need
nothing but the documented file format
([`docs/design/performance-manifest-format.md`](../../../../../docs/design/performance-manifest-format.md)),
so they are committed and exercised by the suite today.

They are shared by `manifest_reader_test.dart` and `fx_chains_test.dart`: one
manifest read by both reader surfaces, so the two can never drift on what a
given capture means. Tests copy a fixture into a temp capture directory and
create whatever stems/loops the case needs beside it.

| File | What it pins |
|---|---|
| `fx-stages-v1.json` | A current, four-stage FX v3 capture (`fxStagesVersion: 1`) with **mixed enabled bits** at every level. |
| `legacy-pre-fx-v3.json` | A pre-FX-v3 capture: **no** `fxStagesVersion` marker, no bus stages, no bypass flag anywhere — the back-compat proof. |

## What `fx-stages-v1.json` deliberately exercises

- **Channel 0** — both lanes carry the *same* chain with the *same* second
  slot bypassed (`enabled: false`). Per-slot bypass is not part of a chain's
  sound, so the two lanes still agree and the channel resolves to a
  single-effect device chain (the bypassed slot dropped, never emitted as a
  live device).
- **Channel 1** — one lane whose *whole* chain is bypassed
  (`chainEnabled: false`). It resolves to an empty chain, exactly as a lane
  with no chain at all would: its wet stem is bit-exact passthrough, so
  emitting its entries as devices would add effects the performance never had.
- **`trackChains`** — one engaged bus chain (channel 0) and one bypassed bus
  chain (channel 1), so both header forms are covered.
- **`masterEffects`** — two entries, the second bypassed, with
  `masterChainEnabled` omitted (i.e. the insert itself is engaged).
- `slotId`s throughout, which are entry *identity* and must never affect
  chain equality (A9).

Both bus stages are **manifest-only** (R20): they are never rendered into a
stem and never become `.als` devices. `fx-chains.txt` is the only place they
surface, which is what the fx_chains tests assert.
