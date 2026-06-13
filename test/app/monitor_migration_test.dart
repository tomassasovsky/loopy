import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/app/monitor_migration.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('runMonitorMigration', () {
    late FakeKeyValueStore store;
    late SettingsRepository settings;

    setUp(() {
      store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
    });

    test(
      'legacy flag on + no saved routes seeds input 0 to the main out once',
      () async {
        await store.setBool('audio.monitor_input', value: true);

        await runMonitorMigration(settings);

        // Input 0 monitored to the main stereo pair (mask 0x3).
        expect(await settings.loadMonitorInput(0), (true, 0x3));
        expect(await settings.loadMonitorMigratedV1(), isTrue);

        // A second run must not re-touch input 0 (idempotent via the flag),
        // even if the legacy flag is somehow still set.
        await settings.saveMonitorInput(0, enabled: false, outputMask: 0x3);
        await runMonitorMigration(settings);
        expect(await settings.loadMonitorInput(0), (false, 0x3));
      },
    );

    test(
      'legacy flag on but an enabled route exists leaves routes untouched',
      () async {
        await store.setBool('audio.monitor_input', value: true);
        // The user already routes input 1 → right out; the migration must
        // not add input 0.
        await settings.saveMonitorInput(1, enabled: true, outputMask: 0x2);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInput(0), isNull);
        expect(await settings.loadMonitorInput(1), (true, 0x2));
        expect(await settings.loadMonitorMigratedV1(), isTrue);
      },
    );

    test(
      'an enabled route at the highest scanned input (kMaxInputs-1) blocks it',
      () async {
        await store.setBool('audio.monitor_input', value: true);
        // A route at the very top of the scanned range must still be seen, so a
        // one-off in the scan ceiling would surface here.
        await settings.saveMonitorInput(
          kMaxInputs - 1,
          enabled: true,
          outputMask: 0x1,
        );

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInput(0), isNull);
      },
    );

    test(
      'a disabled saved route counts as "no route" and is migrated',
      () async {
        await store.setBool('audio.monitor_input', value: true);
        // A saved-but-disabled route is not audible, so it does not block the
        // courtesy migration.
        await settings.saveMonitorInput(2, enabled: false, outputMask: 0x3);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInput(0), (true, 0x3));
      },
    );

    test('legacy flag off enables no monitoring', () async {
      await store.setBool('audio.monitor_input', value: false);

      await runMonitorMigration(settings);

      expect(await settings.loadMonitorInput(0), isNull);
      expect(await settings.loadMonitorMigratedV1(), isTrue);
    });

    test(
      'a fresh install (no legacy flag) just marks the migration done',
      () async {
        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInput(0), isNull);
        expect(await settings.loadMonitorMigratedV1(), isTrue);
      },
    );

    test('already-migrated stores are skipped entirely', () async {
      await settings.saveMonitorMigratedV1();
      // Legacy flag on + no routes would normally seed input 0, but the
      // done-flag short-circuits before any read.
      await store.setBool('audio.monitor_input', value: true);

      await runMonitorMigration(settings);

      expect(await settings.loadMonitorInput(0), isNull);
      expect(await settings.loadMonitorMigratedV1(), isTrue);
    });
  });
}
