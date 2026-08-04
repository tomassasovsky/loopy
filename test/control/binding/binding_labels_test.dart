import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/l10n/l10n.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _drive(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  late AppLocalizations l10n;
  late _MockLooperRepository looper;
  late Map<int, List<TrackEffect>> trackChains;
  late Map<(int, int), List<TrackEffect>> laneChains;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    looper = _MockLooperRepository();
    trackChains = {
      3: [
        _drive('t-1'),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          slotId: 'plug-1',
        ),
      ],
    };
    laneChains = {
      (1, 0): [_drive('l-1')],
    };
    when(looper.allMonitors).thenReturn(const {});
    when(looper.allLaneChains).thenAnswer(
      (_) => {for (final key in laneChains.keys) key: const FxChainEnvelope()},
    );
    when(looper.allTrackChains).thenAnswer(
      (_) => {
        for (final channel in trackChains.keys)
          channel: const FxChainEnvelope(),
      },
    );
    when(() => looper.monitorEffects(any())).thenReturn(const []);
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
    when(() => looper.masterEffects).thenReturn(const []);
  });

  group('fxStageLabel', () {
    test('names every stage', () {
      expect(
        fxStageLabel(l10n, const FxAddress(stage: FxStage.input, index: 2)),
        l10n.pedalAssignStageInput(2),
      );
      expect(
        fxStageLabel(
          l10n,
          const FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        ),
        l10n.pedalAssignStageLoop(1, 0),
      );
      expect(
        fxStageLabel(l10n, const FxAddress(stage: FxStage.track, index: 3)),
        l10n.pedalAssignStageTrack(3),
      );
      expect(
        fxStageLabel(l10n, const FxAddress(stage: FxStage.master)),
        l10n.pedalAssignStageMaster,
      );
    });
  });

  group('bindingTargetLabel', () {
    test('names a chain by its stage and a slot by its stable id', () {
      const address = FxAddress(stage: FxStage.track, index: 3);

      expect(
        bindingTargetLabel(l10n, const FxChainTarget(address)),
        l10n.pedalAssignChainTarget(l10n.pedalAssignStageTrack(3)),
      );
      expect(
        bindingTargetLabel(
          l10n,
          const FxSlotTarget(address: address, slotId: 't-1'),
        ),
        contains('t-1'),
      );
    });
  });

  group('valueTargetLabel', () {
    test('names the rig-level controls', () {
      expect(
        valueTargetLabel(l10n, looper, const TrackVolumeTarget(2)),
        l10n.midiLearnTargetVolume(2),
      );
      expect(
        valueTargetLabel(l10n, looper, const MasterGainTarget()),
        l10n.midiLearnTargetMaster,
      );
    });

    test(
      "names a live FX param with the effect type's own parameter name",
      () {
        const target = FxParamTarget(
          address: FxAddress(stage: FxStage.track, index: 3),
          slotId: 't-1',
          param: 1,
        );

        expect(
          valueTargetLabel(l10n, looper, target),
          l10n.midiLearnTargetParam(
            l10n.pedalAssignStageTrack(3),
            't-1',
            TrackEffectType.drive.params[1].label,
          ),
        );
      },
    );

    test('falls back to the bare index when the slot is gone', () {
      // A stale row still has to say what it used to drive, so the label never
      // vanishes with the slot.
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'gone',
        param: 2,
      );

      expect(valueTargetLabel(l10n, looper, target), contains('#2'));
    });

    test('falls back for a plugin slot and an out-of-range param', () {
      const plugin = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'plug-1',
        param: 0,
      );
      const past = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 't-1',
        param: 99,
      );

      expect(valueTargetLabel(l10n, looper, plugin), contains('#0'));
      expect(valueTargetLabel(l10n, looper, past), contains('#99'));
    });

    test(
      'a lane-less Loop address names no parameter, like the resolver',
      () {
        // The resolvers refuse to coerce it onto lane 0 (A9); a label naming
        // lane 0's effect would describe a chain nothing ever writes to.
        const laneless = FxParamTarget(
          address: FxAddress(stage: FxStage.loop, index: 1),
          slotId: 'l-1',
          param: 0,
        );

        expect(valueTargetLabel(l10n, looper, laneless), contains('#0'));
      },
    );
  });

  group('controlLabel', () {
    test('names a CC and a note by number and 1-based channel', () {
      expect(
        controlLabel(
          l10n,
          const MappingTrigger(
            kind: ControllerSourceKind.midiCc,
            id: 11,
            midiChannel: 0,
          ),
        ),
        l10n.midiLearnCcControl(11, 1),
      );
      expect(
        controlLabel(
          l10n,
          const MappingTrigger(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            midiChannel: 15,
          ),
        ),
        l10n.midiLearnNoteControl(60, 16),
      );
    });

    test('an omni trigger reads as channel 1', () {
      expect(
        controlLabel(
          l10n,
          const MappingTrigger(kind: ControllerSourceKind.midiCc, id: 11),
        ),
        l10n.midiLearnCcControl(11, 1),
      );
    });
  });
}
