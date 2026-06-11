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
      () => repository.setMonitorInput(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
        outputMask: any(named: 'outputMask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorDry(
        input: any(named: 'input'),
        dryOutputMask: any(named: 'dryOutputMask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorEffectParam(
        input: any(named: 'input'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  MonitorCubit build() =>
      MonitorCubit(repository: repository, settings: settings);

  group('MonitorCubit', () {
    test('defaults to no configured inputs (disabled)', () {
      final cubit = build();
      expect(cubit.state.inputs, isEmpty);
      expect(cubit.state.forInput(0).enabled, isFalse);
      expect(cubit.state.forInput(0).outputMask, 0x3);
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
          () => repository.setMonitorInput(
            input: 0,
            enabled: true,
            outputMask: 0x3,
          ),
        ).called(1);
        expect(await settings.loadMonitorInput(0), (true, 0x3));
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setOutputMask updates and persists a per-input output mask',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(1, enabled: true);
        await cubit.setOutputMask(1, 0x2);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(1).outputMask, 0x2);
        verify(
          () => repository.setMonitorInput(
            input: 1,
            enabled: true,
            outputMask: 0x2,
          ),
        ).called(1);
        expect(await settings.loadMonitorInput(1), (true, 0x2));
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setDryOutputMask updates, applies, and persists the dry send',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.setDryOutputMask(0, 0x2);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).dryOutputMask, 0x2);
        verify(
          () => repository.setMonitorDry(input: 0, dryOutputMask: 0x2),
        ).called(greaterThanOrEqualTo(1));
        expect(await settings.loadMonitorInputDry(0), 0x2);
      },
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
      'load restores per-input routing, dry send and effects, applying them',
      setUp: () async {
        await settings.saveMonitorInput(0, enabled: true, outputMask: 0x2);
        await settings.saveMonitorInputDry(0, 0x1);
        await settings.saveMonitorInputEffects(
          0,
          encodeTrackEffects([TrackEffect(type: TrackEffectType.delay)]),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.enabled, isTrue);
        expect(monitor.outputMask, 0x2);
        expect(monitor.dryOutputMask, 0x1);
        expect(monitor.effects.single.type, TrackEffectType.delay);
        verify(
          () => repository.setMonitorInput(
            input: 0,
            enabled: true,
            outputMask: 0x2,
          ),
        ).called(1);
        verify(
          () => repository.setMonitorDry(input: 0, dryOutputMask: 0x1),
        ).called(1);
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
          ),
        ).called(1);
      },
    );

    group('per-input monitor effects', () {
      blocTest<MonitorCubit, MonitorState>(
        'addEffect appends a default drive, applies it, and persists',
        build: build,
        act: (cubit) => cubit.addEffect(0),
        expect: () => [
          isA<MonitorState>().having(
            (s) => s.forInput(0).effects.single.type,
            'type',
            TrackEffectType.drive,
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
            ),
          ).called(1);
          expect(await settings.loadMonitorInputEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectParam tweaks the entry without a structural reset',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectParam(0, 0, 0, 0.9);
        },
        verify: (cubit) {
          expect(cubit.state.forInput(0).effects.single.params[0], 0.9);
          verify(
            () => repository.setMonitorEffectParam(
              input: 0,
              index: 0,
              param: 0,
              value: 0.9,
            ),
          ).called(1);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'removeEffect drops the entry',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..removeEffect(0, 0);
        },
        verify: (cubit) => expect(cubit.state.forInput(0).effects, isEmpty),
      );

      blocTest<MonitorCubit, MonitorState>(
        'moveEffect reorders the chain and persists it',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectType(0, 0, TrackEffectType.drive)
            ..addEffect(0)
            ..setEffectType(0, 1, TrackEffectType.delay)
            ..moveEffect(0, 0, 1); // drive moves after delay
        },
        verify: (cubit) async {
          expect(
            cubit.state.forInput(0).effects.map((e) => e.type),
            [TrackEffectType.delay, TrackEffectType.drive],
          );
          verify(
            () => repository.setMonitorEffects(
              input: 0,
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
            ..addEffect(0)
            ..moveEffect(0, 5, 0) // from out of range
            ..moveEffect(0, 0, 0); // no-op
        },
        verify: (cubit) =>
            expect(cubit.state.forInput(0).effects, hasLength(1)),
      );
    });
  });
}
