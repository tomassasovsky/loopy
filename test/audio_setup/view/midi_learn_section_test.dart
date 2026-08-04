import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/surface_theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

/// Lets a test move a control the way the user would, so a capture ends
/// through the real repository path rather than a hand-emitted state.
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

TrackEffect _fx(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  const cc = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 11,
    midiChannel: 0,
  );
  const volume = TrackVolumeTarget(0);
  const chain = FxChainTarget(FxAddress(stage: FxStage.track, index: 3));

  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late Map<int, List<TrackEffect>> trackChains;
  late Map<(int, int), List<TrackEffect>> laneChains;
  late MidiSetupCubit midi;
  late ControlCubit control;
  late SettingsRepository settings;
  late _FakeSource source;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    trackChains = {
      3: [_fx('a')],
    };
    laneChains = {};
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 4; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.allMonitors()).thenReturn(const {});
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
      () => looper.trackEffects(any()),
    ).thenAnswer((i) => trackChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.masterEffects).thenReturn(const []);
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(
      () => looper.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());
  });

  tearDown(() => looperStates.close());

  /// Pumps the section with [bindings] already mapped, on a rig whose MIDI
  /// input is [connected].
  Future<void> pump(
    WidgetTester tester, {
    List<ControllerBinding> bindings = const [],
    bool connected = true,
    Duration learnTimeout = const Duration(seconds: 15),
  }) async {
    settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    source = _FakeSource();
    final controller = ControllerRepository(sources: [source]);
    addTearDown(controller.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      controller: controller,
      keepAliveInterval: Duration.zero,
      learnTimeout: learnTimeout,
      // Straight-through writes: a debounced one would outlive the pumped
      // frame and trip the pending-timer check.
      mappingsWriteDebounce: Duration.zero,
    );
    // unawaited: awaiting ControlCubit.close() inside a testWidgets body
    // deadlocks on the test binding's stream cancellation.
    addTearDown(() => unawaited(control.close()));
    if (bindings.isNotEmpty) {
      await control.setControllerBindings(ControllerBindingSet(bindings));
    }

    final state = MidiSetupState(
      connection: MidiConnection(
        status: connected
            ? MidiConnectionStatus.connected
            : MidiConnectionStatus.deviceGone,
      ),
    );
    midi = _MockMidiSetupCubit();
    when(() => midi.state).thenReturn(state);
    whenListen(
      midi,
      const Stream<MidiSetupState>.empty(),
      initialState: state,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: control),
            BlocProvider<MidiSetupCubit>.value(value: midi),
          ],
          child: RepositoryProvider<LooperRepository>.value(
            value: looper,
            child: const Scaffold(
              body: SingleChildScrollView(child: MidiLearnSection()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('MidiLearnSection', () {
    testWidgets('shows the empty state and both add pickers', (tester) async {
      await pump(tester);

      expect(find.byKey(const Key('midiLearn_empty')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_addSweep')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_addSwitch')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_row')), findsNothing);
    });

    testWidgets('renders a mapped row with its control and target', (
      tester,
    ) async {
      await pump(
        tester,
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byKey(const Key('midiLearn_row')), findsOneWidget);
      expect(find.text(l10n.midiLearnCcControl(11, 1)), findsOneWidget);
      expect(find.text(l10n.midiLearnTargetVolume(0)), findsOneWidget);
      // A continuous mapping shows its travel, not a threshold.
      expect(find.byKey(const Key('midiLearn_lo')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_hi')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_threshold')), findsNothing);
    });

    testWidgets('a discrete row shows its threshold and behavior', (
      tester,
    ) async {
      await pump(
        tester,
        bindings: [
          DiscreteBinding(trigger: cc, target: chain.canonicalString()),
        ],
      );

      expect(find.byKey(const Key('midiLearn_threshold')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_behavior')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_lo')), findsNothing);
    });

    testWidgets('editing the LO knob writes the new range through', (
      tester,
    ) async {
      final binding = ContinuousBinding(
        trigger: cc,
        target: volume.canonicalString(),
      );
      await pump(tester, bindings: [binding]);

      // The knob exposes slider semantics; drive it through the accessible
      // increase action rather than a pixel drag.
      final knob = find.byKey(const Key('midiLearn_lo'));
      await tester.ensureVisible(knob);
      await tester.pumpAndSettle();
      final handle = tester.ensureSemantics();
      // The canonical way to drive a semantics action from a widget test;
      // there is no non-deprecated equivalent yet (same note as
      // signal_knob_test).
      // ignore: deprecated_member_use
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        tester.getSemantics(knob).id,
        SemanticsAction.increase,
      );
      await tester.pumpAndSettle();
      handle.dispose();

      final edited =
          control.state.controllerBindings.bindings.single as ContinuousBinding;
      expect(edited.lo, greaterThan(0));
    });

    testWidgets('Remove clears the mapping', (tester) async {
      await pump(
        tester,
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );

      await tapVisible(tester, find.byKey(const Key('midiLearn_clear')));

      expect(control.state.controllerBindings.isEmpty, isTrue);
      expect(find.byKey(const Key('midiLearn_row')), findsNothing);
    });

    testWidgets('a stale target renders the missing-target treatment', (
      tester,
    ) async {
      await pump(
        tester,
        bindings: [
          ContinuousBinding(
            trigger: cc,
            target: const FxParamTarget(
              address: FxAddress(stage: FxStage.track, index: 3),
              slotId: 'gone',
              param: 0,
            ).canonicalString(),
          ),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byKey(const Key('midiLearn_staleGlyph')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_staleDetail')), findsOneWidget);
      expect(find.text(l10n.midiLearnStale), findsOneWidget);
    });

    testWidgets('a disconnected input warns and offers relearn on each row', (
      tester,
    ) async {
      await pump(
        tester,
        connected: false,
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byKey(const Key('midiLearn_deviceMissing')), findsOneWidget);
      expect(find.text(l10n.midiLearnRelearn), findsOneWidget);
      expect(find.text(l10n.midiLearnLearn), findsNothing);
    });

    testWidgets('Learn shows the listening state, and cancel ends it', (
      tester,
    ) async {
      await pump(
        tester,
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tapVisible(tester, find.byKey(const Key('midiLearn_learn')));

      expect(find.byKey(const Key('midiLearn_status')), findsOneWidget);
      expect(find.text(l10n.midiLearnListening), findsOneWidget);

      await tapVisible(tester, find.byKey(const Key('midiLearn_cancel')));

      expect(find.byKey(const Key('midiLearn_status')), findsNothing);
      expect(control.state.controllerLearn, isNull);
    });

    testWidgets('editing a row while it listens keeps the listening state', (
      tester,
    ) async {
      final binding = ContinuousBinding(
        trigger: cc,
        target: volume.canonicalString(),
      );
      await pump(tester, bindings: [binding]);

      await tapVisible(tester, find.byKey(const Key('midiLearn_learn')));
      expect(find.byKey(const Key('midiLearn_status')), findsOneWidget);

      // A knob nudge mid-capture must not take the "listening…" row — and its
      // only Cancel button — away while the repository is still swallowing
      // every controller event.
      await control.updateControllerBinding(binding, binding.copyWith(lo: 0.4));
      await tester.pumpAndSettle();

      expect(control.state.controllerLearn, isNotNull);
      expect(find.byKey(const Key('midiLearn_status')), findsOneWidget);
      expect(find.byKey(const Key('midiLearn_cancel')), findsOneWidget);

      await tapVisible(tester, find.byKey(const Key('midiLearn_cancel')));
      expect(control.state.controllerLearn, isNull);
    });

    testWidgets('a capture on a mapped control asks before replacing', (
      tester,
    ) async {
      final existing = ContinuousBinding(
        trigger: cc,
        target: volume.canonicalString(),
      );
      await pump(tester, bindings: [existing]);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // Learn a DIFFERENT target, then move the control that is already
      // mapped — the real path into the confirmation.
      await tapVisible(tester, find.byKey(const Key('midiLearn_addSweep')));
      await tapVisible(tester, find.text(l10n.midiLearnTargetMaster).last);
      source.cc(11, 40);
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.midiLearnReplacePrompt(l10n.midiLearnCcControl(11, 1))),
        findsOneWidget,
      );
      expect(
        control.state.controllerBindings.bindings,
        [existing],
        reason: 'nothing is replaced until the user says so',
      );

      await tapVisible(tester, find.byKey(const Key('midiLearn_replace')));

      expect(
        control.state.controllerBindings.bindings.single.target,
        const MasterGainTarget().canonicalString(),
      );
    });

    testWidgets('Add sweep picks a target and starts listening', (
      tester,
    ) async {
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tapVisible(tester, find.byKey(const Key('midiLearn_addSweep')));
      await tapVisible(tester, find.text(l10n.midiLearnTargetMaster).last);

      expect(find.text(l10n.midiLearnListening), findsOneWidget);
      expect(control.state.controllerLearn?.continuous, isTrue);

      // Moving a control completes it into a real mapping.
      source.cc(11, 90);
      await tester.pumpAndSettle();

      expect(
        control.state.controllerBindings.bindings.single,
        isA<ContinuousBinding>(),
      );
      expect(find.byKey(const Key('midiLearn_row')), findsOneWidget);
    });

    testWidgets('Add switch learns a discrete mapping', (tester) async {
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tapVisible(tester, find.byKey(const Key('midiLearn_addSwitch')));
      await tapVisible(tester, find.text(bindingTargetLabel(l10n, chain)).last);
      source.cc(21, 127);
      await tester.pumpAndSettle();

      expect(
        control.state.controllerBindings.bindings.single,
        isA<DiscreteBinding>(),
      );
    });

    testWidgets('a capture nobody feeds times out and clears the row', (
      tester,
    ) async {
      await pump(
        tester,
        learnTimeout: const Duration(seconds: 1),
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );

      await tapVisible(tester, find.byKey(const Key('midiLearn_learn')));
      expect(find.byKey(const Key('midiLearn_status')), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('midiLearn_status')), findsNothing);
      expect(control.state.controllerLearn, isNull);
    });

    testWidgets('a row is announced with its control and target (a11y)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        bindings: [
          ContinuousBinding(trigger: cc, target: volume.canonicalString()),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(
        find.bySemanticsLabel(
          RegExp(
            RegExp.escape(
              l10n.a11yMidiLearnRow(
                l10n.midiLearnCcControl(11, 1),
                l10n.midiLearnTargetVolume(0),
              ),
            ),
          ),
        ),
        findsWidgets,
      );
      handle.dispose();
    });
  });
}
