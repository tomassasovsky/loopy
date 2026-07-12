# fix: session monitors — save dry inputs & re-sync MonitorCubit on load

**Type:** bug fix
**Date:** 2026-07-11
**Branch:** `claude/input-monitoring-fx-cache-4ba187`
**Domain:** FX-state-robustness (follows PR #112 — one-owner `LooperRepository`, chain-fingerprint fuzzer)

---

## Problem

Two user-reported defects around per-input live monitoring on Windows (not platform-specific):

1. **Some inputs stop monitoring after a session change / on open** — the user must toggle the
   monitor indicator off/on to restore audio.
2. **FX from a previous session get "cached" on inputs** — audible on monitoring after switching
   sessions; adding another FX on the FX dock clears them.

Both trace to per-input **monitors** being mishandled in the session save/load path.

### Root cause 1 — session *save* silently drops dry monitors (→ symptom #1)

`chainsFromLooper` ([lib/session/session_mapping.dart:22](../../lib/session/session_mapping.dart)) enumerates
monitors from `looper.allMonitorEffects()`, which returns **only inputs with a non-empty FX chain**
(`_monitorEffects` never stores empty chains —
[looper_repository.dart:918](../../packages/looper_repository/lib/src/looper_repository.dart)).

An input monitored **clean/dry** (enabled + routed, no FX — the common case) is therefore never written
to the session bundle. On load, `applySession` resets every remembered monitor the rig does **not**
define back to *disabled*
([looper_repository.dart:858-877](../../packages/looper_repository/lib/src/looper_repository.dart)),
so the dry input is switched off. Toggling re-asserts it via `MonitorCubit.setEnabled`.

The existing round-trip test only ever exercises a monitor that *has* an FX
([session_fx_roundtrip_test.dart:89](../../test/session/session_fx_roundtrip_test.dart)), so the gap
is uncaught.

### Root cause 2 — session *load* never re-syncs `MonitorCubit` (→ symptom #2)

`SessionCubit.loadNamed → _looper.applySession(...)`
([session_cubit.dart:117](../../lib/session/cubit/session_cubit.dart)) writes the engine **and** the
repository caches, but the **`MonitorCubit` is never told**. `MonitorCubit` owns (a) the on-screen
monitor / FX-dock state read by the Signal surface
([signal_list_view.dart:185](../../lib/looper/view/signal_graph/signal_list_view.dart)) and (b) the
**persisted monitor settings**. Nothing bridges a session load back to it
([app.dart:188-202](../../lib/app/view/app.dart) — no listener; `load()` runs once at boot).

After switching sessions: the engine holds the new session's monitor chains, but the FX dock still
shows the *previous* session's chains (stale cubit). The dock's stale view re-applies that old chain
on the next edit (`_pushEffects` rebuilds the whole engine chain), so old FX "reappear," and a
rebuild-style edit (adding an FX) wipes them. Persisted settings also drift from what was loaded.

> The native engine fully resets all monitors on every `start()`
> ([engine.c:371](../../packages/loopy_engine/src/core/engine.c)), so this is **not** a
> startup/restart leak — it is purely the load-time split-brain. The occasional "on opening the
> program" flavor is most likely separate ASIO device-timing and is **out of scope** here (tracked as
> a follow-up).

---

## Proposed solution

Keep `LooperRepository` the single owner of monitor state; make the save path enumerate **all**
configured monitors, and make `MonitorCubit` re-project from the repository after a session load.

### Change 1 — `LooperRepository.allMonitors()` (new), and one enumerator

Add a repository method returning every **configured** monitor input as a full `InputMonitor`, where
"configured" = differs from the disabled default (enabled ∥ muted ∥ non-unity volume ∥ non-default
output mask ∥ non-empty FX). This becomes the **single** monitor-enumeration source of truth: the save
path, the cubit re-sync, **and** `applySession`'s reset loop all read it.

```dart
// packages/looper_repository/lib/src/looper_repository.dart
import 'package:looper_repository/src/models/input_monitor.dart'; // NEW — first InputMonitor use here

/// Every configured live monitor, keyed by input — the union of all remembered
/// monitor state, not just inputs with an FX chain. A monitor equal to the
/// disabled default is omitted (absent == disabled default on load).
Map<int, InputMonitor> allMonitors() {
  final inputs = <int>{
    ..._monitorInputEnabled.keys,
    ..._monitorOutput.keys,
    ..._monitorVolume.keys,
    ..._monitorMute.keys,
    ..._monitorEffects.keys,
  };
  final result = <int, InputMonitor>{};
  for (final input in inputs) {
    final monitor = InputMonitor(
      input: input,
      enabled: monitorEnabled(input),
      outputMask: monitorOutput(input),
      volume: monitorVolume(input),
      muted: monitorMuted(input),
      effects: monitorEffects(input),
    );
    if (monitor != InputMonitor(input: input)) result[input] = monitor; // skip default
  }
  return result;
}
```

`InputMonitor` already exists with value equality
([input_monitor.dart](../../packages/looper_repository/lib/src/models/input_monitor.dart)) and is
exported, so the repository can return it directly.

**Collapse the two enumerators (VGV review).** After Change 2, `allMonitorEffects()`
([looper_repository.dart:918](../../packages/looper_repository/lib/src/looper_repository.dart)) has **no
production callers** and would leave the repo with two monitor enumerators using *different* filters
(non-empty-chain vs non-default) — a drift hazard. **Delete `allMonitorEffects()`** and migrate its unit
test ([looper_repository_test.dart:2687](../../packages/looper_repository/test/looper_repository_test.dart))
to assert on `allMonitors()`. (Build step: grep to confirm no other caller before deleting.)

**Reuse in `applySession` (simplicity review).** `applySession` currently recomputes the same five-map
union inline as `rememberedMonitors`
([looper_repository.dart:862-869](../../packages/looper_repository/lib/src/looper_repository.dart)).
Replace that inline union with `allMonitors().keys.toList()` (snapshot before the reset loop mutates the
maps). Resetting a monitor already equal to the disabled default is a no-op, so omitting default-equal
inputs is behaviorally identical — and removes the second place the union could drift.

### Change 2 — `chainsFromLooper` enumerates all monitors

```dart
// lib/session/session_mapping.dart
monitors: [
  for (final entry in looper.allMonitors().entries)
    SessionMonitor(
      input: entry.key,
      enabled: entry.value.enabled,
      outputMask: entry.value.outputMask,
      volume: entry.value.volume,
      muted: entry.value.muted,
      encoded: encodeTrackEffects(entry.value.effects),
    ),
],
```

No change to `rigFromBundle` or the bundle format — the wire format already carries all five fields;
we simply stop under-populating the list on save. Old bundles still load unchanged.

### Change 3 — `MonitorCubit.syncFromRepository()` (new) + shell bridge

Persist through **one private helper** so the sync and drop paths can't drift from the five persisted
fields, and reset dropped inputs to the **full** disabled default (all five fields) — not just
enabled+effects. This matters because `_restoreInput` treats *any* saved field as "configured"
([monitor_cubit.dart:87-93](../../lib/audio_setup/cubit/monitor_cubit.dart)), so a lingering persisted
`outputMask`/`volume`/`mute` would resurrect a stale (disabled) monitor entry on the next boot —
inconsistent with `applySession`, which resets all five fields for undefined monitors.

```dart
// lib/audio_setup/cubit/monitor_cubit.dart
/// Re-projects the per-input monitors from the repository (the one owner) after
/// a session load applied them straight to the engine, and re-persists them so
/// the next boot restores THIS session's monitors, not a pre-load leftover.
Future<void> syncFromRepository() async {
  final applied = _repository.allMonitors();
  final previous = state.inputs.keys.toSet();
  emit(MonitorState(inputs: applied));
  for (final monitor in applied.values) {
    await _persistMonitor(monitor);
  }
  // Inputs dropped since the last state reset to the FULL disabled default, so
  // the next boot reads them as "no saved state" (mirrors applySession).
  for (final input in previous.difference(applied.keys.toSet())) {
    await _persistMonitor(InputMonitor(input: input));
  }
}

/// Persists every field of [monitor] (the five monitor settings keys). Shared by
/// syncFromRepository's apply + reset loops so they never diverge.
Future<void> _persistMonitor(InputMonitor monitor) async {
  await _settings.saveMonitorInputEnabled(monitor.input, enabled: monitor.enabled);
  await _settings.saveMonitorOutput(monitor.input, monitor.outputMask);
  await _settings.saveMonitorVolume(monitor.input, monitor.volume);
  await _settings.saveMonitorMute(monitor.input, muted: monitor.muted);
  await _settings.saveMonitorEffects(monitor.input, encodeTrackEffects(monitor.effects));
}
```

Wire the bridge as **another entry in the existing `MultiBlocListener`** in `_AppView.build`
([app.dart:580-601](../../lib/app/view/app.dart) — where the waveform / connectivity / MIDI / recovery
shell bridges already live), matching the surrounding listeners. `SessionCubit` composes repositories
(not cubits), so the reconciliation belongs in the widget tree, not a cubit-to-cubit subscription.

```dart
// lib/app/view/app.dart — inside _AppView.build's MultiBlocListener list
BlocListener<SessionCubit, SessionState>(
  // Only a LOADED session applies monitors to the engine; save/saveAs/rename/
  // delete emit `saved`/`renamed`/... and must NOT re-sync. Every action passes
  // through a `working` emit that nulls `outcome`, so this transitions each load.
  listenWhen: (a, b) =>
      b.status == SessionStatus.success && b.outcome == SessionOutcome.loaded,
  listener: (context, _) =>
      unawaited(context.read<MonitorCubit>().syncFromRepository()),
),
```

---

## Files touched

| File | Change |
|------|--------|
| `packages/looper_repository/lib/src/looper_repository.dart` | Add `allMonitors()` (+ `InputMonitor` import); **delete** `allMonitorEffects()`; `applySession` reset loop reads `allMonitors().keys` |
| `lib/session/session_mapping.dart` | `chainsFromLooper` uses `allMonitors()` |
| `lib/audio_setup/cubit/monitor_cubit.dart` | Add `syncFromRepository()` + `_persistMonitor()` helper |
| `lib/app/view/app.dart` | Add `BlocListener<SessionCubit>` → `syncFromRepository()` inside the existing `MultiBlocListener` in `_AppView.build` |

## Tests

| File | Test |
|------|------|
| `packages/looper_repository/test/looper_repository_test.dart` | New `allMonitors()` tests: returns enabled **dry** monitors; omits pure-default inputs; includes FX/mute/volume/output-varied inputs. **Migrate** the existing `allMonitorEffects()` test (~:2687) onto `allMonitors()` |
| `test/session/session_fx_roundtrip_test.dart` | Extend round-trip: stage an **enabled dry** monitor on a second input (no FX) alongside the existing FX monitor; assert `monitorEnabled` + routing survive save→clear→load (fuzz-tagged, self-skips without `LOOPY_ENGINE_LIB`) |
| `test/session/cubit/session_cubit_test.dart` | **Regression guard (critical):** add `when(looper.allMonitors).thenReturn(const {})` to the shared `setUp` — the save tests (`saveAs`/`save`, ~:166/:212/:445) now call `allMonitors()` and would throw on a mock without that stub |
| `test/audio_setup/cubit/monitor_cubit_test.dart` | `syncFromRepository()` re-projects repo monitors into state, persists **all five** fields, and resets **all five** persisted fields for inputs dropped since the last state |
| `test/app/…` (widget test) | Bridge: pump the shell, drive a `loaded` `SessionState`, assert `MonitorCubit` state re-projects. (Not `session_cubit_test` — the wire lives in the widget tree.) |

## Acceptance criteria

- [ ] Saving a session with an **enabled dry** monitor (no FX) and reloading it keeps that input
      monitoring to its outputs — no toggle needed.
- [ ] After switching sessions, the FX dock reflects the **loaded** session's monitor chains, and no
      previous-session FX are audible on monitoring.
- [ ] Persisted monitor settings after a session load match the loaded session (next boot restores it).
- [ ] `allMonitors()` omits inputs equal to the disabled default (no bundle bloat).
- [ ] `allMonitors()` is the **only** monitor enumerator — `allMonitorEffects()` is gone, no other callers.
- [ ] A dropped input's persisted settings read as full disabled default on next boot (no resurrected monitor via a lingering `outputMask`/`volume`/`mute`).
- [ ] Existing FX-state fuzzer + `monitorChainFingerprint`/engine agreement stay green.
- [ ] Existing `session_cubit_test` save tests stay green (mock stubs `allMonitors`).
- [ ] `flutter analyze` clean; `flutter test` (non-fuzz) green; monorepo package tests green.

## Risks & mitigations

- **Bundle format** — unchanged; only the save-side monitor list is more complete. Old bundles load
  as before. Low risk.
- **Settings write volume on sync** — bounded by the number of configured inputs (small). Awaited so a
  rapid re-load can't interleave, mirroring `_restore`.
- **Fuzzer/fingerprint** — `allMonitors()` reads existing getters; no engine writes. Re-sync reads the
  repo (the owner) and never re-pushes to the engine, so it cannot desync engine vs cache.
- **Double-apply** — the bridge only *reads* the repo into the cubit; it does not call
  `_applyMonitor`, so the engine is untouched by the re-sync (no risk of re-triggering DSP resets).

## Out of scope

- Intermittent "monitor off on program open" when it stems from ASIO device-open timing (separate
  follow-up; the engine-reset path is already correct).
- Multi-lane monitor keys (`saveMonitorLane*`) — legacy, folded to single-chain at bootstrap (v3).
