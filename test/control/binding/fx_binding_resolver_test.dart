import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/binding/fx_binding_resolver.dart';
import 'package:loopy/control/binding/fx_binding_target.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

TrackEffect _fx(String slotId, {bool enabled = true}) => BuiltInEffect(
  type: TrackEffectType.drive,
  enabled: enabled,
  slotId: slotId,
);

void main() {
  late _MockLooperRepository looper;

  /// The rig the stubs below describe: input 2, lane (1,0), track 5 and the
  /// Master insert all exist; everything else is absent.
  late Map<int, List<TrackEffect>> monitorChains;
  late Map<(int, int), List<TrackEffect>> laneChains;
  late Map<int, List<TrackEffect>> trackChains;
  late List<TrackEffect> masterChain;
  late Map<String, bool> chainEnabled;

  setUp(() {
    looper = _MockLooperRepository();
    monitorChains = {
      2: [_fx('m-1')],
    };
    laneChains = {
      (1, 0): [_fx('l-1'), _fx('l-2')],
    };
    trackChains = {
      5: [_fx('t-1'), _fx('t-2'), _fx('t-3')],
      // A CONFIGURED but empty chain: its flag is real and stompable, so it
      // must resolve where an absent stage does not.
      6: <TrackEffect>[],
    };
    masterChain = [_fx('mx-1')];
    chainEnabled = {'input:2': true, 'loop:1:0': true, 'track:5': true};

    when(
      () => looper.allMonitors(),
    ).thenAnswer(
      (_) => {
        for (final input in monitorChains.keys)
          input: InputMonitor(input: input),
      },
    );
    when(() => looper.allLaneChains()).thenAnswer(
      (_) => {
        for (final key in laneChains.keys) key: const FxChainEnvelope(),
      },
    );
    when(() => looper.allTrackChains()).thenAnswer(
      (_) => {
        for (final channel in trackChains.keys)
          channel: const FxChainEnvelope(),
      },
    );

    when(
      () => looper.monitorEffects(any()),
    ).thenAnswer((i) => monitorChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.laneEffects(any(), any())).thenAnswer(
      (i) =>
          laneChains[(
            i.positionalArguments[0] as int,
            i.positionalArguments[1] as int,
          )] ??
          const [],
    );
    when(
      () => looper.trackEffects(any()),
    ).thenAnswer((i) => trackChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.masterEffects).thenAnswer((_) => masterChain);

    when(
      () => looper.monitorChainEnabled(any()),
    ).thenAnswer(
      (i) => chainEnabled['input:${i.positionalArguments[0]}'] ?? true,
    );
    when(() => looper.laneChainEnabled(any(), any())).thenAnswer(
      (i) =>
          chainEnabled['loop:${i.positionalArguments[0]}:'
              '${i.positionalArguments[1]}'] ??
          true,
    );
    when(
      () => looper.trackChainEnabled(any()),
    ).thenAnswer(
      (i) => chainEnabled['track:${i.positionalArguments[0]}'] ?? true,
    );
    when(
      () => looper.masterChainEnvelope(),
    ).thenAnswer(
      (_) => FxChainEnvelope(chainEnabled: chainEnabled['master'] ?? true),
    );

    when(
      () => looper.setTrackChainEnabled(
        channel: any(named: 'channel'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setLaneChainEnabled(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMonitorChainEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMasterChainEnabled(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setTrackEffectEnabled(
        channel: any(named: 'channel'),
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setLaneEffectEnabled(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMonitorEffectEnabled(
        input: any(named: 'input'),
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMasterEffectEnabled(
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  group('FxBindingResolver', () {
    group('chain targets', () {
      test('read the per-chain flag on every stage', () {
        chainEnabled['track:5'] = false;
        expect(
          looper.bindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.track, index: 5)),
          ),
          isFalse,
        );
        expect(
          looper.bindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.input, index: 2)),
          ),
          isTrue,
        );
        expect(
          looper.bindingEnabled(
            const FxChainTarget(
              FxAddress(stage: FxStage.loop, index: 1, lane: 0),
            ),
          ),
          isTrue,
        );
        expect(
          looper.bindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.master)),
          ),
          isTrue,
        );
      });

      test('write through to the matching domain setter', () {
        looper.setBindingEnabled(
          const FxChainTarget(FxAddress(stage: FxStage.track, index: 5)),
          enabled: false,
        );
        verify(
          () => looper.setTrackChainEnabled(channel: 5, enabled: false),
        ).called(1);
      });

      test('a CONFIGURED but empty chain still resolves — its flag is real '
          'and stompable', () {
        expect(
          looper.bindingResolves(
            const FxChainTarget(FxAddress(stage: FxStage.track, index: 6)),
          ),
          isTrue,
        );
      });
    });

    group('slot targets survive positional churn (A9)', () {
      const target = FxSlotTarget(
        address: FxAddress(stage: FxStage.track, index: 5),
        slotId: 't-3',
      );

      test('resolve by slotId, not position', () {
        looper.setBindingEnabled(target, enabled: false);
        verify(
          () => looper.setTrackEffectEnabled(
            channel: 5,
            index: 2,
            enabled: false,
          ),
        ).called(1);
      });

      test('an INSERT before the bound slot still hits the same effect', () {
        trackChains[5] = [_fx('new'), ...trackChains[5]!];
        looper.setBindingEnabled(target, enabled: false);
        // t-3 moved from index 2 to index 3; the binding followed it.
        verify(
          () => looper.setTrackEffectEnabled(
            channel: 5,
            index: 3,
            enabled: false,
          ),
        ).called(1);
      });

      test('a REORDER never retargets a neighbour', () {
        trackChains[5] = trackChains[5]!.reversed.toList();
        looper.setBindingEnabled(target, enabled: false);
        verify(
          () => looper.setTrackEffectEnabled(
            channel: 5,
            index: 0,
            enabled: false,
          ),
        ).called(1);
      });

      test('reads the slot own enabled flag, not the chain', () {
        trackChains[5] = [_fx('t-1'), _fx('t-3', enabled: false)];
        expect(looper.bindingEnabled(target), isFalse);
      });
    });

    group('unresolvable targets go inert — never retarget (A9)', () {
      test('a chain on a stage the rig has not configured', () {
        for (final address in const [
          FxAddress(stage: FxStage.track, index: 7),
          FxAddress(stage: FxStage.input),
          FxAddress(stage: FxStage.loop, index: 3, lane: 0),
        ]) {
          expect(looper.bindingEnabled(FxChainTarget(address)), isNull);
          expect(looper.bindingResolves(FxChainTarget(address)), isFalse);
        }
      });

      test('a slotId no longer in the chain — it does NOT fall back to the '
          'chain or to whatever now sits at the old position', () {
        const gone = FxSlotTarget(
          address: FxAddress(stage: FxStage.track, index: 5),
          slotId: 'deleted',
        );
        expect(looper.bindingEnabled(gone), isNull);

        expect(looper.setBindingEnabled(gone, enabled: false), isFalse);
        verifyNever(
          () => looper.setTrackEffectEnabled(
            channel: any(named: 'channel'),
            index: any(named: 'index'),
            enabled: any(named: 'enabled'),
          ),
        );
        verifyNever(
          () => looper.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        );
      });

      test('a Loop address with NO lane — every lane owns a chain, so a '
          'lane-less address names none; coercing it to lane 0 would act on '
          'a chain the user never bound', () {
        const laneless = FxChainTarget(
          FxAddress(stage: FxStage.loop, index: 1),
        );
        expect(looper.bindingEnabled(laneless), isNull);
        expect(looper.setBindingEnabled(laneless, enabled: false), isFalse);
        verifyNever(
          () => looper.setLaneChainEnabled(
            channel: any(named: 'channel'),
            lane: any(named: 'lane'),
            enabled: any(named: 'enabled'),
          ),
        );
      });

      test('a negative index, and a non-zero Master index', () {
        expect(
          looper.bindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.track, index: -1)),
          ),
          isNull,
        );
        expect(
          looper.bindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.master, index: 1)),
          ),
          isNull,
        );
      });

      test('a write to an unresolvable target reports that nothing landed', () {
        expect(
          looper.setBindingEnabled(
            const FxChainTarget(FxAddress(stage: FxStage.track, index: 7)),
            enabled: false,
          ),
          isFalse,
        );
      });
    });

    test('a write that matches the current value is a no-op, so a stomp over '
        'an already-bypassed chain costs no engine call', () {
      chainEnabled['track:5'] = false;
      expect(
        looper.setBindingEnabled(
          const FxChainTarget(FxAddress(stage: FxStage.track, index: 5)),
          enabled: false,
        ),
        isFalse,
      );
      verifyNever(
        () => looper.setTrackChainEnabled(
          channel: any(named: 'channel'),
          enabled: any(named: 'enabled'),
        ),
      );
    });
  });
}
