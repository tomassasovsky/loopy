import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

TrackEffect _fx(String slotId, TrackEffectType type) =>
    BuiltInEffect(type: type, slotId: slotId);

/// The Master chain, which every rig has — the one target that is always
/// offerable, so a test never depends on a configured stage existing.
const _master = FxAddress(stage: FxStage.master);

void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late _MockMidiDevices midiDevices;
  late StreamController<MidiConnection> connections;
  late StreamController<void> activity;
  late ControlCubit control;
  late MidiSetupCubit midi;
  late SettingsTrayCubit tray;
  late List<TrackEffect> masterChain;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    masterChain = [
      _fx('slot-drive', TrackEffectType.drive),
      _fx('slot-reverb', TrackEffectType.reverb),
    ];
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.masterEffects).thenAnswer((_) => masterChain);
    when(
      () => looper.chainEntriesAt(_master),
    ).thenAnswer((_) => masterChain);
    when(
      () => looper.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());

    midiDevices = _MockMidiDevices();
    connections = StreamController<MidiConnection>.broadcast();
    activity = StreamController<void>.broadcast();
    when(() => midiDevices.connections).thenAnswer((_) => connections.stream);
    when(() => midiDevices.activity).thenAnswer((_) => activity.stream);
    when(() => midiDevices.connection).thenReturn(const MidiConnection());
    when(() => midiDevices.select(any())).thenAnswer((_) async {});
  });

  tearDown(() async {
    await looperStates.close();
    await connections.close();
    await activity.close();
  });

  /// Mounts the Control face with the providers the real tray inherits.
  Future<void> pump(
    WidgetTester tester, {
    MidiConnection connection = const MidiConnection(),
    Size size = const Size(1600, 1400),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => midiDevices.connection).thenReturn(connection);

    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    // A real ControllerRepository with no sources: the learn path needs one to
    // exist at all — without it `learnControllerBinding` returns on its first
    // line, which is exactly the app-wiring bug this slice fixed.
    final controller = ControllerRepository(sources: const []);
    addTearDown(controller.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      controller: controller,
      midiDevices: midiDevices,
      keepAliveInterval: Duration.zero,
    );
    midi = MidiSetupCubit(repository: midiDevices);
    tray = SettingsTrayCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(midi.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: midi),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: ControlTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(ControlTrayPanel)));

  Future<void> showMidi(WidgetTester tester) async {
    tray.showControlTab(ControlTab.midi);
    await tester.pumpAndSettle();
  }

  group('Control face', () {
    testWidgets('the tab strip swaps the body', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('pedal_tray_body')), findsOneWidget);
      expect(find.byKey(const Key('midi_tray_body')), findsNothing);

      await tester.tap(find.text(l10nOf(tester).controlMidiTab));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pedal_tray_body')), findsNothing);
      expect(find.byKey(const Key('midi_tray_body')), findsOneWidget);
    });

    testWidgets('the domain names itself once, above the strip', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text(l10nOf(tester).trayControlLabel), findsOneWidget);
    });
  });

  group('Pedal tab', () {
    testWidgets('draws four transport switches and four track switches', (
      tester,
    ) async {
      await pump(tester);
      for (final button in [
        PedalButton.recPlay,
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
        PedalButton.track4,
      ]) {
        expect(
          find.byKey(Key('pedal_switch_${button.name}')),
          findsOneWidget,
          reason: '${button.name} should be assignable',
        );
      }
    });

    testWidgets('offers MODE and Bank nowhere — they can never hold one', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('pedal_switch_mode')), findsNothing);
      expect(find.byKey(const Key('pedal_switch_bank')), findsNothing);
    });

    testWidgets('selecting a switch lists what it can drive', (tester) async {
      await pump(tester);
      final chain = const FxChainTarget(_master).canonicalString();
      expect(find.byKey(Key('pedal_target_$chain')), findsNothing);

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
    });

    testWidgets('chains come first; individual effects are one tap down', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      final slot = const FxSlotTarget(
        address: _master,
        slotId: 'slot-drive',
      ).canonicalString();
      expect(find.byKey(Key('pedal_target_$slot')), findsNothing);

      await tester.tap(find.byKey(const Key('pedal_show_effects')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('pedal_target_$slot')), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
    });

    testWidgets('choosing a target assigns it, and choosing it again clears', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      const key = PedalBindingKey(button: PedalButton.recPlay);
      expect(
        control.state.globalBindings.bindings
            .where((b) => b.key == key)
            .map((b) => b.target),
        [chain],
      );
      // The check IS the row's on-state, so tapping it again turns it off.
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();
      expect(
        control.state.globalBindings.bindings.where((b) => b.key == key),
        isEmpty,
      );
    });

    testWidgets('bank B stays put once picked, so its switches are usable', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();

      // Regression: selecting a switch used to re-seed the bank from the
      // pedal's own, which snapped the list back to A on the tap and left
      // bank B's four switches impossible to reach.
      await tester.tap(find.byKey(const Key('pedal_switch_track2')));
      await tester.pumpAndSettle();

      expect(
        find.text(l10nOf(tester).controlAssignGroup('TRACK 2', 'B')),
        findsOneWidget,
      );

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      expect(
        control.state.globalBindings.bindings.single.key,
        const PedalBindingKey(button: PedalButton.track2, bank: 1),
      );
    });

    testWidgets('a track switch holds a binding per bank', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_track1')));
      await tester.pumpAndSettle();

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      expect(
        control.state.globalBindings.bindings.single.key,
        const PedalBindingKey(button: PedalButton.track1, bank: 0),
      );

      // Bank B is a different key on the same cap, so its row reads back as
      // unassigned rather than inheriting bank A's binding.
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).controlUnassigned),
        findsWidgets,
      );
    });

    testWidgets('a binding whose target is gone takes the warning tone', (
      tester,
    ) async {
      await pump(tester);
      final gone = const FxSlotTarget(
        address: _master,
        slotId: 'slot-deleted',
      ).canonicalString();
      await control.setGlobalBindings(
        PedalBindingSet([
          const PedalBinding(
            key: PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: '',
          ).copyWith(target: gone),
        ]),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester);
      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('pedal_switch_track1')),
      );
      expect(row.value, l10n.controlTargetMissing);
      expect(
        row.valueColor,
        SurfaceTheme.dark.warning,
        reason: 'a missing target is not the grey of "nobody asked it to"',
      );
    });

    testWidgets('the assign list animates open and holds while it closes', (
      tester,
    ) async {
      await pump(tester);
      final chain = const FxChainTarget(_master).canonicalString();

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      // Three frames in, the strip is on screen but still growing — goldens
      // only ever photograph settled states, so the motion needs its own
      // assertion.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // The strip itself is measured, not a row inside it: the row keeps its
      // own 70px whatever the clip is doing, so only the expansion's own box
      // reports the growth.
      final growing = tester.getSize(
        find.byKey(const Key('pedal_assign_slot')),
      );
      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
      await tester.pumpAndSettle();
      final settled = tester.getSize(
        find.byKey(const Key('pedal_assign_slot')),
      );
      expect(growing.height, lessThan(settled.height));

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // Still drawn mid-close: the expansion holds the outgoing child, so the
      // list travels back up instead of the rows vanishing and a gap
      // collapsing behind them.
      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('pedal_target_$chain')), findsNothing);
    });
  });

  group('MIDI tab', () {
    const device = MidiDevice(id: 'dev-1', name: 'Nektar Pacer');
    const connected = MidiConnection(
      devices: [device],
      selectedId: 'dev-1',
      selectedName: 'Nektar Pacer',
      status: MidiConnectionStatus.connected,
    );

    ControllerBindingSet mappings() => ControllerBindingSet([
      ContinuousBinding(
        trigger: const MappingTrigger(
          kind: ControllerSourceKind.midiCc,
          id: 11,
          midiChannel: 0,
        ),
        target: const MasterGainTarget().canonicalString(),
      ),
      DiscreteBinding(
        trigger: const MappingTrigger(
          kind: ControllerSourceKind.midiNote,
          id: 36,
          midiChannel: 0,
        ),
        target: const FxChainTarget(_master).canonicalString(),
      ),
    ]);

    testWidgets('the device row opens a chooser in place, not a modal', (
      tester,
    ) async {
      await pump(tester, connection: connected);
      await showMidi(tester);

      expect(find.byKey(const Key('midi_device_choice_dev-1')), findsNothing);

      await tester.tap(find.byKey(const Key('midi_device_row')));
      await tester.pumpAndSettle();

      // In the list, under the row that opened it — no route was pushed, so
      // the status card underneath is still on screen.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const Key('midi_status')), findsOneWidget);
      expect(find.byKey(const Key('midi_device_choice_')), findsOneWidget);
      expect(find.byKey(const Key('midi_device_choice_dev-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('midi_device_choice_')));
      await tester.pumpAndSettle();

      verify(() => midiDevices.select('')).called(1);
      expect(find.byKey(const Key('midi_device_choice_dev-1')), findsNothing);
    });

    testWidgets('an add button opens its target chooser in place', (
      tester,
    ) async {
      await pump(tester, connection: connected);
      await showMidi(tester);

      final target = const FxChainTarget(_master).canonicalString();
      expect(find.byKey(Key('midi_add_target_$target')), findsNothing);

      await tester.tap(find.byKey(const Key('midi_add_switch')));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(Key('midi_add_target_$target')), findsOneWidget);

      await tester.tap(find.byKey(Key('midi_add_target_$target')));
      await tester.pumpAndSettle();

      // Picking a target starts the capture and shuts the chooser.
      expect(control.state.controllerLearn?.target, target);
      expect(control.state.controllerLearn?.continuous, isFalse);
      expect(find.byKey(Key('midi_add_target_$target')), findsNothing);
      expect(find.byKey(const Key('midi_add_banner')), findsOneWidget);

      // A live capture holds the learn-timeout timer, which the binding fails
      // the test for if it outlives the tree.
      control.cancelControllerLearn();
      await tester.pumpAndSettle();
    });

    testWidgets('stacks the device, its status and the mappings', (
      tester,
    ) async {
      await pump(tester, connection: connected);
      await showMidi(tester);

      expect(find.byKey(const Key('midi_device_row')), findsOneWidget);
      expect(find.byKey(const Key('midi_status')), findsOneWidget);
      expect(find.byKey(const Key('midi_add_sweep')), findsOneWidget);
      expect(find.byKey(const Key('midi_add_switch')), findsOneWidget);
      expect(find.text('Nektar Pacer'), findsOneWidget);
    });

    testWidgets("states the fixed transport map from the rig's own defaults", (
      tester,
    ) async {
      await pump(tester, connection: connected);
      await showMidi(tester);

      final l10n = l10nOf(tester);
      final expected = ControllerMapping.defaults().entries
          .where((e) => e.trigger.kind == ControllerSourceKind.midiCc)
          .length;
      final prose = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .firstWhere((s) => s.startsWith('CC '));
      expect(prose.split(' · ').length, expected);
      expect(prose, contains(l10n.midiActionRecord));
      expect(prose, contains(l10n.midiActionTapTempo));
    });

    testWidgets('each device fault tells itself apart', (tester) async {
      for (final (status, matcher)
          in <
            (
              MidiConnectionStatus,
              String Function(AppLocalizations),
            )
          >[
            (MidiConnectionStatus.none, (l) => l.midiStatusNone),
            (
              MidiConnectionStatus.deviceGone,
              (l) => l.midiStatusDeviceGone('Nektar Pacer'),
            ),
            (
              MidiConnectionStatus.error,
              (l) => l.midiStatusOpenFailed('Nektar Pacer'),
            ),
            (MidiConnectionStatus.connecting, (l) => l.midiStatusConnecting),
          ]) {
        await pump(
          tester,
          connection: MidiConnection(
            selectedId: status == MidiConnectionStatus.none ? '' : 'dev-1',
            selectedName: 'Nektar Pacer',
            status: status,
          ),
        );
        await showMidi(tester);
        expect(
          find.text(matcher(l10nOf(tester))),
          findsOneWidget,
          reason: '$status should say something only it says',
        );
      }
    });

    testWidgets('reports traffic only on a live link', (tester) async {
      await pump(tester);
      await showMidi(tester);
      expect(find.byKey(const Key('midi_traffic')), findsNothing);

      await pump(tester, connection: connected);
      await showMidi(tester);
      expect(find.byKey(const Key('midi_traffic')), findsOneWidget);
      expect(find.text(l10nOf(tester).midiStatusWaiting), findsOneWidget);

      activity.add(null);
      // Twice: the first pump delivers the stream event, the second draws the
      // state it produced.
      await tester.pump();
      await tester.pump();
      expect(find.text(l10nOf(tester).midiStatusReceiving), findsOneWidget);
      // And stops claiming to be busy once the controller goes quiet.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(l10nOf(tester).midiStatusWaiting), findsOneWidget);
    });

    testWidgets('a mapping opens onto its own calibration', (tester) async {
      await pump(tester, connection: connected);
      await control.setControllerBindings(mappings());
      await showMidi(tester);

      expect(find.byKey(const Key('midi_lo')), findsNothing);

      final sweep = control.state.controllerBindings.bindings
          .whereType<ContinuousBinding>()
          .single;
      await tester.tap(find.byKey(Key('midi_mapping_11_${sweep.target}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('midi_lo')), findsOneWidget);
      expect(find.byKey(const Key('midi_hi')), findsOneWidget);
      expect(find.byKey(const Key('midi_relearn')), findsOneWidget);
      expect(find.byKey(const Key('midi_remove')), findsOneWidget);
      // A sweep has travel, not a threshold and a behaviour.
      expect(find.byKey(const Key('midi_threshold')), findsNothing);
    });

    testWidgets('a switch mapping opens onto a threshold and a behaviour', (
      tester,
    ) async {
      await pump(tester, connection: connected);
      await control.setControllerBindings(mappings());
      await showMidi(tester);

      final discrete = control.state.controllerBindings.bindings
          .whereType<DiscreteBinding>()
          .single;
      await tester.tap(
        find.byKey(Key('midi_mapping_36_${discrete.target}')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('midi_threshold')), findsOneWidget);
      expect(find.byKey(const Key('midi_behavior')), findsOneWidget);
    });

    testWidgets('removing a mapping drops it from the set', (tester) async {
      await pump(tester, connection: connected);
      await control.setControllerBindings(mappings());
      await showMidi(tester);

      final sweep = control.state.controllerBindings.bindings
          .whereType<ContinuousBinding>()
          .single;
      await tester.tap(find.byKey(Key('midi_mapping_11_${sweep.target}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('midi_remove')));
      // Past the mappings-write debounce: the binding leaves the widget tree
      // long before the persist does, and a pending timer fails the binding.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(
        control.state.controllerBindings.bindings
            .whereType<ContinuousBinding>(),
        isEmpty,
      );
    });

    testWidgets('the add buttons are inert with no device attached', (
      tester,
    ) async {
      await pump(tester);
      await showMidi(tester);

      expect(
        tester
            .widget<ConsoleActionChip>(find.byKey(const Key('midi_add_sweep')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('midi_idle_notice')), findsOneWidget);
    });
  });
}
