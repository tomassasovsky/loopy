# fix: reset leftover lane routing/count on session load

**Status:** Planned · **Date:** 2026-07-13 · **Type:** bug fix (session-state robustness)

> Verified against `master`. This is the one real residual from the two "session
> lane" gaps flagged in the 2026-07-13 triage — the overdub-fidelity initiative
> (#151–#156) already closed the rest (stems + per-lane input/output routing are
> saved and restored). See `docs/2026-07-13-backlog-triage.md`.

## The bug

Loading session B does **not** countermand the *live engine's* lane count/routing
for a track that session B leaves empty but session A had configured. Symptom:
**record into that now-empty track and the engine records session A's lane
count/inputs** (e.g. 2 lanes on inputs 0+1) instead of a fresh single default lane
— a `cache != engine` divergence.

### Root cause (file:line)
- `LooperRepository.applySession` (`packages/looper_repository/lib/src/looper_repository.dart:813`)
  clears every track (`:819-821`) and **purges the lane caches** `_laneCount/_laneInput/
  _laneOutput/_laneVolume/_laneMute` (`:825-829`) — which fixes the *restart replay*
  and the cache-reading record path, but never resets the **live engine**.
- Native `clear` does **not** reset lane state: `handle_clear`
  (`packages/loopy_engine/src/core/engine_process.c:495-526`) and `le_engine_clear`
  (`engine_commands.c:563+`) reset audio/state/length/mutes but leave `lane_count`
  and per-lane input/output intact.
- `applySession` has an explicit leftover-reset for **chains** (`:936-944`) and
  **monitors** (`:945-968`) but **none for lanes** — that asymmetry is the gap.
- The record path reads the *cache*, not the engine: `record` (`:666`) →
  `_snapshotMonitorChainsOntoLanes` (`~:700`) uses `_laneCount[channel] ?? 1` and
  `_laneInput[(channel,lane)] ?? lane`. So the cache says "1 lane" post-load, but the
  **engine still records at its stale `lane_count`** → divergence + wrong take.

### Engine fresh-lane defaults (confirmed — the reset must match these)
- `le_lane_reset(ln, input_channel)` (`engine.c:121`): output `0x3`, vol `1`, unmuted.
- Configure resets lane `l` to input `l` (`engine.c:280` `le_lane_reset(ln, l)`); a
  **growing** `set_lane_count` also resets each newly-activated lane to input `l`
  (`engine_commands.c:1058`). Fresh `lane_count = 1` (`engine.c:231`).
- So the repository's `?? lane` / `0x3` defaults already mirror the engine — good.

## Fix approach

**Option A (recommended) — repository-side, scoped to session load.** In
`applySession`, after the clear + cache purge, push the live engine back to fresh
lane defaults for every channel (mirroring the monitor/chain leftover-reset), then
let the rig restore (`:909-930`) re-apply the rig's tracks on top:

```dart
// Countermand the live engine's leftover lane count/routing so it matches the
// purged caches — clear() does not reset these, so a track session B leaves empty
// would otherwise record session A's lane count/inputs.
if (_intendRunning) {
  for (var c = 0; c < trackCount; c++) {
    _engine.setLaneInput(channel: c, lane: 0, inputChannel: 0);   // == le_lane_reset(_,0)
    _engine.setLaneOutput(channel: c, lane: 0, mask: 0x3);
    _engine.setLaneVolume(1, channel: c, lane: 0);
    _engine.setLaneMute(muted: false, channel: c, lane: 0);
    _engine.setLaneCount(channel: c, count: 1);   // inactive lanes reset on regrow
  }
}
```
Direct `_engine` calls (not the cached setters) keep the caches purged/minimal;
`cache(empty ⇒ default) == engine(default)` holds. Placement matters — see risks.

**Option B — native-side.** Make `handle_clear` reset `lane_count = 1` +
`le_lane_reset(lane[0], 0)`. Simpler ("clear ⇒ fully fresh track") and self-consistent
with the engine's own defaults, but changes `clear` semantics **globally** — the
control fuzzer and every clear test must confirm no regression. Prefer A unless the
team decides clear *should* reset lane structure.

## ⚠️ Must-verify before implementing
1. **Import vs. lane_count ordering.** The rig import loop (`:834-903`) stages layers
   into lanes **before** the routing restore sets `setLaneCount` (`:915`). Confirm
   whether `le_engine_import_layer` / `import_track_lane` auto-allocate the target lane
   or require `lane_count` set first. If they require it, Option A's `setLaneCount=1`
   reset must **not** run before a multi-lane rig track's import — reset only channels
   **not** in `rig.tracks`, or place the reset after import. (Snapshot the remembered
   lane channels before the purge to know which to reset — like the monitor snapshot at
   `:953`.)
2. **`setLaneCount` `_intendRunning` guard** (`:1111`) vs the unconditional
   input/output/vol/mute setters — keep the reset consistent with that.
3. **Fuzzer invariant.** Run the control-sequence fuzzer (`flutter test --tags fuzz`
   with `LOOPY_ENGINE_LIB` built) — it enforces `cache == engine`. Add a new action:
   *set lane routing/count on a track → apply a session that omits it → record into it*.

## Tasks
- [ ] Resolve must-verify #1 (read `engine_session.c` `le_engine_import_layer`/`_lane`).
- [ ] Implement Option A in `applySession` (reset only tracks absent from `rig.tracks`).
- [ ] New round-trip/fuzzer test mirroring the monitor leftover-reset
      (`packages/looper_repository/test/looper_repository_test.dart:2607`): load A (2-lane
      track) → load B (empty there) → record → assert 1 lane + `cache == engine`.
- [ ] Run the fuzzer + `looper_repository` + `session_repository` suites green.

## Out of scope (documented, lower priority)
- **Explicit lane count in the manifest.** Lane count is inferred on load from the
  highest audio-bearing lane (`applySession:913-914`); routing/count on an *audio-less*
  lane is dropped on capture (`session_repository.dart:374`). Add a `SessionTrack.laneCount`
  field (manifest v4, v3-tolerant) only if audio-less custom routing must round-trip.
- **Stale/dead code:** the header comment `engine_session.c:14-15` ("routing … not
  stored") is now wrong; `le_engine_export_track`/`import_track` (`engine_session.c:24`,
  `:120`) are lane-0-only legacy conveniences unused by the save path — delete or note.
