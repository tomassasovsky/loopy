import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/signal_graph/signal_list_view.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(const LooperLaneVolumeChanged(0, 0, 0));
  });

  group('SignalListView', () {
    late LooperBloc bloc;
    late MonitorCubit monitor;
    late LooperRepository repository;

    LooperState stateWith({
      List<Track> tracks = const [
        Track(lanes: [Lane(inputChannel: 1, outputMask: 0x2)]),
      ],
      int outputEnabledMask = 0xFFFFFFFF,
    }) => LooperState(
      tracks: tracks,
      status: const EngineStatus(
        inputChannels: 3,
        outputChannels: 2,
        isConnected: true,
      ),
      outputEnabledMask: outputEnabledMask,
    );

    void seed(LooperState state) => whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: state,
    );

    setUp(() {
      bloc = _MockLooperBloc();
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      monitor = MonitorCubit(
        repository: repository,
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
    });

    tearDown(() => repository.dispose());

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(1200, 900),
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<MonitorCubit>.value(value: monitor),
            ],
            child: const Scaffold(body: SignalListView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'every tap target has a semantic label (labeledTapTargetGuideline)',
      (tester) async {
        // The regression net for this surface's hand-labeling: a tappable node
        // added without a Semantics label (an icon-only IconButton, a bare
        // GestureDetector, a FocusableTapTarget with no label) fails it.
        // A track with a lane exercises the routing chips, mute, and knob.
        final handle = tester.ensureSemantics();
        seed(stateWith());
        await pump(tester);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      },
    );

    testWidgets('renders an input/output row per channel and a track row', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      expect(find.byKey(const Key('signalIn_0')), findsOneWidget);
      expect(find.byKey(const Key('signalIn_2')), findsOneWidget);
      expect(find.byKey(const Key('signalOut_0')), findsOneWidget);
      expect(find.byKey(const Key('signalOut_1')), findsOneWidget);
      expect(find.byKey(const Key('signalTake_0_0')), findsOneWidget);
    });

    testWidgets('a single-lane track reads as the track, not "Lane 1"', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);
      // The track's own row reads as the track (a feeder chip on an output card
      // may also say "Track 1", so scope to the take row itself).
      expect(
        find.descendant(
          of: find.byKey(const Key('signalTake_0_0')),
          matching: find.text('Track 1'),
        ),
        findsOneWidget,
      );
      expect(find.text('Lane 1'), findsNothing);
    });

    testWidgets('an output card groups feeders into input + track chip rows', (
      tester,
    ) async {
      // Track 1 routes to Out 2 (mask 0x2); also monitor input 0 to Out 2 so
      // the card has both kinds of feeder (an input only feeds when live).
      seed(stateWith());
      await monitor.setEnabled(0, enabled: true);
      await monitor.setOutputMask(0, 0x2);
      await pump(tester);

      final out = find.byKey(const Key('signalOut_1'));
      // Two labelled rows: inputs and tracks, each with its own chip.
      expect(find.descendant(of: out, matching: find.text('IN')), findsOne);
      expect(find.descendant(of: out, matching: find.text('TRK')), findsOne);
      expect(find.descendant(of: out, matching: find.text('In 1')), findsOne);
      expect(
        find.descendant(of: out, matching: find.text('Track 1')),
        findsOne,
      );
    });

    testWidgets('an output with no feeders says so', (tester) async {
      seed(stateWith()); // only Out 2 is fed; Out 1 is empty.
      await pump(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('signalOut_0')),
          matching: find.text('nothing routed here'),
        ),
        findsOne,
      );
    });

    testWidgets('a multi-lane track nests its takes', (tester) async {
      seed(
        stateWith(
          tracks: const [
            Track(lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)]),
          ],
        ),
      );
      await pump(tester);
      expect(find.byKey(const Key('signalTake_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signalTake_0_1')), findsOneWidget);
      expect(find.text('Lane 1'), findsOneWidget);
      expect(find.text('Lane 2'), findsOneWidget);
    });

    testWidgets('tapping an input card traces without changing its gate', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);
      expect(monitor.state.forInput(0).enabled, isFalse);

      bool anyDimmed() => tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .any((w) => w.opacity < 1);
      expect(anyDimmed(), isFalse);

      await tester.tap(find.byKey(const Key('signalIn_0')));
      await tester.pumpAndSettle();

      // Traced (unrelated rows dim) but monitoring is untouched.
      expect(anyDimmed(), isTrue);
      expect(monitor.state.forInput(0).enabled, isFalse);
    });

    testWidgets('the input FX summary opens the dock for that input', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalInFx_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fx_dock')), findsOneWidget);
      expect(find.text('Input 1'), findsOneWidget);
    });

    testWidgets('the take FX summary opens the dock for that lane', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalTakeFx_0_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fx_dock')), findsOneWidget);
      // The dock opened for the lane scope (its header reads "Lane 1").
      expect(find.text('Lane 1'), findsOneWidget);
    });

    testWidgets('the track FX row opens the dock on that track bus chain', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalTrackFx_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fx_dock')), findsOneWidget);
      expect(find.text('Track 1 bus'), findsOneWidget);
    });

    testWidgets('the master strip opens the dock on the Master insert', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      // The Master insert heads the outputs pane — no new page, no new tile.
      expect(find.byKey(const Key('signalMaster')), findsOneWidget);
      await tester.tap(find.byKey(const Key('signalMasterFx')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fx_dock')), findsOneWidget);
      expect(find.text('Master'), findsOneWidget);
    });

    testWidgets('the track FX row summarises the bus chain', (tester) async {
      seed(
        stateWith(
          tracks: [
            Track(
              lanes: const [Lane(inputChannel: 1)],
              effects: [BuiltInEffect(type: TrackEffectType.reverb)],
            ),
          ],
        ),
      );
      await pump(tester);

      // The bus chain is named on the surface, not only inside the dock.
      expect(find.text('Reverb'), findsOneWidget);
    });

    testWidgets('a multi-lane track hides empty lanes behind "all lanes"', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(inputChannel: 0, lengthFrames: 1000),
                Lane(inputChannel: 1),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      // A11: the recorded take is what you came to shape; the empty lane waits
      // behind the expander.
      expect(find.byKey(const Key('signalTake_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signalTake_0_1')), findsNothing);

      await tester.tap(find.byKey(const Key('signalAllLanes_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signalTake_0_1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('signalAllLanes_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signalTake_0_1')), findsNothing);
    });

    testWidgets('a track with nothing recorded still shows all its lanes', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
            ),
          ],
        ),
      );
      await pump(tester);

      // Hiding them would take the track's routing and mix off the surface.
      expect(find.byKey(const Key('signalTake_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signalTake_0_1')), findsOneWidget);
      expect(find.byKey(const Key('signalAllLanes_0')), findsNothing);
    });

    testWidgets('an inherited take carries its provenance badge', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(inputChannel: 1, lengthFrames: 10, inheritedFrom: [1]),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('signalInherited_0_0')), findsOneWidget);
      expect(find.text('Inherited'), findsOneWidget);
    });

    testWidgets(
      'the provenance badge follows the domain through detach and re-sync',
      (tester) async {
        // The lifecycle end to end, driven by real state EMISSIONS rather than
        // three static fixtures: a badge that stopped rebuilding when the
        // backing chain changed would pass the fixtures and fail here.
        LooperState withLane(Lane lane) => stateWith(
          tracks: [
            Track(lanes: [lane]),
          ],
        );
        final states = StreamController<LooperState>.broadcast();
        addTearDown(states.close);
        const inherited = Lane(
          inputChannel: 1,
          lengthFrames: 10,
          inheritedFrom: [1],
        );
        whenListen(
          bloc,
          states.stream,
          initialState: withLane(inherited),
        );
        await pump(tester);
        expect(find.byKey(const Key('signalInherited_0_0')), findsOneWidget);

        // Detach: the domain drops the marker on a wholesale replacement, and
        // the badge goes with it — the badge never asserts a link of its own.
        states.add(
          withLane(
            Lane(
              inputChannel: 1,
              lengthFrames: 10,
              effects: [BuiltInEffect(type: TrackEffectType.echo)],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('signalInherited_0_0')), findsNothing);

        // Re-sync stamps fresh provenance, and the badge comes back.
        states.add(
          withLane(
            Lane(
              inputChannel: 1,
              lengthFrames: 10,
              effects: [BuiltInEffect(type: TrackEffectType.drive)],
              inheritedFrom: const [1],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('signalInherited_0_0')), findsOneWidget);
      },
    );

    testWidgets('the re-sync action reaches the domain from the dock', (
      tester,
    ) async {
      // Wire the real repository so the dock's re-sync affordance is offered
      // for the reason it would be in the app: the lane's ROUTED input has an
      // audible chain to copy.
      repository
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 1)
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(inputChannel: 1, lengthFrames: 10, inheritedFrom: [1]),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalTakeFx_0_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fxDock_resync')));
      await tester.pump();

      verify(
        () => bloc.add(const LooperLaneChainResyncedFromInput(0, 0)),
      ).called(1);
    });

    testWidgets('re-sync is withheld when the input has nothing audible', (
      tester,
    ) async {
      repository.setLaneInput(channel: 0, lane: 0, inputChannel: 1);
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(inputChannel: 1, lengthFrames: 10, inheritedFrom: [1]),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalTakeFx_0_0')));
      await tester.pumpAndSettle();

      // An empty input chain is dry: copying it would do nothing.
      expect(find.byKey(const Key('fxDock_resync')), findsNothing);
    });

    testWidgets('adding a lane reveals it even on a track with a take', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(inputChannel: 0, lengthFrames: 1000),
                Lane(inputChannel: 1),
              ],
            ),
          ],
        ),
      );
      await pump(tester);
      // Collapsed by default: only the recorded take shows.
      expect(find.byKey(const Key('signalTake_0_1')), findsNothing);

      await tester.tap(find.byKey(const Key('signalGraph_addLane_0')));
      await tester.pumpAndSettle();

      // A fresh lane holds no audio, so without this the button would read as
      // a no-op — the track expands so the new lane is visible.
      expect(find.byKey(const Key('signalTake_0_1')), findsOneWidget);
    });

    testWidgets('remove-lane is withheld when the last lane holds audio', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [Lane(inputChannel: 0), Lane(lengthFrames: 1000)],
            ),
          ],
        ),
      );
      await pump(tester);

      // Lanes are a stack, so removal drops the LAST one — and the drill-in
      // may be hiding it. One tap must not destroy an unseen take.
      expect(find.byKey(const Key('signalGraph_removeLane_0')), findsNothing);
    });

    testWidgets('remove-lane stays available when the last lane is empty', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [Lane(lengthFrames: 1000), Lane(inputChannel: 1)],
            ),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalGraph_removeLane_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperLaneCountChanged(0, 1))).called(1);
    });

    testWidgets('a recording track shows every lane, even empty ones', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              state: TrackState.recording,
              lanes: [
                Lane(inputChannel: 0, lengthFrames: 1000),
                Lane(inputChannel: 1),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      // A lane being recorded right now has no captured length yet; hiding it
      // would take the take you are cutting off the surface.
      expect(find.byKey(const Key('signalTake_0_1')), findsOneWidget);
      expect(find.byKey(const Key('signalAllLanes_0')), findsNothing);
    });

    testWidgets('a detached take carries no provenance badge', (tester) async {
      seed(stateWith());
      await pump(tester);
      expect(find.byKey(const Key('signalInherited_0_0')), findsNothing);
    });

    testWidgets('a take shows no cache glyph while telemetry is off', (
      tester,
    ) async {
      // The default lane carries a null cacheState — the repository never
      // polled it — so the calm default view has nothing extra on it.
      seed(stateWith());
      await pump(tester);
      // Assert the glyph slot IS present and renders nothing, rather than
      // just that no Text is under the key: a missing key would satisfy the
      // latter for the wrong reason.
      expect(find.byKey(const Key('signalCache_0_0')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('signalCache_0_0')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('a take shows its cache glyph once a state is observed', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(
              lanes: [
                Lane(
                  inputChannel: 1,
                  outputMask: 0x2,
                  cacheState: LaneCacheState.cached,
                ),
              ],
            ),
          ],
        ),
      );
      await pump(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('signalCache_0_0')),
          matching: find.text('●'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the dock closes via its close affordance', (tester) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalInFx_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fx_dock')), findsOneWidget);

      await tester.tap(find.byKey(const Key('fxDock_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fx_dock')), findsNothing);
    });

    testWidgets('a single-lane track carries an add-lane control', (
      tester,
    ) async {
      seed(stateWith()); // single-lane track 0
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalGraph_addLane_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperLaneCountChanged(0, 2))).called(1);
    });

    testWidgets('the input card mute toggle mutes monitoring', (tester) async {
      seed(stateWith());
      await pump(tester);
      expect(monitor.state.forInput(0).muted, isFalse);

      await tester.tap(find.byKey(const Key('signalIn_0_mute')));
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).muted, isTrue);
    });

    testWidgets('a take card mute toggle dispatches the lane mute', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalTake_0_0_mute')));
      await tester.pump();
      verify(() => bloc.add(const LooperLaneMuteToggled(0, 0))).called(1);
    });

    testWidgets('dragging an input volume knob changes the volume', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);
      expect(monitor.state.forInput(0).volume, 1.0);

      final knob = find.byKey(const Key('signalIn_0_volume'));
      final gesture = await tester.startGesture(tester.getCenter(knob));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).volume, isNot(1.0));
    });

    testWidgets('dragging a take volume knob dispatches the lane volume', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      final knob = find.byKey(const Key('signalTake_0_0_volume'));
      final gesture = await tester.startGesture(tester.getCenter(knob));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      // The event is keyed to the right (track, lane) — a swapped pair would
      // fail this having-check.
      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneVolumeChanged>()
                .having((e) => e.channel, 'channel', 0)
                .having((e) => e.lane, 'lane', 0),
          ),
        ),
      ).called(greaterThan(0));
    });

    testWidgets('a multi-lane track can add and remove lanes', (tester) async {
      seed(
        stateWith(
          tracks: const [
            Track(lanes: [Lane(), Lane()]),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalGraph_removeLane_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperLaneCountChanged(0, 1))).called(1);

      await tester.tap(find.byKey(const Key('signalGraph_addLane_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperLaneCountChanged(0, 3))).called(1);
    });
    testWidgets('the gate dot toggles monitoring on and off', (tester) async {
      seed(stateWith());
      await pump(tester);
      expect(monitor.state.forInput(0).enabled, isFalse);

      await tester.tap(find.byKey(const Key('signalInGate_0')));
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).enabled, isTrue);

      await tester.tap(find.byKey(const Key('signalInGate_0')));
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).enabled, isFalse);
    });

    testWidgets('the input gate names its on/off state for a11y', (
      tester,
    ) async {
      // The lit/dim dot replaced the LIVE/OFF pill, so state must stay exposed
      // to assistive tech by label — never by colour/opacity alone — and the
      // gate must still announce as an interactive toggle, not static text.
      final handle = tester.ensureSemantics();
      seed(stateWith());
      await pump(tester);

      final gate = find.byKey(const Key('signalInGate_0'));
      final off = tester.getSemantics(gate);
      expect(off, isSemantics(isButton: true, hasTapAction: true));
      expect(off.label.toLowerCase(), contains('off'));

      await tester.tap(gate);
      await tester.pumpAndSettle();

      final on = tester.getSemantics(gate);
      expect(on, isSemantics(isButton: true, hasTapAction: true));
      expect(on.label.toLowerCase(), contains('live'));
      handle.dispose();
    });

    testWidgets('toggling an input route chip updates its output mask', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);
      // A routed input must be live (an off input shows no chips).
      await tester.tap(find.byKey(const Key('signalInGate_0')));
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).outputMask, 0x3);

      // Lit chip for Out 2 (index 1) -> remove it -> 0x3 ^ 0x2 = 0x1.
      await tester.tap(find.byKey(const Key('signalIn_0_chip_1')));
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(0).outputMask, 0x1);
    });

    testWidgets(
      'toggling a take route chip dispatches the lane output change',
      (
        tester,
      ) async {
        seed(stateWith()); // lane routes to Out 2 (mask 0x2)
        await pump(tester);

        await tester.tap(find.byKey(const Key('signalTake_0_0_chip_1')));
        await tester.pump();

        verify(
          () => bloc.add(const LooperLaneOutputChanged(0, 0, 0)),
        ).called(1);
      },
    );

    testWidgets('reassigning a take input dispatches the capture change', (
      tester,
    ) async {
      seed(
        stateWith(
          tracks: const [
            Track(lanes: [Lane(outputMask: 0x2)]), // records nothing yet
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalCapture_0_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 1').last);
      await tester.pump();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, 0))).called(1);
    });

    testWidgets('the "None" picker option un-captures the take', (
      tester,
    ) async {
      seed(stateWith()); // lane records In 2 (inputChannel 1)
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalCapture_0_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None (clean)'));
      await tester.pump();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
    });

    testWidgets('multi-lane takes get distinct capture keys', (tester) async {
      seed(
        stateWith(
          tracks: const [
            Track(lanes: [Lane(), Lane()]), // two clean takes
          ],
        ),
      );
      await pump(tester);

      // Both badges exist with their own keys (no collision on inputChannel).
      expect(find.byKey(const Key('signalCapture_0_0')), findsOneWidget);
      expect(find.byKey(const Key('signalCapture_0_1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('signalCapture_0_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 1').last);
      await tester.pump();
      verify(() => bloc.add(const LooperLaneInputChanged(0, 1, 0))).called(1);
    });

    testWidgets('a loopback input row is inert', (tester) async {
      seed(
        LooperState(
          tracks: stateWith().tracks,
          status: const EngineStatus(
            inputChannels: 3,
            outputChannels: 2,
            isConnected: true,
            excludedInputMask: 0x4, // input 2 is loopback
          ),
        ),
      );
      await pump(tester);

      await tester.tap(
        find.byKey(const Key('signalIn_2')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(monitor.state.forInput(2).enabled, isFalse);
    });

    testWidgets('an off input names its off state for a11y', (tester) async {
      final handle = tester.ensureSemantics();
      seed(stateWith());
      await pump(tester);

      final node = tester.getSemantics(find.byKey(const Key('signalIn_1')));
      expect(node.label.toLowerCase(), contains('off'));
      handle.dispose();
    });

    testWidgets('dimmed rows stay focusable while tracing (visual-only)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(stateWith());
      await pump(tester);

      // Trace Out 1 (nothing routes there by default) -> In 1 dims but stays
      // a tappable semantics node.
      await tester.tap(find.byKey(const Key('signalOut_0')));
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.byKey(const Key('signalIn_0')));
      expect(node, isSemantics(hasTapAction: true));
      handle.dispose();
    });

    testWidgets('an enabled output toggles its gate off', (tester) async {
      seed(stateWith());
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalGraph_out_0')));
      await tester.pump();

      verify(
        () => bloc.add(const LooperOutputEnabledToggled(0, enabled: false)),
      ).called(1);
    });

    testWidgets('a gated-off output toggles back on', (tester) async {
      seed(stateWith(outputEnabledMask: 0));
      await pump(tester);

      await tester.tap(find.byKey(const Key('signalGraph_out_0')));
      await tester.pump();

      verify(
        () => bloc.add(const LooperOutputEnabledToggled(0, enabled: true)),
      ).called(1);
    });

    testWidgets('surfaces the no-active-outputs notice when all gated off', (
      tester,
    ) async {
      seed(stateWith(outputEnabledMask: 0));
      await pump(tester);
      expect(
        find.byKey(const Key('signalGraph_noActiveOutputs')),
        findsOneWidget,
      );
    });

    testWidgets('tap-to-trace dims unrelated rows, and clears on re-tap', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester);

      bool anyDimmed() => tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .any((w) => w.opacity < 1);
      expect(anyDimmed(), isFalse);

      await tester.tap(find.byKey(const Key('signalOut_0')));
      await tester.pumpAndSettle();
      expect(anyDimmed(), isTrue);

      await tester.tap(find.byKey(const Key('signalOut_0')));
      await tester.pumpAndSettle();
      expect(anyDimmed(), isFalse);
    });

    testWidgets('an output row names its gate state for a11y (1.4.1)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(stateWith());
      await pump(tester);

      final node = tester.getSemantics(find.byKey(const Key('signalOut_0')));
      expect(node.label.toLowerCase(), contains('output'));
      handle.dispose();
    });

    testWidgets('a narrow window switches the columns to tabs', (tester) async {
      seed(stateWith());
      await pump(tester, size: const Size(700, 1000));
      expect(find.byKey(const Key('signalList_tabbed')), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);
      // The inputs tab is shown first; outputs lives behind another tab.
      expect(find.byKey(const Key('signalIn_0')), findsOneWidget);
    });

    testWidgets('tabs switch between the lists on a narrow window', (
      tester,
    ) async {
      seed(stateWith());
      await pump(tester, size: const Size(700, 1000));
      expect(find.byKey(const Key('signalOut_0')), findsNothing);

      await tester.tap(find.textContaining('OUTPUTS'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signalOut_0')), findsOneWidget);
    });

    testWidgets('stays three panes on a wide window', (tester) async {
      seed(stateWith());
      await pump(tester);
      expect(find.byKey(const Key('signalList_tabbed')), findsNothing);
    });
  });
}
