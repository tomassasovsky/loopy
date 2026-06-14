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

    group('v1 (global flag → per-input), then v2 folds it into lanes', () {
      test(
        'legacy flag on + no saved routes ends as input 0, lane 0 → main out',
        () async {
          await store.setBool('audio.monitor_input', value: true);

          await runMonitorMigration(settings);

          // v1 seeded input 0 → main out; v2 folded it into lane 0 and cleared
          // the legacy key.
          expect(await settings.loadMonitorInputEnabled(0), isTrue);
          expect(await settings.loadMonitorLaneOutput(0, 0), 0x3);
          expect(await settings.loadMonitorLaneCount(0), 1);
          expect(await settings.loadMonitorInput(0), isNull); // legacy cleared
          expect(await settings.loadMonitorMigratedV1(), isTrue);
          expect(await settings.loadMonitorMigratedV2(), isTrue);
        },
      );

      test('legacy flag off enables no monitoring', () async {
        await store.setBool('audio.monitor_input', value: false);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(0), isNull);
        expect(await settings.loadMonitorMigratedV1(), isTrue);
        expect(await settings.loadMonitorMigratedV2(), isTrue);
      });

      test(
        'a fresh install (no legacy flag) just marks both migrations done',
        () async {
          await runMonitorMigration(settings);

          expect(await settings.loadMonitorInputEnabled(0), isNull);
          expect(await settings.loadMonitorMigratedV1(), isTrue);
          expect(await settings.loadMonitorMigratedV2(), isTrue);
        },
      );
    });

    group('v2 (single route → lanes)', () {
      test('a wet-only legacy route becomes lane 0', () async {
        // A user-configured single route on input 1: effected to out 1, with a
        // gain and a delay chain. The legacy per-input keys are no longer
        // written by the live app, so seed the old store directly.
        await settings.saveMonitorInput(1, enabled: true, outputMask: 0x2);
        await store.setDouble('monitor_input_vol.1', 0.4);
        await store.setString(
          'monitor_input_fx.1',
          encodeTrackEffects([TrackEffect(type: TrackEffectType.delay)]),
        );

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(1), isTrue);
        expect(await settings.loadMonitorLaneCount(1), 1);
        expect(await settings.loadMonitorLaneOutput(1, 0), 0x2);
        expect(await settings.loadMonitorLaneVolume(1, 0), 0.4);
        expect(
          await settings.loadMonitorLaneEffects(1, 0),
          encodeTrackEffects([TrackEffect(type: TrackEffectType.delay)]),
        );
        // The legacy keys are gone.
        expect(await settings.loadMonitorInput(1), isNull);
      });

      test(
        'a wet + dry legacy route becomes lane 0 (wet) + lane 1 (clean)',
        () async {
          // Effected route to out 0, a parallel dry send to out 1, gain 0.5.
          // Seed the legacy store directly (the live app no longer writes
          // these).
          await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);
          await store.setInt('monitor_input_dry.0', 0x2);
          await store.setDouble('monitor_input_vol.0', 0.5);

          await runMonitorMigration(settings);

          expect(await settings.loadMonitorLaneCount(0), 2);
          // lane 0 = the wet route.
          expect(await settings.loadMonitorLaneOutput(0, 0), 0x1);
          expect(await settings.loadMonitorLaneVolume(0, 0), 0.5);
          // lane 1 = the old dry send as a no-FX clean lane.
          expect(await settings.loadMonitorLaneOutput(0, 1), 0x2);
          expect(await settings.loadMonitorLaneVolume(0, 1), 0.5);
          expect(await settings.loadMonitorLaneEffects(0, 1), isNull);
        },
      );

      test('a zero dry mask produces a single lane (no clean lane)', () async {
        await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);
        // No dry send saved (defaults to 0).

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorLaneCount(0), 1);
        expect(await settings.loadMonitorLaneOutput(0, 1), isNull);
        // No saved gain → the lane defaults to unity (1.0), not silence.
        expect(await settings.loadMonitorLaneVolume(0, 0), 1.0);
      });

      test('the highest scanned input (kMaxInputs-1) is migrated', () async {
        await settings.saveMonitorInput(
          kMaxInputs - 1,
          enabled: true,
          outputMask: 0x1,
        );

        await runMonitorMigration(settings);

        expect(
          await settings.loadMonitorInputEnabled(kMaxInputs - 1),
          isTrue,
        );
        expect(await settings.loadMonitorLaneOutput(kMaxInputs - 1, 0), 0x1);
      });

      test(
        'a second run is a no-op once the v2 flag is set (idempotent)',
        () async {
          await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);
          await runMonitorMigration(settings);
          // Simulate a later user edit to the lane keys.
          await settings.saveMonitorLaneOutput(0, 0, 0x4);

          await runMonitorMigration(settings);

          // The second run did not re-convert (no legacy key to read) and did
          // not clobber the user's edit.
          expect(await settings.loadMonitorLaneOutput(0, 0), 0x4);
        },
      );

      test(
        'a store on v1 but not v2 still converts on the next launch',
        () async {
          // A device that shipped with v1 (its done-flag set, the legacy
          // per-input key already written) but has never run v2. The next
          // launch must skip v1 and still fold the legacy route into lanes.
          await settings.saveMonitorMigratedV1();
          await settings.saveMonitorInput(0, enabled: true, outputMask: 0x2);

          await runMonitorMigration(settings);

          expect(await settings.loadMonitorInputEnabled(0), isTrue);
          expect(await settings.loadMonitorLaneOutput(0, 0), 0x2);
          expect(await settings.loadMonitorInput(0), isNull); // legacy cleared
          expect(await settings.loadMonitorMigratedV2(), isTrue);
        },
      );

      test('a store already on v2 skips conversion entirely', () async {
        await settings.saveMonitorMigratedV2();
        // A stray legacy key must NOT be converted once v2 is marked done.
        await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(0), isNull);
        expect(await settings.loadMonitorInput(0), (true, 0x1)); // untouched
      });
    });
  });
}
