import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _drive(String slotId, {List<double>? params}) => BuiltInEffect(
  type: TrackEffectType.drive,
  slotId: slotId,
  params: params,
);

void main() {
  late _MockLooperRepository looper;
  late Map<int, List<TrackEffect>> monitorChains;
  late Map<(int, int), List<TrackEffect>> laneChains;
  late Map<int, List<TrackEffect>> trackChains;
  late List<TrackEffect> masterChain;
  late List<Track> tracks;

  setUp(() {
    looper = _MockLooperRepository();
    monitorChains = {
      2: [_drive('m-1')],
    };
    laneChains = {
      (1, 0): [
        _drive('l-1', params: [0.1, 0.2, 0.3, 0.4]),
      ],
    };
    trackChains = {
      5: [
        // A hosted plugin offers no continuous targets in v1.
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          slotId: 'plug-1',
        ),
        _drive('t-1'),
      ],
    };
    masterChain = [_drive('mx-1')];
    tracks = [
      const Track(volume: 0.5),
      const Track(channel: 1),
    ];

    when(() => looper.allMonitors()).thenAnswer(
      (_) => {
        for (final input in monitorChains.keys)
          input: InputMonitor(input: input),
      },
    );
    when(() => looper.allLaneChains()).thenAnswer(
      (_) => {for (final key in laneChains.keys) key: const FxChainEnvelope()},
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
    when(() => looper.state).thenAnswer((_) => LooperState(tracks: tracks));

    when(
      () => looper.setLaneEffectParam(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setTrackEffectParam(
        channel: any(named: 'channel'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMonitorEffectParam(
        input: any(named: 'input'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setMasterEffectParam(
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
  });

  const laneParam = FxParamTarget(
    address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
    slotId: 'l-1',
    // Drive's second descriptor ("Level") — the effect type's OWN parameter
    // list is what bounds a target, not the raw value array.
    param: 1,
  );

  group('availableValueTargets', () {
    test('offers every built-in param, the track volumes, and master gain', () {
      final targets = looper.availableValueTargets();

      expect(
        targets.whereType<FxParamTarget>().where((t) => t.slotId == 'l-1'),
        hasLength(TrackEffectType.drive.params.length),
      );
      expect(targets.whereType<TrackVolumeTarget>().map((t) => t.channel), [
        0,
        1,
      ]);
      expect(targets.whereType<MasterGainTarget>(), hasLength(1));
    });

    test('never offers a hosted plugin slot', () {
      final targets = looper.availableValueTargets().whereType<FxParamTarget>();

      expect(targets.where((t) => t.slotId == 'plug-1'), isEmpty);
    });

    test('never offers a slot with no stable id (A9)', () {
      trackChains[5] = [BuiltInEffect(type: TrackEffectType.filter)];

      expect(
        looper.availableValueTargets().whereType<FxParamTarget>().where(
          (t) => t.address.stage == FxStage.track,
        ),
        isEmpty,
      );
    });
  });

  group('resolution', () {
    test('the rig-level targets always resolve', () {
      expect(looper.valueTargetResolves(const MasterGainTarget()), isTrue);
      expect(looper.valueTargetResolves(const TrackVolumeTarget(0)), isTrue);
    });

    test('a live FX param resolves', () {
      expect(looper.valueTargetResolves(laneParam), isTrue);
    });

    test('a target whose slot is gone goes inert — it never retargets', () {
      laneChains[(1, 0)] = [_drive('l-9')];

      expect(looper.valueTargetResolves(laneParam), isFalse);
      expect(looper.writeValueTarget(laneParam, 0.8), isFalse);
      verifyNever(
        () => looper.setLaneEffectParam(
          channel: any(named: 'channel'),
          lane: any(named: 'lane'),
          index: any(named: 'index'),
          param: any(named: 'param'),
          value: any(named: 'value'),
        ),
      );
    });

    test('a lane-less Loop address never coerces onto lane 0', () {
      const laneless = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1),
        slotId: 'l-1',
        param: 0,
      );

      expect(looper.valueTargetResolves(laneless), isFalse);
    });

    test('a param index past the effect type goes inert', () {
      const past = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        slotId: 'l-1',
        param: 99,
      );

      expect(looper.valueTargetResolves(past), isFalse);
    });

    test('a plugin slot goes inert rather than writing by position', () {
      const plugin = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 5),
        slotId: 'plug-1',
        param: 0,
      );

      expect(looper.writeValueTarget(plugin, 0.5), isFalse);
    });
  });

  group('writes', () {
    test('an FX param writes at the slot CURRENT position', () {
      // The bound slot moved to index 1 — the write must follow the id.
      laneChains[(1, 0)] = [_drive('l-9'), _drive('l-1')];

      expect(looper.writeValueTarget(laneParam, 0.75), isTrue);
      verify(
        () => looper.setLaneEffectParam(
          channel: 1,
          lane: 0,
          index: 1,
          param: 1,
          value: 0.75,
        ),
      ).called(1);
    });

    test('track volume and master gain write through their own setters', () {
      expect(looper.writeValueTarget(const TrackVolumeTarget(1), 0.4), isTrue);
      expect(looper.writeValueTarget(const MasterGainTarget(), 0.9), isTrue);

      verify(() => looper.setVolume(0.4, channel: 1)).called(1);
      verify(() => looper.setMasterGain(0.9)).called(1);
    });

    test('a value outside the domain is clamped, not passed through', () {
      looper.writeValueTarget(const MasterGainTarget(), 3);

      verify(() => looper.setMasterGain(1)).called(1);
    });

    test('a track volume on a channel the rig lacks is inert', () {
      expect(looper.writeValueTarget(const TrackVolumeTarget(7), 0.4), isFalse);
    });
  });
}
