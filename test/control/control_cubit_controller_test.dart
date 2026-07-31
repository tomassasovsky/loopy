import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

class _FakeSource implements ControllerSource {
  final _inputs = StreamController<RawControllerInput>.broadcast();

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  void cc(int id, int value, {int channel = 0}) => _inputs.add(
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: id,
      value: value,
      midiChannel: channel,
    ),
  );

  @override
  Future<void> dispose() => _inputs.close();
}

/// External MIDI control at the ONE dispatch point (part 7): resolved binding
/// events reaching the rig, the learn flow that creates them, and the
/// release-all rule extended to MIDI-source disconnect (B1).
void main() {
  const expression = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 11,
    midiChannel: 0,
  );
  const stomp = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 21,
    midiChannel: 0,
  );
  const chainTarget = FxChainTarget(FxAddress(stage: FxStage.track));
  const volumeTarget = TrackVolumeTarget(0);

  group('ControlCubit external MIDI', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late _FakeSource source;
    late ControllerRepository controller;
    late _MockMidiDeviceRepository midiDevices;
    late StreamController<MidiConnection> connections;
    late SettingsRepository settings;
    late PedalRepository pedal;
    late PerformanceRepository performance;
    late ControlCubit cubit;
    late Directory tempDir;
    late Map<int, bool> chainEnabled;
    late Map<int, List<TrackEffect>> trackChains;
    late List<double> volumeWrites;
    /// The write debounce the cubit under test is built with. Zero (immediate)
    /// unless a test overrides it before the cubit is built.
    var mappingsWriteDebounce = Duration.zero;

    /// Lets every pending stream event and microtask land — the repository's
    /// binding stream is asynchronous, as is the cubit's own subscription.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    setUp(() {
      mappingsWriteDebounce = Duration.zero;
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      source = _FakeSource();
      controller = ControllerRepository(
        sources: [source],
        // One tick per move: the ramp is covered under a fake clock in the
        // package suite; here what matters is the value reaching the rig.
        smoothing: const Duration(milliseconds: 1),
        smoothingTick: const Duration(milliseconds: 1),
      );
      midiDevices = _MockMidiDeviceRepository();
      connections = StreamController<MidiConnection>.broadcast();
      when(() => midiDevices.connections).thenAnswer((_) => connections.stream);
      settings = SettingsRepository(store: FakeKeyValueStore());
      pedal = PedalRepository(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
        ),
      );

      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      when(() => looper.state).thenReturn(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );

      chainEnabled = <int, bool>{};
      trackChains = <int, List<TrackEffect>>{
        0: [BuiltInEffect(type: TrackEffectType.drive, slotId: 't-1')],
      };
      volumeWrites = <double>[];
      when(() => looper.trackChainEnabled(any())).thenAnswer(
        (call) => chainEnabled[call.positionalArguments.first as int] ?? true,
      );
      when(
        () => looper.setTrackChainEnabled(
          channel: any(named: 'channel'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((call) {
        chainEnabled[call.namedArguments[#channel] as int] =
            call.namedArguments[#enabled] as bool;
        return EngineResult.ok;
      });
      when(() => looper.trackEffects(any())).thenAnswer(
        (call) =>
            trackChains[call.positionalArguments.first as int] ??
            const <TrackEffect>[],
      );
      when(() => looper.allTrackChains()).thenAnswer(
        (_) => {
          for (final channel in trackChains.keys)
            channel: const FxChainEnvelope(),
        },
      );
      when(() => looper.allMonitors()).thenAnswer((_) => const {});
      when(() => looper.allLaneChains()).thenAnswer((_) => const {});
      when(() => looper.masterEffects).thenAnswer((_) => const []);
      when(
        () => looper.setVolume(any(), channel: any(named: 'channel')),
      ).thenAnswer((call) {
        volumeWrites.add(call.positionalArguments.first as double);
        return EngineResult.ok;
      });
      when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
      when(
        () => looper.setTrackEffectParam(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          param: any(named: 'param'),
          value: any(named: 'value'),
        ),
      ).thenReturn(EngineResult.ok);

      tempDir = Directory.systemTemp.createTempSync('loopy_control_midi');
      performance = PerformanceRepository(
        engine: FakeAudioEngine(),
        exportsRoot: () async => tempDir.path,
      );
      cubit = ControlCubit(
        looper: looper,
        pedal: pedal,
        settings: settings,
        performance: performance,
        controller: controller,
        midiDevices: midiDevices,
        keepAliveInterval: Duration.zero,
        learnTimeout: const Duration(milliseconds: 20),
        mappingsWriteDebounce: mappingsWriteDebounce,
      );
    });

    tearDown(() async {
      await cubit.close();
      await controller.dispose();
      await connections.close();
      await pedal.dispose();
      await looperStates.close();
      performance.dispose();
      tempDir.deleteSync(recursive: true);
    });

    /// Installs [bindings] the way an edit does — through the cubit, so the
    /// repository and the persisted blob stay in step.
    Future<void> use(List<ControllerBinding> bindings) =>
        cubit.setControllerBindings(ControllerBindingSet(bindings));

    group('continuous bindings', () {
      test('a CC sweep writes the mapped value into the rig', () async {
        await use([
          ContinuousBinding(
            trigger: expression,
            target: volumeTarget.canonicalString(),
            lo: 0.25,
            hi: 0.75,
          ),
        ]);

        source.cc(11, 127);
        await settle();

        expect(volumeWrites, hasLength(1));
        expect(volumeWrites.single, closeTo(0.75, 1e-9));
      });

      test('master gain keeps the encoder accumulator in step', () async {
        await use([
          ContinuousBinding(
            trigger: expression,
            target: const MasterGainTarget().canonicalString(),
          ),
        ]);

        source.cc(11, 0); // MIDI drives master gain to 0
        await settle();
        cubit.encoderTurned(1); // the next detent must step up FROM 0

        final gains = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured.cast<double>();
        expect(gains, hasLength(2));
        expect(gains.first, 0);
        expect(gains.last, closeTo(1 / 64, 1e-9));
      });

      test('a stale target writes nothing and does not throw', () async {
        await use([
          ContinuousBinding(
            trigger: expression,
            target: const FxParamTarget(
              address: FxAddress(stage: FxStage.track),
              slotId: 'gone',
              param: 0,
            ).canonicalString(),
          ),
        ]);

        source.cc(11, 127);
        await settle();

        verifyNever(
          () => looper.setTrackEffectParam(
            channel: any(named: 'channel'),
            index: any(named: 'index'),
            param: any(named: 'param'),
            value: any(named: 'value'),
          ),
        );
      });

      test('a value HOLDS when the MIDI source disconnects', () async {
        await use([
          ContinuousBinding(
            trigger: expression,
            target: volumeTarget.canonicalString(),
          ),
        ]);

        source.cc(11, 127);
        await settle();
        connections.add(
          const MidiConnection(status: MidiConnectionStatus.deviceGone),
        );
        await settle();

        // No snap-back: the last swept value is left exactly where it was.
        expect(volumeWrites, [closeTo(1, 1e-9)]);
      });
    });

    group('discrete bindings', () {
      test('a toggle CC flips the chain on the ON edge only', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
          ),
        ]);

        source.cc(21, 127);
        await settle();
        expect(chainEnabled[0], isFalse);

        source.cc(21, 0); // the release must not undo the stomp
        await settle();
        expect(chainEnabled[0], isFalse);
      });

      test('a momentary CC enables on press and restores on release', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
            behavior: BindingBehavior.momentary,
          ),
        ]);
        chainEnabled[0] = false;

        source.cc(21, 127);
        await settle();
        expect(chainEnabled[0], isTrue);

        source.cc(21, 0);
        await settle();
        expect(chainEnabled[0], isFalse, reason: 'restores what it captured');
      });

      test('MIDI disconnect releases a held momentary (B1)', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
            behavior: BindingBehavior.momentary,
          ),
        ]);
        chainEnabled[0] = false;

        source.cc(21, 127);
        await settle();
        expect(chainEnabled[0], isTrue);

        // The release edge is never coming — the cable is out.
        connections.add(
          const MidiConnection(status: MidiConnectionStatus.deviceGone),
        );
        await settle();

        expect(chainEnabled[0], isFalse);
      });

      test('a still-connected status leaves a held momentary alone', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
            behavior: BindingBehavior.momentary,
          ),
        ]);
        chainEnabled[0] = false;

        source.cc(21, 127);
        await settle();
        connections.add(
          const MidiConnection(status: MidiConnectionStatus.connected),
        );
        await settle();

        expect(chainEnabled[0], isTrue);
      });

      test('editing the mappings releases a held momentary (B1)', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
            behavior: BindingBehavior.momentary,
          ),
        ]);
        chainEnabled[0] = false;

        source.cc(21, 127);
        await settle();
        await use(const []);

        expect(chainEnabled[0], isFalse);
      });

      test(
        'a repeated press does not re-capture the state it enabled',
        () async {
          await use([
            DiscreteBinding(
              trigger: stomp,
              target: chainTarget.canonicalString(),
              behavior: BindingBehavior.momentary,
            ),
          ]);
          chainEnabled[0] = false;

          source.cc(21, 127);
          await settle();
          // A second ON edge with no release between them (a dropped
          // message, or a control that re-crosses the threshold): the
          // capture must stand.
          source
            ..cc(21, 0)
            ..cc(21, 127)
            ..cc(21, 0);
          await settle();

          expect(chainEnabled[0], isFalse);
        },
      );
    });

    group('persistence', () {
      test(
        'an edit writes the global blob and reaches the repository',
        () async {
          final binding = ContinuousBinding(
            trigger: expression,
            target: volumeTarget.canonicalString(),
            hi: 0.5,
          );

          await use([binding]);

          expect(controller.bindings.bindings, [binding]);
          expect(
            await settings.loadControllerMappings(),
            ControllerBindingSet([binding]).encode(),
          );
        },
      );

      test('a burst of edits coalesces into one write', () async {
        mappingsWriteDebounce = const Duration(milliseconds: 30);
        await cubit.close();
        cubit = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          controller: controller,
          midiDevices: midiDevices,
          keepAliveInterval: Duration.zero,
          mappingsWriteDebounce: mappingsWriteDebounce,
        );
        final binding = ContinuousBinding(
          trigger: expression,
          target: volumeTarget.canonicalString(),
        );

        // What a LO knob drag looks like: many edits inside one debounce.
        for (final lo in [0.1, 0.2, 0.3]) {
          await use([binding.copyWith(lo: lo)]);
        }
        expect(
          await settings.loadControllerMappings(),
          isNull,
          reason: 'nothing has reached the store yet',
        );

        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          await settings.loadControllerMappings(),
          ControllerBindingSet([binding.copyWith(lo: 0.3)]).encode(),
          reason: 'only the settled value is written',
        );
      });

      test('close() flushes an edit the debounce was still holding', () async {
        mappingsWriteDebounce = const Duration(seconds: 30);
        await cubit.close();
        cubit = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          controller: controller,
          midiDevices: midiDevices,
          keepAliveInterval: Duration.zero,
          mappingsWriteDebounce: mappingsWriteDebounce,
        );
        final binding = ContinuousBinding(
          trigger: expression,
          target: volumeTarget.canonicalString(),
        );

        await use([binding]);
        await cubit.close();
        await settle();

        expect(
          await settings.loadControllerMappings(),
          ControllerBindingSet([binding]).encode(),
        );
      });

      test('load() restores the blob into state and the repository', () async {
        final binding = DiscreteBinding(
          trigger: stomp,
          target: chainTarget.canonicalString(),
        );
        await settings.saveControllerMappings(
          ControllerBindingSet([binding]).encode(),
        );

        await cubit.load();

        expect(cubit.state.controllerBindings.bindings, [binding]);
        expect(controller.bindings.bindings, [binding]);

        source.cc(21, 127);
        await settle();
        expect(chainEnabled[0], isFalse, reason: 'a restored mapping is live');
      });
    });

    group('learn', () {
      test(
        'a captured control binds, with the channel it arrived on',
        () async {
          cubit.learnControllerBinding(target: volumeTarget.canonicalString());
          expect(cubit.state.controllerLearn, isNotNull);

          source.cc(11, 40, channel: 6);
          await settle();

          final bound = cubit.state.controllerBindings.bindings.single;
          expect(bound, isA<ContinuousBinding>());
          expect(bound.trigger.id, 11);
          expect(bound.trigger.midiChannel, 6);
          expect(cubit.state.controllerLearn, isNull);
        },
      );

      test('a discrete learn binds the switch shape', () async {
        cubit.learnControllerBinding(
          target: chainTarget.canonicalString(),
          continuous: false,
        );

        source.cc(21, 127);
        await settle();

        expect(
          cubit.state.controllerBindings.bindings.single,
          isA<DiscreteBinding>(),
        );
      });

      test(
        'an already-mapped control waits for the replace confirmation',
        () async {
          final existing = ContinuousBinding(
            trigger: expression,
            target: volumeTarget.canonicalString(),
          );
          await use([existing]);

          cubit.learnControllerBinding(
            target: const MasterGainTarget().canonicalString(),
          );
          source.cc(11, 40);
          await settle();

          expect(cubit.state.controllerLearn?.awaitingConfirm, isTrue);
          expect(
            cubit.state.controllerBindings.bindings,
            [existing],
            reason: 'nothing is replaced until the user says so',
          );

          await cubit.confirmControllerLearn();

          expect(
            cubit.state.controllerBindings.bindings.single.target,
            const MasterGainTarget().canonicalString(),
          );
          expect(cubit.state.controllerLearn, isNull);
        },
      );

      test('keeping the old mapping cancels the capture', () async {
        final existing = ContinuousBinding(
          trigger: expression,
          target: volumeTarget.canonicalString(),
        );
        await use([existing]);

        cubit.learnControllerBinding(
          target: const MasterGainTarget().canonicalString(),
        );
        source.cc(11, 40);
        await settle();
        cubit.cancelControllerLearn();

        expect(cubit.state.controllerLearn, isNull);
        expect(cubit.state.controllerBindings.bindings, [existing]);
      });

      test(
        'a relearn keeps the row ranges and drops the old control',
        () async {
          final existing = ContinuousBinding(
            trigger: expression,
            target: volumeTarget.canonicalString(),
            lo: 0.3,
            hi: 0.6,
          );
          await use([existing]);

          cubit.learnControllerBinding(
            target: existing.target,
            replacing: existing,
          );
          source.cc(21, 100); // a different control
          await settle();

          final bound =
              cubit.state.controllerBindings.bindings.single
                  as ContinuousBinding;
          expect(bound.trigger.id, 21);
          expect(bound.lo, 0.3);
          expect(bound.hi, 0.6);
          expect(cubit.state.controllerBindings.length, 1);
        },
      );

      test(
        'a capture nobody feeds times out and stops swallowing input',
        () async {
          await use([
            DiscreteBinding(
              trigger: stomp,
              target: chainTarget.canonicalString(),
            ),
          ]);

          cubit.learnControllerBinding(target: volumeTarget.canonicalString());
          await Future<void>.delayed(const Duration(milliseconds: 40));

          expect(cubit.state.controllerLearn, isNull);
          expect(controller.isLearning, isFalse);

          source.cc(21, 127);
          await settle();
          expect(chainEnabled[0], isFalse, reason: 'dispatch resumed');
        },
      );

      test('starting a capture releases a held momentary (B1)', () async {
        await use([
          DiscreteBinding(
            trigger: stomp,
            target: chainTarget.canonicalString(),
            behavior: BindingBehavior.momentary,
          ),
        ]);
        chainEnabled[0] = false;

        source.cc(21, 127);
        await settle();
        expect(chainEnabled[0], isTrue);

        // A pending capture swallows the release edge, so the foot on that
        // switch would never let go of the target.
        cubit.learnControllerBinding(target: volumeTarget.canonicalString());
        await settle();

        expect(chainEnabled[0], isFalse);
      });

      test('close() ends a capture instead of leaving the stream swallowed',
          () async {
        cubit.learnControllerBinding(target: volumeTarget.canonicalString());
        expect(controller.isLearning, isTrue);

        await cubit.close();

        expect(
          controller.isLearning,
          isFalse,
          reason: 'a learning repository swallows every controller event',
        );
      });

      test('cancelling a capture leaves the mappings untouched', () async {
        cubit
          ..learnControllerBinding(target: volumeTarget.canonicalString())
          ..cancelControllerLearn();
        await settle();

        expect(cubit.state.controllerLearn, isNull);
        expect(cubit.state.controllerBindings.isEmpty, isTrue);
      });
    });
  });
}
