import 'package:looper_repository/looper_repository.dart' show kMaxInputs;
import 'package:settings_repository/settings_repository.dart';

/// One-time courtesy + structural migrations of the persisted monitor settings,
/// run from `runLoopy` at bootstrap (so a first launch and the mock path run
/// them too, not only when a saved config exists).
///
/// Two ordered steps, each guarded by its own done-flag so they run once and
/// are idempotent:
///
/// 1. **v1** — global passthrough flag → per-input route. The old "Monitor
///    input" toggle persisted a single global flag (`audio.monitor_input`) that
///    auto-enabled hardware input 0. v1 seeds the legacy per-input
///    (`monitor_input.N`) key so that user keeps hearing their input.
/// 2. **v2** — single per-input route → multi-lane monitor. Converts each
///    legacy single-route input (effected route + parallel dry send) into the
///    multi-lane model: the effected route becomes lane 0, and a non-empty dry
///    send becomes lane 1 (a no-FX clean lane). The legacy keys are then
///    cleared.
///
/// v1 runs first so a cold upgrade folds both in order: the global flag becomes
/// a per-input route (v1), which v2 then converts to lanes.
Future<void> runMonitorMigration(SettingsRepository settings) async {
  await _runMonitorMigrationV1(settings);
  await _runMonitorMigrationV2(settings);
}

/// v1: restores the removed global passthrough monitor as a per-input route.
///
/// If the legacy flag was on and the user has no enabled per-input route yet,
/// it seeds input 0 → main out (mask `0x3`). A user who already configured
/// per-input monitoring, or who had the legacy flag off, is left untouched. The
/// done-flag is always set, so a later "disable monitoring" is never
/// re-enabled.
Future<void> _runMonitorMigrationV1(SettingsRepository settings) async {
  if (await settings.loadMonitorMigratedV1()) return;

  final legacyOn = await settings.loadLegacyMonitorInput() ?? false;
  if (legacyOn && !await _hasEnabledRoute(settings)) {
    await settings.saveMonitorInput(0, enabled: true, outputMask: 0x3);
  }

  await settings.saveMonitorMigratedV1();
}

/// Whether any hardware input already has an enabled, audible legacy monitor
/// route saved. Scans the same `[0, kMaxInputs)` range the `MonitorCubit`
/// restores. A route enabled but routed to no output (`outputMask == 0`) is
/// inaudible and so does not count.
Future<bool> _hasEnabledRoute(SettingsRepository settings) async {
  for (var input = 0; input < kMaxInputs; input++) {
    final routing = await settings.loadMonitorInput(input);
    if (routing != null && routing.$1 && routing.$2 != 0) return true;
  }
  return false;
}

/// v2: converts each legacy single-route monitor input into the multi-lane
/// model, then clears the legacy keys. Deterministic and flag-guarded (not
/// key-absence-based), so it runs exactly once after v1.
Future<void> _runMonitorMigrationV2(SettingsRepository settings) async {
  if (await settings.loadMonitorMigratedV2()) return;

  for (var input = 0; input < kMaxInputs; input++) {
    await _migrateInputToLanes(settings, input);
  }

  await settings.saveMonitorMigratedV2();
}

/// Folds hardware [input]'s legacy single route into lanes:
/// - **lane 0** = the effected route (`outputMask` = old wet mask, `volume` =
///   old gain, `effects` = old chain). A no-FX chain makes it the clean path.
/// - **lane 1** = the old parallel dry send as a no-FX (clean) lane, written
///   only when the dry mask routed somewhere (`!= 0`).
///
/// A no-op when the input has no legacy keys saved.
Future<void> _migrateInputToLanes(
  SettingsRepository settings,
  int input,
) async {
  final routing = await settings.loadMonitorInput(input);
  final dryMask = await settings.loadMonitorInputDry(input);
  final volume = await settings.loadMonitorInputVolume(input);
  final effects = await settings.loadMonitorInputEffects(input);

  // Nothing legacy saved for this input → nothing to migrate.
  if (routing == null && dryMask == 0 && volume == null && effects == null) {
    return;
  }

  final enabled = routing?.$1 ?? false;
  final wetMask = routing?.$2 ?? 0x3;
  final gain = volume ?? 1.0;

  // lane 0 = the wet/effected route (clean when there are no effects).
  await settings.saveMonitorInputEnabled(input, enabled: enabled);
  await settings.saveMonitorLaneOutput(input, 0, wetMask);
  await settings.saveMonitorLaneVolume(input, 0, gain);
  if (effects != null) {
    await settings.saveMonitorLaneEffects(input, 0, effects);
  }

  var laneCount = 1;
  // lane 1 = the old dry send as a no-FX (clean) lane, only when it routed.
  if (dryMask != 0) {
    await settings.saveMonitorLaneOutput(input, 1, dryMask);
    await settings.saveMonitorLaneVolume(input, 1, gain);
    laneCount = 2;
  }
  await settings.saveMonitorLaneCount(input, laneCount);

  await settings.clearLegacyMonitorInput(input);
}
