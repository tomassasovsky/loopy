import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;

  setUpAll(() => registerFallbackValue(<TrackEffect>[]));

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(
      () => repository.setMonitorInputEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneCount(
        input: any(named: 'input'),
        count: any(named: 'count'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneOutput(
        input: any(named: 'input'),
        lane: any(named: 'lane'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneVolume(
        input: any(named: 'input'),
        lane: any(named: 'lane'),
        volume: any(named: 'volume'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneMute(
        input: any(named: 'input'),
        lane: any(named: 'lane'),
        muted: any(named: 'muted'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneEffects(
        input: any(named: 'input'),
        lane: any(named: 'lane'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorLaneEffectParam(
        input: any(named: 'input'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  MonitorCubit build() =>
      MonitorCubit(repository: repository, settings: settings);

  group('MonitorCubit', () {
    test('defaults to no configured inputs (disabled, one default lane)', () {
      final cubit = build();
      expect(cubit.state.inputs, isEmpty);
      expect(cubit.state.forInput(0).enabled, isFalse);
      expect(cubit.state.forInput(0).laneCount, 1);
      expect(cubit.state.forInput(0).lane(0).outputMask, 0x3);
      expect(cubit.state.forInput(0).lane(0).volume, 1.0);
    });

    blocTest<MonitorCubit, MonitorState>(
      'setEnabled enables an input, applies it, and persists',
      build: build,
      act: (cubit) => cubit.setEnabled(0, enabled: true),
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.forInput(0).enabled,
          'enabled',
          isTrue,
        ),
      ],
      verify: (_) async {
        verify(
          () => repository.setMonitorInputEnabled(input: 0, enabled: true),
        ).called(1);
        expect(await settings.loadMonitorInputEnabled(0), isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setLaneOutputMask updates and persists a per-lane output mask',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(1, enabled: true);
        await cubit.setLaneOutputMask(1, 0, 0x2);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(1).lane(0).outputMask, 0x2);
        verify(
          () => repository.setMonitorLaneOutput(input: 1, lane: 0, mask: 0x2),
        ).called(1);
        expect(await settings.loadMonitorLaneOutput(1, 0), 0x2);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setLaneVolume updates, applies, and persists the lane gain',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.setLaneVolume(0, 0, 0.5);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).lane(0).volume, 0.5);
        verify(
          () => repository.setMonitorLaneVolume(input: 0, lane: 0, volume: 0.5),
        ).called(1);
        expect(await settings.loadMonitorLaneVolume(0, 0), 0.5);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setLaneMute mutes only the addressed lane',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.addLane(0);
        await cubit.setLaneMute(0, 1, muted: true);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).lane(0).muted, isFalse);
        expect(cubit.state.forInput(0).lane(1).muted, isTrue);
        verify(
          () => repository.setMonitorLaneMute(input: 0, lane: 1, muted: true),
        ).called(1);
        expect(await settings.loadMonitorLaneMute(0, 1), isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'addLane appends a default (clean) lane and persists the count',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.addLane(0);
      },
      verify: (cubit) async {
        final monitor = cubit.state.forInput(0);
        expect(monitor.laneCount, 2);
        expect(monitor.lane(1).effects, isEmpty); // a clean (dry) lane
        verify(
          () => repository.setMonitorLaneCount(input: 0, count: 2),
        ).called(1);
        expect(await settings.loadMonitorLaneCount(0), 2);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'removeLane drops a lane and collapses the rest',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.addLane(0);
        await cubit.setLaneOutputMask(0, 1, 0x2);
        await cubit.removeLane(0, 0);
      },
      verify: (cubit) async {
        final monitor = cubit.state.forInput(0);
        expect(monitor.laneCount, 1);
        // The surviving lane is the old lane 1 (its 0x2 mask carried over).
        expect(monitor.lane(0).outputMask, 0x2);
        expect(await settings.loadMonitorLaneCount(0), 1);
        // The collapse re-dispatches the re-indexed lane to the engine: the
        // carried-over 0x2 mask now lands on lane 0 (it never did before).
        verify(
          () => repository.setMonitorLaneOutput(input: 0, lane: 0, mask: 0x2),
        ).called(1);
        verify(
          () => repository.setMonitorLaneCount(input: 0, count: 1),
        ).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'addLane is a no-op once the lane cap (kMaxLanes) is reached',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        for (var i = 1; i < kMaxLanes; i++) {
          await cubit.addLane(0);
        }
        expect(cubit.state.forInput(0).laneCount, kMaxLanes);
        await cubit.addLane(0); // one past the cap
      },
      verify: (cubit) {
        expect(cubit.state.forInput(0).laneCount, kMaxLanes);
        // The cap-blocked call never pushed a count of kMaxLanes + 1.
        verifyNever(
          () => repository.setMonitorLaneCount(
            input: 0,
            count: kMaxLanes + 1,
          ),
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'removeLane is a no-op on the last lane',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.removeLane(0, 0);
      },
      verify: (cubit) => expect(cubit.state.forInput(0).laneCount, 1),
    );

    blocTest<MonitorCubit, MonitorState>(
      'inputs are independent of one another',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.setEnabled(1, enabled: true);
        await cubit.setEnabled(0, enabled: false);
      },
      verify: (cubit) {
        expect(cubit.state.forInput(0).enabled, isFalse);
        expect(cubit.state.forInput(1).enabled, isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load restores per-(input, lane) state from the new keys, applying it',
      setUp: () async {
        await settings.saveMonitorInputEnabled(0, enabled: true);
        await settings.saveMonitorLaneCount(0, 2);
        await settings.saveMonitorLaneOutput(0, 0, 0x2);
        await settings.saveMonitorLaneVolume(0, 0, 0.4);
        await settings.saveMonitorLaneEffects(
          0,
          0,
          encodeTrackEffects([TrackEffect(type: TrackEffectType.delay)]),
        );
        // Lane 1 is a no-FX clean (dry) lane routed to out 1.
        await settings.saveMonitorLaneOutput(0, 1, 0x1);
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.enabled, isTrue);
        expect(monitor.laneCount, 2);
        expect(monitor.lane(0).outputMask, 0x2);
        expect(monitor.lane(0).volume, 0.4);
        expect(monitor.lane(0).effects.single.type, TrackEffectType.delay);
        // The clean (dry) lane: routed, no effects.
        expect(monitor.lane(1).outputMask, 0x1);
        expect(monitor.lane(1).effects, isEmpty);
        verify(
          () => repository.setMonitorInputEnabled(input: 0, enabled: true),
        ).called(1);
        verify(
          () => repository.setMonitorLaneCount(input: 0, count: 2),
        ).called(1);
        verify(
          () => repository.setMonitorLaneOutput(input: 0, lane: 0, mask: 0x2),
        ).called(1);
        verify(
          () => repository.setMonitorLaneVolume(input: 0, lane: 0, volume: 0.4),
        ).called(1);
        verify(
          () => repository.setMonitorLaneEffects(
            input: 0,
            lane: 0,
            effects: any(named: 'effects'),
          ),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    group('per-lane monitor effects', () {
      blocTest<MonitorCubit, MonitorState>(
        'addEffect appends a default drive to a lane, applies, and persists',
        build: build,
        act: (cubit) => cubit.addEffect(0, 0),
        expect: () => [
          isA<MonitorState>().having(
            (s) => s.forInput(0).lane(0).effects.single.type,
            'type',
            TrackEffectType.drive,
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorLaneEffects(
              input: 0,
              lane: 0,
              effects: any(named: 'effects'),
            ),
          ).called(1);
          expect(await settings.loadMonitorLaneEffects(0, 0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectParam tweaks a lane entry without a structural reset',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, 0)
            ..setEffectParam(0, 0, 0, 0, 0.9);
        },
        verify: (cubit) {
          expect(
            cubit.state.forInput(0).lane(0).effects.single.params[0],
            0.9,
          );
          verify(
            () => repository.setMonitorLaneEffectParam(
              input: 0,
              lane: 0,
              index: 0,
              param: 0,
              value: 0.9,
            ),
          ).called(1);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'removeEffect drops a lane entry (back to the clean path)',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, 0)
            ..removeEffect(0, 0, 0);
        },
        verify: (cubit) =>
            expect(cubit.state.forInput(0).lane(0).effects, isEmpty),
      );

      blocTest<MonitorCubit, MonitorState>(
        'moveEffect reorders a lane chain and persists it',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, 0)
            ..setEffectType(0, 0, 0, TrackEffectType.drive)
            ..addEffect(0, 0)
            ..setEffectType(0, 0, 1, TrackEffectType.delay)
            ..moveEffect(0, 0, 0, 1); // drive moves after delay
        },
        verify: (cubit) async {
          expect(
            cubit.state.forInput(0).lane(0).effects.map((e) => e.type),
            [TrackEffectType.delay, TrackEffectType.drive],
          );
          verify(
            () => repository.setMonitorLaneEffects(
              input: 0,
              lane: 0,
              effects: any(named: 'effects'),
            ),
          ).called(greaterThanOrEqualTo(1));
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'moveEffect ignores out-of-range and no-op moves',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, 0)
            ..moveEffect(0, 0, 5, 0) // from out of range
            ..moveEffect(0, 0, 0, 0); // no-op
        },
        verify: (cubit) =>
            expect(cubit.state.forInput(0).lane(0).effects, hasLength(1)),
      );
    });
  });
}
