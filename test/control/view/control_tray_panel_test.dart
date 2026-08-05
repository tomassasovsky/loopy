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
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

TrackEffect _fx(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  late AppLocalizations l10n;
  late ControlCubit control;
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late _MockMidiDeviceRepository midiDevices;
  late StreamController<MidiConnection> connections;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenAnswer(
      (_) => {3: const FxChainEnvelope()},
    );
    when(() => looper.trackEffects(any())).thenAnswer(
      (i) => i.positionalArguments[0] == 3 ? [_fx('a'), _fx('b')] : const [],
    );
    when(() => looper.masterEffects).thenReturn(const []);
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(
      () => looper.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());

    midiDevices = _MockMidiDeviceRepository();
    connections = StreamController<MidiConnection>.broadcast();
    when(() => midiDevices.connections).thenAnswer((_) => connections.stream);
    when(() => midiDevices.connection).thenReturn(const MidiConnection());
    when(() => midiDevices.activity).thenAnswer(
      (_) => const Stream<void>.empty(),
    );
    when(midiDevices.refresh).thenAnswer((_) async {});
  });

  tearDown(() async {
    await looperStates.close();
    await connections.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    ControlTab tab = ControlTab.pedal,
  }) async {
    // The console is 1920x1080 and these faces are built for it; the default
    // 800x600 surface pushes the mapping list below the fold, where a tap
    // lands on nothing.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: SettingsRepository(store: FakeKeyValueStore()),
      performance: performance,
      keepAliveInterval: Duration.zero,
      // Otherwise the mappings write debounce outlives the widget tree and
      // the binding fails the test on a pending timer.
      mappingsWriteDebounce: Duration.zero,
    );
    // unawaited: awaiting ControlCubit.close() inside a testWidgets body
    // deadlocks on the Flutter test binding's stream cancellation.
    addTearDown(() => unawaited(control.close()));
    final midi = MidiSetupCubit(repository: midiDevices);
    addTearDown(() => unawaited(midi.close()));
    var current = tab;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<MidiSetupCubit>.value(value: midi),
            ],
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(19),
                child: StatefulBuilder(
                  builder: (context, setState) => ControlTrayPanel(
                    tab: current,
                    onTabChanged: (next) => setState(() => current = next),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Installs one switch mapping the way an edit does, then settles the UI.
  Future<void> seedSwitchMapping(WidgetTester tester) async {
    await control.setControllerBindings(
      ControllerBindingSet([
        DiscreteBinding(
          trigger: const MappingTrigger(
            kind: ControllerSourceKind.midiNote,
            id: 36,
            midiChannel: 0,
          ),
          target: looper.availableBindingTargets().first.canonicalString(),
        ),
      ]),
    );
    await tester.pumpAndSettle();
  }

  group('the Control domain', () {
    testWidgets('names itself above the tab strip, with no chrome bar', (
      tester,
    ) async {
      await pump(tester);

      // The mockups put the domain's name at the top of the pane and the tabs
      // under it — the opposite of the Network face, whose tabs come first
      // because each of its bodies carries its own titled row.
      expect(find.text(l10n.trayControlLabel), findsOneWidget);
      expect(find.byKey(const Key('control_tabs')), findsOneWidget);
      expect(find.byKey(const Key('pedal_control_tab')), findsOneWidget);
      expect(find.byKey(const Key('midi_control_tab')), findsNothing);
    });

    testWidgets('the strip swaps the body', (tester) async {
      await pump(tester);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('control_tabs')),
          matching: find.text(l10n.controlMidiTab),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('midi_control_tab')), findsOneWidget);
      expect(find.byKey(const Key('pedal_control_tab')), findsNothing);
    });
  });

  group('Pedal tab', () {
    testWidgets('shows the transport cards and the track rows', (
      tester,
    ) async {
      await pump(tester);

      for (final button in [
        PedalButton.recPlay,
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
      ]) {
        expect(
          find.byKey(Key('pedal_switch_${button.name}')),
          findsOneWidget,
          reason: 'no card for ${button.name}',
        );
      }
      // Mode and Bank can never hold a binding (B12), so they get no card
      // and no row.
      expect(find.byKey(const Key('pedal_switch_mode')), findsNothing);
      expect(find.byKey(const Key('pedal_switch_bank')), findsNothing);
      // Nothing selected: the track list is the only card on the face.
      expect(find.byType(ConsoleCard), findsOneWidget);
    });

    testWidgets('selecting a switch lists the racks it can drive', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      // The track list plus the assign list, under a caption that names what
      // is being assigned.
      expect(find.byType(ConsoleCard), findsNWidgets(2));
      expect(find.byKey(const Key('pedal_show_slots')), findsOneWidget);
      expect(
        find.text(
          l10n
              .pedalControlAssign(
                pedalButtonLabel(l10n, PedalButton.recPlay),
              )
              .toUpperCase(),
        ),
        findsOneWidget,
      );
    });

    testWidgets('individual effects are one tap further down', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      final beforeRows = tester.widgetList(find.byType(ConsoleRow)).length;

      await tester.tap(find.byKey(const Key('pedal_show_slots')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pedal_show_slots')), findsNothing);
      expect(
        tester.widgetList(find.byType(ConsoleRow)).length,
        greaterThanOrEqualTo(beforeRows),
      );
    });

    testWidgets('choosing a target assigns the switch', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_stop')));
      await tester.pumpAndSettle();

      final target = looper.availableBindingTargets().first;
      await tester.tap(
        find.byKey(Key('pedal_target_${target.canonicalString().hashCode}')),
      );
      await tester.pumpAndSettle();

      final binding = control.state.bindings.bindings
          .where(
            (b) => b.key == const PedalBindingKey(button: PedalButton.stop),
          )
          .firstOrNull;
      expect(binding, isNotNull);
      expect(binding!.target, target.canonicalString());
      // The chosen target is marked in the list — checked, not tinted, so it
      // cannot be confused with the row that is open.
      expect(find.byKey(const Key('pedal_target_current')), findsOneWidget);
      // The card now names what it drives instead of saying "unassigned".
      expect(
        find.descendant(
          of: find.byKey(const Key('pedal_switch_stop')),
          matching: find.text(l10n.pedalControlUnassigned),
        ),
        findsNothing,
      );
    });
  });

  group('MIDI tab', () {
    testWidgets('shows the device, its status and the mapping list', (
      tester,
    ) async {
      await pump(tester, tab: ControlTab.midi);

      expect(find.byKey(const Key('midi_device_row')), findsOneWidget);
      expect(find.byKey(const Key('midi_status_connection')), findsOneWidget);
      // No device in this harness, so no traffic line and an idle notice.
      expect(find.byKey(const Key('midi_status_traffic')), findsNothing);
      expect(find.byKey(const Key('midi_idle_notice')), findsOneWidget);
      expect(find.text(l10n.midiControlFixedCcs), findsOneWidget);
      expect(find.byKey(const Key('midi_mapping_empty')), findsOneWidget);
    });

    testWidgets('each device fault says what it actually is', (tester) async {
      // The repository tells four states apart; a face that calls them all
      // "no MIDI device" sends the operator looking in the wrong place.
      for (final probe in [
        (
          // `none` is the default, spelled out so the case list reads as
          // four states rather than three and a blank.
          const MidiConnection(),
          (AppLocalizations l) => l.midiControlNoDeviceDetail,
        ),
        (
          const MidiConnection(
            status: MidiConnectionStatus.deviceGone,
            selectedId: 'p',
            selectedName: 'Nektar Pacer',
          ),
          (AppLocalizations l) => l.midiControlDeviceGone('Nektar Pacer'),
        ),
        (
          const MidiConnection(
            status: MidiConnectionStatus.error,
            selectedId: 'p',
            selectedName: 'Nektar Pacer',
          ),
          (AppLocalizations l) => l.midiControlOpenFailed('Nektar Pacer'),
        ),
      ]) {
        when(() => midiDevices.connection).thenReturn(probe.$1);
        await pump(tester, tab: ControlTab.midi);

        expect(find.text(probe.$2(l10n)), findsOneWidget);
        // ...and the mappings say why they cannot fire.
        expect(find.byKey(const Key('midi_idle_notice')), findsOneWidget);
        // No traffic line while there is nothing to carry traffic.
        expect(find.byKey(const Key('midi_status_traffic')), findsNothing);
      }
    });

    testWidgets('a connected device reports its traffic and no idle notice', (
      tester,
    ) async {
      when(() => midiDevices.connection).thenReturn(
        const MidiConnection(
          status: MidiConnectionStatus.connected,
          selectedId: 'p',
          selectedName: 'Nektar Pacer',
        ),
      );
      await pump(tester, tab: ControlTab.midi);

      expect(
        find.text(l10n.midiControlConnected('Nektar Pacer')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('midi_status_traffic')), findsOneWidget);
      expect(find.byKey(const Key('midi_idle_notice')), findsNothing);
    });

    testWidgets('a mapping opens to its calibration and actions', (
      tester,
    ) async {
      await pump(tester, tab: ControlTab.midi);
      await seedSwitchMapping(tester);

      expect(find.text(l10n.midiControlSwitch), findsOneWidget);
      expect(find.byKey(const Key('midi_mapping_thresh')), findsNothing);

      await tester.tap(find.byKey(const Key('midi_mapping_row')).first);
      await tester.pumpAndSettle();

      // A switch calibrates on its threshold and its behaviour; a sweep would
      // show LO and HI instead.
      expect(find.byKey(const Key('midi_mapping_thresh')), findsOneWidget);
      expect(find.byKey(const Key('midi_mapping_behavior')), findsOneWidget);
      expect(find.byKey(const Key('midi_mapping_relearn')), findsOneWidget);
      expect(find.byKey(const Key('midi_mapping_remove')), findsOneWidget);
    });

    testWidgets('removing a mapping drops it from the list', (tester) async {
      await pump(tester, tab: ControlTab.midi);
      await seedSwitchMapping(tester);
      await tester.tap(find.byKey(const Key('midi_mapping_row')).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('midi_mapping_remove')));
      await tester.pumpAndSettle();

      expect(control.state.controllerBindings.bindings, isEmpty);
      expect(find.byKey(const Key('midi_mapping_empty')), findsOneWidget);
    });

    testWidgets(
      'the add buttons are inert while no device is delivering MIDI',
      (tester) async {
        await pump(tester, tab: ControlTab.midi);

        // A capture with nothing to listen to would wait forever.
        final sweep = tester.widget<ConsoleSmallButton>(
          find.byKey(const Key('midi_add_sweep')),
        );
        final sw = tester.widget<ConsoleSmallButton>(
          find.byKey(const Key('midi_add_switch')),
        );
        expect(sweep.onPressed, isNull);
        expect(sw.onPressed, isNull);
      },
    );
  });
}
