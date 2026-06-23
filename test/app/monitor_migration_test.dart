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

    // The full migration runs v1 → v2 → v3, so its end state is always the
    // single-chain model: enable + one output mask + volume + mute + one chain.
    group('v1 (global flag) → v2 (lanes) → v3 (single chain)', () {
      test(
        'legacy flag on + no saved routes ends as input 0 → main out, clean',
        () async {
          await store.setBool('audio.monitor_input', value: true);

          await runMonitorMigration(settings);

          // v1 seeded input 0 → main out; v2 made it lane 0; v3 folded it to a
          // single clean chain and cleared the intermediate keys.
          expect(await settings.loadMonitorInputEnabled(0), isTrue);
          expect(await settings.loadMonitorOutput(0), 0x3);
          expect(await settings.loadMonitorEffects(0), isNull);
          expect(await settings.loadMonitorLaneCount(0), isNull); // cleared
          expect(await settings.loadMonitorInput(0), isNull); // legacy cleared
          expect(await settings.loadMonitorMigratedV1(), isTrue);
          expect(await settings.loadMonitorMigratedV2(), isTrue);
          expect(await settings.loadMonitorMigratedV3(), isTrue);
        },
      );

      test('legacy flag off enables no monitoring', () async {
        await store.setBool('audio.monitor_input', value: false);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(0), isNull);
        expect(await settings.loadMonitorMigratedV3(), isTrue);
      });

      test('a fresh install marks all three migrations done', () async {
        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(0), isNull);
        expect(await settings.loadMonitorMigratedV1(), isTrue);
        expect(await settings.loadMonitorMigratedV2(), isTrue);
        expect(await settings.loadMonitorMigratedV3(), isTrue);
      });

      test('a wet-only legacy route folds to a single chain', () async {
        await settings.saveMonitorInput(1, enabled: true, outputMask: 0x2);
        await store.setDouble('monitor_input_vol.1', 0.4);
        await store.setString(
          'monitor_input_fx.1',
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
        );

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(1), isTrue);
        expect(await settings.loadMonitorOutput(1), 0x2);
        expect(await settings.loadMonitorVolume(1), 0.4);
        expect(
          await settings.loadMonitorEffects(1),
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
        );
        expect(await settings.loadMonitorInput(1), isNull); // legacy cleared
        expect(await settings.loadMonitorLaneCount(1), isNull); // lanes cleared
      });

      test(
        'a wet + dry legacy route unions both masks into one chain',
        () async {
          // Effected route to out 0, parallel dry send to out 1, gain 0.5.
          await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);
          await store.setInt('monitor_input_dry.0', 0x2);
          await store.setDouble('monitor_input_vol.0', 0.5);

          await runMonitorMigration(settings);

          // v2 made lane 0 (out 0) + lane 1 (out 1); v3 OR-unions to 0x3, keeps
          // lane 0's volume, and (no FX on either) leaves a clean chain.
          expect(await settings.loadMonitorOutput(0), 0x3);
          expect(await settings.loadMonitorVolume(0), 0.5);
          expect(await settings.loadMonitorEffects(0), isNull);
        },
      );

      test(
        'a chained v1→v2→v3 cold upgrade preserves FX and unions masks (R3)',
        () async {
          // A cold upgrade from the oldest schema: a legacy single route with
          // an effect chain (wet to out 0) AND a parallel dry send (to out 1).
          // The
          // full v1→v2→v3 chain must keep the FX and union both masks — never
          // silently dropping the chain (R3 / F-14).
          await settings.saveMonitorInput(0, enabled: true, outputMask: 0x1);
          await store.setInt('monitor_input_dry.0', 0x2);
          await store.setDouble('monitor_input_vol.0', 0.6);
          await store.setString(
            'monitor_input_fx.0',
            encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
          );

          await runMonitorMigration(settings);

          expect(await settings.loadMonitorInputEnabled(0), isTrue);
          expect(await settings.loadMonitorOutput(0), 0x3); // 0x1 | 0x2
          expect(await settings.loadMonitorVolume(0), 0.6);
          expect(
            await settings.loadMonitorEffects(0),
            encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
          );
          // Every intermediate key is gone.
          expect(await settings.loadMonitorInput(0), isNull);
          expect(await settings.loadMonitorLaneCount(0), isNull);
          expect(await settings.loadMonitorMigratedV3(), isTrue);
        },
      );

      test('the highest scanned input (kMaxInputs-1) is migrated', () async {
        await settings.saveMonitorInput(
          kMaxInputs - 1,
          enabled: true,
          outputMask: 0x1,
        );

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorInputEnabled(kMaxInputs - 1), isTrue);
        expect(await settings.loadMonitorOutput(kMaxInputs - 1), 0x1);
      });
    });

    group('v3 (multi-lane → single chain)', () {
      // Seed a v2-migrated store (lane keys present, v2 flag set, v3 not) so
      // only the v3 fold acts when the full migration runs.
      Future<void> seedLanes(
        int input, {
        required int count,
        Map<int, int>? out,
        Map<int, double>? vol,
        Map<int, bool>? mute,
        Map<int, List<TrackEffect>>? fx,
      }) async {
        await settings.saveMonitorMigratedV1();
        await settings.saveMonitorMigratedV2();
        await settings.saveMonitorLaneCount(input, count);
        for (var lane = 0; lane < count; lane++) {
          await settings.saveMonitorLaneOutput(input, lane, out?[lane] ?? 0x3);
          if (vol?[lane] != null) {
            await settings.saveMonitorLaneVolume(input, lane, vol![lane]!);
          }
          if (mute?[lane] ?? false) {
            await store.setBool(
              'monitor_lane_mute.$input.$lane',
              value: true,
            );
          }
          if (fx?[lane] != null) {
            await settings.saveMonitorLaneEffects(
              input,
              lane,
              encodeTrackEffects(fx![lane]!),
            );
          }
        }
      }

      test(
        'M1: all-empty lanes fold to one clean chain (union masks)',
        () async {
          await seedLanes(0, count: 2, out: {0: 0x1, 1: 0x2});

          await runMonitorMigration(settings);

          expect(await settings.loadMonitorOutput(0), 0x3); // 0x1 | 0x2
          expect(await settings.loadMonitorEffects(0), isNull); // still clean
          expect(await settings.loadMonitorMigratedV3(), isTrue);
        },
      );

      test('M2: FX on a non-lane-0 lane is preserved, not dropped', () async {
        await seedLanes(
          0,
          count: 2,
          out: {0: 0x1, 1: 0x2},
          fx: {
            1: [BuiltInEffect(type: TrackEffectType.delay)],
          },
        );

        await runMonitorMigration(settings);

        // Lane 1's chain is the first (only) non-empty one — it survives.
        expect(
          await settings.loadMonitorEffects(0),
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
        );
        expect(await settings.loadMonitorOutput(0), 0x3);
      });

      test('M3: FX on both lanes keeps lane 0 (not merged)', () async {
        await seedLanes(
          0,
          count: 2,
          fx: {
            0: [BuiltInEffect(type: TrackEffectType.drive)],
            1: [BuiltInEffect(type: TrackEffectType.delay)],
          },
        );

        await runMonitorMigration(settings);

        expect(
          await settings.loadMonitorEffects(0),
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.drive)]),
        );
      });

      test('lane 0 volume and mute carry over', () async {
        await seedLanes(
          0,
          count: 2,
          vol: {0: 0.3},
          mute: {0: true},
        );

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorVolume(0), 0.3);
        expect(await settings.loadMonitorMute(0), isTrue);
      });

      test('M5: the dead multi-lane keys are cleared', () async {
        await seedLanes(0, count: 2, out: {0: 0x1, 1: 0x2});

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorLaneCount(0), isNull);
        expect(await settings.loadMonitorLaneOutput(0, 0), isNull);
        expect(await settings.loadMonitorLaneOutput(0, 1), isNull);
      });

      test('idempotent: a second run does not clobber a later edit', () async {
        await seedLanes(0, count: 1, out: {0: 0x1});
        await runMonitorMigration(settings);
        // Simulate a later user edit to the single-chain key.
        await settings.saveMonitorOutput(0, 0x4);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorOutput(0), 0x4); // untouched
      });

      test('a store already on v3 skips the fold entirely', () async {
        await settings.saveMonitorMigratedV1();
        await settings.saveMonitorMigratedV2();
        await settings.saveMonitorMigratedV3();
        // A stray lane key must NOT be folded once v3 is marked done.
        await settings.saveMonitorLaneCount(0, 2);

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorLaneCount(0), 2); // untouched
        expect(await settings.loadMonitorOutput(0), isNull); // never folded
      });

      test('an input with no lane keys is a no-op', () async {
        await settings.saveMonitorMigratedV1();
        await settings.saveMonitorMigratedV2();

        await runMonitorMigration(settings);

        expect(await settings.loadMonitorOutput(0), isNull);
        expect(await settings.loadMonitorMigratedV3(), isTrue);
      });
    });
  });
}
