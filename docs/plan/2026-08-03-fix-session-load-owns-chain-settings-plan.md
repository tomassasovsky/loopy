---
title: "fix(session): a session load owns the boot-restore chain settings"
type: fix
date: 2026-08-03
issue: 389
---

## fix(session): session load writes chains back to settings

> Issue: [#389](https://github.com/tomassasovsky/segno/issues/389)
> Direction: **decided 2026-08-03 — option 1, "yes, a load owns the keys."**
> Autonomy: was `plan-gate` on that call; with it made this is
> `merge-gate` — verifiable here, but it rewrites persistence for every FX
> stage, so the blast radius earns a human merge.
> **Shipped:** [#489](https://github.com/tomassasovsky/segno/pull/489)
> (2026-08-04). This plan is the recorded direction + build brief.

## The decision, recorded

**A session load owns the settings keys.** After loading session B, a cold
boot must restore **session B's** chains — not the rig that was live before
the load, and not nothing.

Rejected: "settings describe the live rig only." The engine and the re-apply
caches *are* updated by a load, so settings would be the only place still
holding the old rig — and today they do not even do that consistently (the
Loop stage ends up empty rather than stale). That is not a defensible
intent, it is the bug restated.

## Problem

`LooperRepository.applySession` re-applies every chain to the engine and to
its caches, but nothing writes them to `settings_repository`. Settings are
written only from the *edit* paths (`LooperBloc._pushLaneEffects` /
`_persistLaneChain` / `_persistTrackChain` / `_persistMasterChain`).
`applySession` calls the repository setters directly, so:

| Stage | Key | After load → quit → relaunch |
|---|---|---|
| Loop (per-lane) | `lane_effects.$channel.$lane` (`settings_repository.dart:842`) | **empty** — the pre-load destructive clear fired `onLaneChainChanged` and zeroed the keys; the applied chains were never written |
| Track | `track_fx_chain.$channel` | **stale** — the pre-load rig resurrects |
| Master | `master_fx_chain` | **stale** — same |
| Input (monitors) | `monitor_*` | **correct** — the only stage that closes the hole |

Input is correct only because
`lib/session/view/session_monitor_sync_listener.dart` re-projects from
`LooperRepository.allMonitors()` and re-persists on
`SessionOutcome.loaded`. Nothing equivalent exists for the other three.

Since FX v3 part 3b the chain strings are **envelopes**, so a stale value also
carries stale per-chain/per-slot enable flags and stale slot ids — a pedal
binding stored against a slot id from the loaded session dangles after a
restart.

## Approach

Mirror the monitor pattern, in the layer that already owns those writes.

1. **`LooperBloc` gains a resync entry point** — an event
   (`LooperSessionLoaded` or similar) whose handler re-persists from
   the repository, exactly as the edit paths do:
   - `allLaneChains()` → `saveLaneEffects` per (channel, lane)
   - `allTrackChains()` → `persistTrackFxChain` (the shared writer in
     `lib/common/fx_chain_persistence.dart` — do **not** add a second writer;
     that helper exists because the bloc and pedal paths drifted once)
   - `masterChainEnvelope()` → `saveMasterFxChain`
2. **Reset the keys the loaded rig dropped.** A load can shrink the rig: a
   lane or channel present before but absent after must have its key removed,
   not left holding the old value. `SettingsRepository` already uses a
   `_store.remove` idiom for exactly this (`:682`, `:801`); add the lane/track
   equivalents beside the existing save/load pairs.
3. **One listener, not two.** Extend the existing
   `SessionMonitorSyncListener` to dispatch the bloc event alongside
   `MonitorCubit.syncFromRepository()`, and rename it for what it now does
   (e.g. `SessionPersistenceSyncListener`). Its `listenWhen` guard —
   `status == success && outcome == loaded` — is already exactly right, and
   its doc comment already explains why a load must not be trusted to have
   updated persistence. Two listeners racing the same trigger is how the
   asymmetry started.
4. **Document the rule on `applySession`.** Its doc comment must state that a
   load updates the engine and caches and that the *caller* owns writing
   settings back — the asymmetry is silent today, which is why it survived
   review twice.

## Testing

The verification the issue sketches, and it is the real exit criterion:

- App-level, real `LooperRepository` + `FakeAudioEngine` + a fake settings
  store: stage chains on **all four** stages, save, load a session defining
  different chains, then re-run the boot restore and assert the **loaded**
  session's chains come back — enable flags and slot ids included, not the
  pre-load ones and not empty.
- A shrinking load: the loaded session defines fewer lanes/channels than the
  live rig; assert the dropped keys are gone rather than stale.
- The Input stage keeps working — it is the one that is already right, so it
  is the regression canary for the listener rename.
- A sabotage check on the main test: revert the bus re-persist and confirm it
  fails. A test that cannot fail is why this shipped.

## Non-goals

- No change to what `applySession` does to the engine or the caches.
- No session schema change — this is purely about who writes the boot-restore
  keys. Part 3 (racks) changes the format; this decides the ownership, and it
  is deliberately landed **first** so that migration is written once.
