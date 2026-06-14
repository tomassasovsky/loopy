import 'package:looper_repository/looper_repository.dart' show kMaxInputs;
import 'package:settings_repository/settings_repository.dart';

/// One-time courtesy migration from the removed global passthrough monitor to
/// the per-input live-monitor routing graph.
///
/// The old "Monitor input" toggle persisted a single global flag
/// (`audio.monitor_input`) that auto-enabled hardware input 0 to the main
/// stereo pair at engine start. That mechanism is gone; monitoring is now the
/// per-input routing graph ([SettingsRepository.loadMonitorInput]). So a user
/// who relied on the global monitor would otherwise launch silent.
///
/// Runs once (guarded by [SettingsRepository.loadMonitorMigratedV1]) and is
/// idempotent: if the legacy flag was on and the user has no enabled per-input
/// route yet, it seeds input 0 → main out (mask `0x3`) so they keep hearing
/// their input. A user who already configured per-input monitoring, or who had
/// the legacy flag off, is left untouched. The done-flag is always set, so a
/// later "disable monitoring" is never re-enabled on the next launch.
///
/// Called unconditionally from `runLoopy` before the engine-start branch, so it
/// runs on a first launch and on the mock path too — not only when a saved
/// config exists.
Future<void> runMonitorMigration(SettingsRepository settings) async {
  if (await settings.loadMonitorMigratedV1()) return;

  final legacyOn = await settings.loadLegacyMonitorInput() ?? false;
  if (legacyOn && !await _hasEnabledRoute(settings)) {
    // Restore the legacy behaviour: input 0 monitored to the main stereo pair.
    await settings.saveMonitorInput(0, enabled: true, outputMask: 0x3);
  }

  await settings.saveMonitorMigratedV1();
}

/// Whether any hardware input already has an enabled, audible monitor route
/// saved. Scans the same `[0, kMaxInputs)` range the `MonitorCubit` restores,
/// using the shared engine ceiling so the two never drift. A route that is
/// enabled but routed to no output (`outputMask == 0`) is inaudible and so does
/// not count — the user would otherwise have a silent monitor and still benefit
/// from the courtesy migration.
Future<bool> _hasEnabledRoute(SettingsRepository settings) async {
  for (var input = 0; input < kMaxInputs; input++) {
    final routing = await settings.loadMonitorInput(input);
    if (routing != null && routing.$1 && routing.$2 != 0) return true;
  }
  return false;
}
