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
      () => repository.setMonitorOutput(
        input: any(named: 'input'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorVolume(
        input: any(named: 'input'),
        volume: any(named: 'volume'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorMute(
        input: any(named: 'input'),
        muted: any(named: 'muted'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorChainEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
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
    when(
      () => repository.openMonitorPluginEditor(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.closeMonitorPluginEditor(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.refreshMonitorPluginParams(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(false);
    when(
      () => repository.isMonitorPluginEditorOpen(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(true);
    when(() => repository.monitorEffects(any())).thenReturn(const []);
  });

  MonitorCubit build() =>
      MonitorCubit(repository: repository, settings: settings);

  group('MonitorCubit', () {
    test('defaults to no configured inputs (disabled, clean chain)', () {
      final cubit = build();
      expect(cubit.state.inputs, isEmpty);
      expect(cubit.state.forInput(0).enabled, isFalse);
      expect(cubit.state.forInput(0).outputMask, 0x3);
      expect(cubit.state.forInput(0).volume, 1.0);
      expect(cubit.state.forInput(0).effects, isEmpty);
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
      'setOutputMask updates, applies, and persists the chain output mask',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(1, enabled: true);
        await cubit.setOutputMask(1, 0x2);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(1).outputMask, 0x2);
        verify(
          () => repository.setMonitorOutput(input: 1, mask: 0x2),
        ).called(1);
        expect(await settings.loadMonitorOutput(1), 0x2);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setVolume updates, applies, and persists the gain',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.setVolume(0, 0.5);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).volume, 0.5);
        verify(
          () => repository.setMonitorVolume(input: 0, volume: 0.5),
        ).called(1);
        expect(await settings.loadMonitorVolume(0), 0.5);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setMute mutes the input chain',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(0, enabled: true);
        await cubit.setMute(0, muted: true);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).muted, isTrue);
        verify(
          () => repository.setMonitorMute(input: 0, muted: true),
        ).called(1);
        expect(await settings.loadMonitorMute(0), isTrue);
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
      'load restores a chain-DISABLED envelope and pushes the flag '
      '(R15/D-CHAINDIS)',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            FxChainEnvelope(
              chainEnabled: false,
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          ),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.chainEnabled, isFalse);
        expect(monitor.effects, hasLength(1));
        verify(
          () => repository.setMonitorChainEnabled(input: 0, enabled: false),
        ).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a chain-DISABLED envelope with EMPTY entries still counts as saved '
      'state — the flag survives the restart (R15)',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(const FxChainEnvelope(chainEnabled: false)),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.inputs, contains(0));
        expect(cubit.state.forInput(0).chainEnabled, isFalse);
        verify(
          () => repository.setMonitorChainEnabled(input: 0, enabled: false),
        ).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a persisted chain re-encodes as the envelope carrying the chain flag',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            FxChainEnvelope(
              chainEnabled: false,
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          ),
        );
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        // A param tweak re-persists the chain; the disabled flag must ride.
        cubit.setEffectParam(0, 0, 0, 0.9);
      },
      verify: (cubit) async {
        final decoded = decodeFxChain(await settings.loadMonitorEffects(0));
        expect(decoded.chainEnabled, isFalse);
        expect(
          ((decoded.entries.single) as BuiltInEffect).params.first,
          0.9,
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load restores single-chain state from the keys, applying it',
      setUp: () async {
        await settings.saveMonitorInputEnabled(0, enabled: true);
        await settings.saveMonitorOutput(0, 0x2);
        await settings.saveMonitorVolume(0, 0.4);
        await settings.saveMonitorMute(0, muted: true);
        await settings.saveMonitorEffects(
          0,
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.enabled, isTrue);
        expect(monitor.outputMask, 0x2);
        expect(monitor.volume, 0.4);
        expect(monitor.muted, isTrue);
        expect(
          (monitor.effects.single as BuiltInEffect).type,
          TrackEffectType.delay,
        );
        verify(
          () => repository.setMonitorInputEnabled(input: 0, enabled: true),
        ).called(1);
        verify(
          () => repository.setMonitorOutput(input: 0, mask: 0x2),
        ).called(1);
        verify(
          () => repository.setMonitorVolume(input: 0, volume: 0.4),
        ).called(1);
        verify(
          () => repository.setMonitorMute(input: 0, muted: true),
        ).called(1);
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
          ),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    group('syncFromRepository', () {
      blocTest<MonitorCubit, MonitorState>(
        're-projects the repository monitors into state and persists them',
        setUp: () {
          when(repository.allMonitors).thenReturn({
            2: InputMonitor(
              input: 2,
              enabled: true,
              outputMask: 0x2,
              volume: 0.4,
              muted: true,
              effects: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          });
        },
        build: build,
        act: (cubit) => cubit.syncFromRepository(),
        verify: (cubit) async {
          final monitor = cubit.state.forInput(2);
          expect(monitor.enabled, isTrue);
          expect(monitor.outputMask, 0x2);
          expect(monitor.volume, 0.4);
          expect(monitor.muted, isTrue);
          expect(
            (monitor.effects.single as BuiltInEffect).type,
            TrackEffectType.delay,
          );
          // All five fields are persisted, so the next boot restores THIS set.
          expect(await settings.loadMonitorInputEnabled(2), isTrue);
          expect(await settings.loadMonitorOutput(2), 0x2);
          expect(await settings.loadMonitorVolume(2), 0.4);
          expect(await settings.loadMonitorMute(2), isTrue);
          expect(await settings.loadMonitorEffects(2), isNotNull);
          // The load already applied to the engine; the re-sync only READS the
          // repository — it must never push back, or it could desync the two.
          verifyNever(
            () => repository.setMonitorInputEnabled(
              input: any(named: 'input'),
              enabled: any(named: 'enabled'),
            ),
          );
          verifyNever(
            () => repository.setMonitorOutput(
              input: any(named: 'input'),
              mask: any(named: 'mask'),
            ),
          );
          verifyNever(
            () => repository.setMonitorVolume(
              input: any(named: 'input'),
              volume: any(named: 'volume'),
            ),
          );
          verifyNever(
            () => repository.setMonitorMute(
              input: any(named: 'input'),
              muted: any(named: 'muted'),
            ),
          );
          verifyNever(
            () => repository.setMonitorEffects(
              input: any(named: 'input'),
              effects: any(named: 'effects'),
            ),
          );
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'resets ALL persisted fields for inputs dropped since the last state',
        setUp: () async {
          // A prior session left input 5 configured (enabled + non-default
          // routing / volume / mute) in settings AND cubit state.
          await settings.saveMonitorInputEnabled(5, enabled: true);
          await settings.saveMonitorOutput(5, 0x2);
          await settings.saveMonitorVolume(5, 0.3);
          await settings.saveMonitorMute(5, muted: true);
          await settings.saveMonitorEffects(
            5,
            encodeTrackEffects([BuiltInEffect(type: TrackEffectType.reverb)]),
          );
          // The freshly loaded session defines no monitors.
          when(repository.allMonitors).thenReturn(const {});
        },
        build: build,
        // Seed input 5 into state so it counts as "previously present".
        act: (cubit) async {
          await cubit.setEnabled(5, enabled: true);
          await cubit.syncFromRepository();
        },
        verify: (cubit) async {
          expect(cubit.state.inputs, isEmpty);
          // Every field is reset to the disabled default — no lingering
          // outputMask / volume / mute to resurrect the monitor on next boot.
          expect(await settings.loadMonitorInputEnabled(5), isFalse);
          expect(await settings.loadMonitorOutput(5), 0x3);
          expect(await settings.loadMonitorVolume(5), 1.0);
          expect(await settings.loadMonitorMute(5), isFalse);
          expect(
            await settings.loadMonitorEffects(5),
            encodeFxChain(const FxChainEnvelope()),
          );
        },
      );
    });

    group('monitor power controls (D-POWER)', () {
      blocTest<MonitorCubit, MonitorState>(
        'setEffectEnabled flips one slot, pushes it, and re-persists',
        setUp: () {
          // Model the repository: it owns the flag flip across the sealed
          // entry hierarchy, and the cubit re-reads what actually landed.
          var chain = <TrackEffect>[];
          when(() => repository.monitorEffects(0)).thenAnswer((_) => chain);
          when(
            () => repository.setMonitorEffects(
              input: any(named: 'input'),
              effects: any(named: 'effects'),
            ),
          ).thenAnswer((invocation) {
            chain = invocation.namedArguments[#effects] as List<TrackEffect>;
            return EngineResult.ok;
          });
          when(
            () => repository.setMonitorEffectEnabled(
              input: any(named: 'input'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          ).thenAnswer((invocation) {
            final index = invocation.namedArguments[#index] as int;
            final enabled = invocation.namedArguments[#enabled] as bool;
            final fx = chain[index] as BuiltInEffect;
            chain = [...chain]..[index] = fx.copyWith(enabled: enabled);
            return EngineResult.ok;
          });
        },
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectEnabled(0, 0, enabled: false);
        },
        verify: (_) async {
          verify(
            () => repository.setMonitorEffectEnabled(
              input: 0,
              index: 0,
              enabled: false,
            ),
          ).called(1);
          // The flag rides the persisted envelope, not just "something wrote".
          final encoded = await settings.loadMonitorEffects(0);
          expect(decodeFxChain(encoded).entries.single.enabled, isFalse);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectEnabled ignores an out-of-range slot',
        build: build,
        act: (cubit) => cubit.setEffectEnabled(0, 3, enabled: false),
        expect: () => <MonitorState>[],
        verify: (_) {
          verifyNever(
            () => repository.setMonitorEffectEnabled(
              input: any(named: 'input'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          );
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setChainEnabled flips the whole chain and persists the envelope',
        build: build,
        act: (cubit) => cubit.setChainEnabled(0, enabled: false),
        expect: () => [
          isA<MonitorState>().having(
            (s) => s.forInput(0).chainEnabled,
            'chainEnabled',
            isFalse,
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorChainEnabled(input: 0, enabled: false),
          ).called(1);
          // R15: the flag rides the one monitor-fx key beside the entries.
          final encoded = await settings.loadMonitorEffects(0);
          expect(decodeFxChain(encoded).chainEnabled, isFalse);
        },
      );
    });

    group('monitor effects', () {
      blocTest<MonitorCubit, MonitorState>(
        'addEffect appends a default drive, applies, and persists',
        build: build,
        act: (cubit) => cubit.addEffect(0),
        expect: () => [
          isA<MonitorState>().having(
            (s) => (s.forInput(0).effects.single as BuiltInEffect).type,
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
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectParam tweaks an entry without a structural reset',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectParam(0, 0, 0, 0.9);
        },
        verify: (cubit) {
          expect(
            (cubit.state.forInput(0).effects.single as BuiltInEffect).params[0],
            0.9,
          );
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
        'setPluginParam routes a plain value by plugin param id and persists',
        setUp: () async {
          when(
            () => repository.setMonitorPluginParam(
              input: any(named: 'input'),
              index: any(named: 'index'),
              paramId: any(named: 'paramId'),
              value: any(named: 'value'),
            ),
          ).thenReturn(EngineResult.ok);
          // Seed a monitor chain with a single plugin entry, then restore it.
          await settings.saveMonitorEffects(
            0,
            encodeTrackEffects(const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              ),
            ]),
          );
        },
        build: build,
        act: (cubit) async {
          await cubit.load();
          cubit.setPluginParam(0, 0, 100, 0.7);
        },
        verify: (cubit) async {
          final fx = cubit.state.forInput(0).effects.single as PluginEffect;
          expect(fx.paramValues[100], 0.7);
          verify(
            () => repository.setMonitorPluginParam(
              input: 0,
              index: 0,
              paramId: 100,
              value: 0.7,
            ),
          ).called(1);
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'insertPlugin appends a PluginEffect, applies, and persists',
        build: build,
        act: (cubit) => cubit.insertPlugin(
          0,
          const PluginRef(format: PluginFormat.vst3, id: 'TUID-HEX'),
        ),
        expect: () => [
          isA<MonitorState>().having(
            (s) => s.forInput(0).effects.single,
            'inserted effect',
            isA<PluginEffect>().having((e) => e.ref.id, 'ref.id', 'TUID-HEX'),
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
            ),
          ).called(1);
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'openPluginEditor opens the editor and starts the sync poll',
        build: build,
        act: (cubit) => cubit.openPluginEditor(0, 0),
        wait: const Duration(milliseconds: 250),
        verify: (_) {
          verify(
            () => repository.openMonitorPluginEditor(input: 0, index: 0),
          ).called(1);
          verify(
            () => repository.refreshMonitorPluginParams(input: 0, index: 0),
          ).called(greaterThanOrEqualTo(1));
        },
      );

      test('closePluginEditor closes the editor and stops the poll', () async {
        var refreshCount = 0;
        when(
          () => repository.refreshMonitorPluginParams(
            input: any(named: 'input'),
            index: any(named: 'index'),
          ),
        ).thenAnswer((_) {
          refreshCount++;
          return false;
        });
        final cubit = build()..openPluginEditor(0, 0);
        addTearDown(cubit.close);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(refreshCount, greaterThanOrEqualTo(1));
        cubit.closePluginEditor(0, 0);
        verify(
          () => repository.closeMonitorPluginEditor(input: 0, index: 0),
        ).called(1);
        // The poll stops climbing once the editor closes.
        final after = refreshCount;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(refreshCount, after);
      });

      blocTest<MonitorCubit, MonitorState>(
        'removeEffect drops an entry (back to the clean path)',
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
            cubit.state
                .forInput(0)
                .effects
                .map((e) => (e as BuiltInEffect).type),
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
