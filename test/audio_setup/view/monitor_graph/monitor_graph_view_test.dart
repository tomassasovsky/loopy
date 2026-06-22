import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_view.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('MonitorGraphView', () {
    late LooperRepository repository;
    late MonitorCubit cubit;

    setUp(() {
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      cubit = MonitorCubit(
        repository: repository,
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
    });

    tearDown(() => repository.dispose());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpApp(
        BlocProvider<MonitorCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: MonitorGraphView(inputChannels: 3, outputChannels: 2),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tapping an input starts monitoring it and focuses lane 0', (
      tester,
    ) async {
      await pump(tester);
      expect(cubit.state.forInput(0).enabled, isFalse);

      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).enabled, isTrue);
      // Its lane node and the focused-lane panel (add-lane) now show.
      expect(
        find.byKey(const Key('monitorGraph_laneNode_0_0')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('monitorGraph_addLane')), findsOneWidget);
    });

    testWidgets('renders one node per (input, lane)', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      await cubit.addLane(0);
      await pump(tester);

      expect(
        find.byKey(const Key('monitorGraph_laneNode_0_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('monitorGraph_laneNode_0_1')),
        findsOneWidget,
      );
    });

    testWidgets('a lane node is a labelled, focusable button', (tester) async {
      final handle = tester.ensureSemantics();
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      final node = tester.getSemantics(
        find.byKey(const Key('monitorGraph_laneNode_0_0')),
      );
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      expect(node.label, isNotEmpty);
      handle.dispose();
    });

    testWidgets('an output chip names its sharing state (1.4.1)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      // The colour-only sharing state (shared / dedicated / unused output) is
      // spelled out in the accessible label for assistive tech.
      final node = tester.getSemantics(
        find.byKey(const Key('monitorGraph_out_1')),
      );
      expect(node.label, contains('output'));
      handle.dispose();
    });

    testWidgets('tapping an output wires the focused lane', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).lane(0).outputMask, 0x3);

      // Toggling Out 2 (index 1) -> 0x3 ^ 0x2 = 0x1.
      await tester.tap(find.byKey(const Key('monitorGraph_out_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).lane(0).outputMask, 0x1);
    });

    testWidgets('add-lane appends a lane; remove-lane drops it', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_addLane')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).laneCount, 2);

      // Focus the second lane and remove it.
      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('monitorGraph_removeLane')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).laneCount, 1);
    });

    testWidgets('the add button appends an effect to the focused lane', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_addFx_0')));
      await tester.pumpAndSettle();

      expect(
        cubit.state.forInput(0).lane(0).effects.single.type,
        TrackEffectType.drive,
      );
      expect(find.byKey(const Key('monitorGraph_fx_0_0')), findsOneWidget);
    });

    testWidgets('selecting an effect opens its editor; type + remove work', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      cubit.addEffect(0, 0);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_fxLabel_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_fxEditor')), findsOneWidget);

      await tester.tap(find.byKey(const Key('monitorGraph_fxType')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delay').last);
      await tester.pumpAndSettle();
      expect(
        cubit.state.forInput(0).lane(0).effects.single.type,
        TrackEffectType.delay,
      );

      await tester.tap(find.byKey(const Key('monitorGraph_fxRemove')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).lane(0).effects, isEmpty);
    });

    testWidgets('the per-card delete removes that effect', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      cubit
        ..addEffect(0, 0)
        ..addEffect(0, 0);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_fxDelete_0_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).lane(0).effects, hasLength(1));
    });

    testWidgets('dragging an effect handle reorders the chain', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      cubit
        ..addEffect(0, 0)
        ..setEffectType(0, 0, 0, TrackEffectType.drive)
        ..addEffect(0, 0)
        ..setEffectType(0, 0, 1, TrackEffectType.delay);
      await pump(tester);

      // Reordering uses the gap-index drop zones (the unified convention):
      // drop the first card into the gap after the last one.
      final handle = find.byKey(const Key('monitorGraph_fxHandle_0_0'));
      final target = find.byKey(const Key('monitorGraph_drop_0_2'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        cubit.state.forInput(0).lane(0).effects.map((e) => e.type),
        [TrackEffectType.delay, TrackEffectType.drive],
      );
    });

    testWidgets('an excluded (loopback) input cannot be monitored', (
      tester,
    ) async {
      await tester.pumpApp(
        BlocProvider<MonitorCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: MonitorGraphView(
              inputChannels: 3,
              outputChannels: 2,
              excludedInputMask: 0x1, // In 1 is loopback
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).enabled, isFalse);
    });

    testWidgets('re-tapping the focused node unfocuses it', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_addLane')), findsOneWidget);

      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_addLane')), findsNothing);
    });

    testWidgets('tapping the background unfocuses the lane', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_addLane')), findsOneWidget);

      final canvas = tester.widget<GraphCanvas>(find.byType(GraphCanvas));
      expect(canvas.onTapBackground, isNotNull);
      canvas.onTapBackground!();
      await tester.pumpAndSettle();

      // Focus cleared: the panel returns to the hint, monitoring stays enabled.
      expect(find.byKey(const Key('monitorGraph_addLane')), findsNothing);
      expect(cubit.state.forInput(0).enabled, isTrue);
    });

    testWidgets('tapping an output with nothing focused is a no-op', (
      tester,
    ) async {
      // Enabling via the cubit does not focus a lane, so no output is wired.
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_out_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).lane(0).outputMask, 0x3); // unchanged
    });

    testWidgets('Stop disables monitoring of the focused input', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_laneNode_0_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_stop')));
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).enabled, isFalse);
    });

    testWidgets('an output chip reached by a lane is wired', (tester) async {
      // Input 0 monitored, lane 0 routed to Out 1 only (bit 0). Nothing is
      // focused (focus is view-local and starts null), so the chips reflect the
      // routed union.
      await cubit.setEnabled(0, enabled: true);
      await cubit.setLaneOutputMask(0, 0, 0x1);
      await pump(tester);

      final routed = tester.widget<ChannelChip>(
        find.byKey(const Key('monitorGraph_out_0')),
      );
      final unrouted = tester.widget<ChannelChip>(
        find.byKey(const Key('monitorGraph_out_1')),
      );
      expect(routed.wired, isTrue);
      expect(unrouted.wired, isFalse);
    });
  });
}
