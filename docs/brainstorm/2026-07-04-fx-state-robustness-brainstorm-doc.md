# FX state robustness — bug-hunt findings

**Symptoms reported (2026-07-04):** FX selection shows wrong; FX lost after
recording; lost after save/load; lost after clear + record. Both built-in and
VST3, across lane / monitor / master chains.

**Diagnosis in one line:** FX chains have the exact disease control state had
before the `ControlCubit` refactor — multiple independent stores with no
written ownership or invalidation rules — except worse, because there are
FOUR stores and one of them (the session bundle) doesn't participate at all.

## The four stores of an FX chain

| Store | Written by | Read by |
| --- | --- | --- |
| Engine lane/monitor chains (`a_fx_*`) | repository applies; engine's own record-snapshot (`le_snapshot_input_fx_to_lanes`) | the AUDIO (only truth that sounds) |
| `LooperRepository._laneEffects` / `._monitorEffects` (Dart cache) | setters; `_snapshotMonitorChainsOntoLanes` mirror | **`LooperState.lanes[].effects` — what the UI renders** (looper_repository.dart:387); restart replay |
| Settings (encoded chains per lane/monitor) | `LooperBloc.setLaneEffects` / `MonitorCubit` — **on explicit UI edit only** | `audio_bootstrap` replay at launch |
| Session bundle manifest | — **nothing: FX are not saved** | — |

`LooperState.Lane` is a hybrid row: volume/mute/routing come from the engine
snapshot, `effects` comes from the Dart cache. The engine never reports
chains back (only `fxAddedLatencyFrames`), so a divergence is invisible and
permanent until something replays a cache.

## Confirmed bugs

- **F1 — Sessions don't carry FX.** `session_repository.dart` saves audio +
  volume/mute/multiple per track; no lane chains, no monitor chains, no
  plugin state. Load restores a rig whose FX are whatever was lying around.
  → "lost after save/load."
- **F2 — Session load bypasses `LooperRepository` entirely.** `load()` calls
  `_engine.clear/importTrack/setLaneVolume/setLaneMute` directly:
  - **F2a** repository caches (`_laneVolume`, `_laneMute`) go stale; the next
    device restart/reconnect replays the STALE cache over the loaded session.
  - **F2b** `_forgetLaneMutes` never runs, so pre-load persisted mutes replay
    at next launch over the loaded session.
  - **F2c** engine lane chains survive the load's clears (`handle_clear`
    doesn't touch `a_fx_count`; only engine create/configure resets it —
    engine.c:129), so **session B plays through session A's leftover
    chains** while the UI shows the cache. → "selection shows wrong" +
    audible-wrong FX.
- **F3 — Take-snapshot chains are never persisted.** Recording copies the
  monitor chain onto the lane (engine + Dart cache mirror), but nothing
  writes it to settings — `saveLaneEffects` runs only on explicit edits. A
  restart replays the pre-take chain from settings. → "selection shows
  wrong" after restart; take plays back different from what you heard.
- **F4 — Clear + record wiped staged lane FX** when the monitor was dry.
  Already fixed on this branch (commit 11980f2, PR #108: dry monitor keeps
  the lane's own chain, engine + repository). The reported symptom likely
  predates that fix — verify on the PR build before chasing further.
- **F5 — Plugin chains on cold boot are placeholders until the async scan
  lands** (`_ensureRestoredPluginsLoaded`); a failed/slow scan leaves
  "unavailable" entries that read as wrong selection. Needs a visible
  loading/unavailable state rather than silent wrongness, and a rebind retry.
- **F6 — No engine readback, no invariant, no fuzz coverage.** The FX domain
  has no equivalent of the control invariant spec: nothing asserts
  "cache == engine chain", and the sequence fuzzer's alphabet has no FX
  actions, so none of the above could ever be caught mechanically.

("Master/output FX": the engine has no master FX chain today — master has
gain + output gates only. Whatever was observed there needs a concrete repro;
possibly the output-gate or monitor-output interaction.)

## Recommended fix shape (the control-state recipe, applied to FX)

1. **One owner:** chains live in the repository maps as the single Dart
   truth, with WRITTEN invalidation rules (what clear does, what record's
   snapshot-copy does, what session load does) — and every engine write goes
   through the repository. Session load must flow through `LooperRepository`
   (new `restoreSession(...)` API), never drive the engine directly.
2. **Sessions carry FX:** manifest v2 with per-lane + per-monitor encoded
   chains (same codec as settings), restored through the repository so
   engine + cache + settings all agree after a load. Manifest version bump
   with legacy (v1) tolerated on read.
3. **Persist on every chain WRITE, not just UI edits:** the record-time
   snapshot mirror also saves to settings (F3), and clear-paths decide
   explicitly whether a chain survives (document: it does).
4. **Readback or checksum:** expose a per-lane chain fingerprint in the
   engine snapshot so a debug assert (and the fuzzer) can check
   `cache == engine`; add FX actions (set/clear chain, record-over,
   session save/load) to the fuzz alphabet.

Rough order: F2 (load through repository) → F1 (manifest v2) → F3 → F5 →
F6. F2+F3 are self-contained bug fixes; F1 is a format change; F6 is the
safety net that keeps this fixed.
