import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/audio_setup/view/monitor_graph/monitor_graph_view.dart';
import 'package:loopy/theme/surface_theme.dart';
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

    testWidgets('tapping an input starts monitoring it and focuses it', (
      tester,
    ) async {
      await pump(tester);
      expect(cubit.state.forInput(0).enabled, isFalse);

      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).enabled, isTrue);
      // Its monitor node and route toggle now show.
      expect(find.byKey(const Key('monitorGraph_node_0')), findsOneWidget);
      expect(find.byKey(const Key('monitorGraph_routeToggle')), findsOneWidget);
    });

    testWidgets('tapping an output wires the focused input wet send', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).outputMask, 0x3);

      // Wet mode is the default; toggling Out 2 (index 1) -> 0x3 ^ 0x2 = 0x1.
      await tester.tap(find.byKey(const Key('monitorGraph_out_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).outputMask, 0x1);
    });

    testWidgets('the Dry toggle routes output taps to the dry send', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).dryOutputMask, 0);

      // Switch the route toggle to Dry, then wire Out 1 (index 0) -> 0x1.
      await tester.tap(find.text('Dry'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('monitorGraph_out_0')));
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).dryOutputMask, 0x1);
      // The wet send is untouched.
      expect(cubit.state.forInput(0).outputMask, 0x3);
    });

    testWidgets('the add button appends an effect to the input', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('monitorGraph_in_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_addFx_0')));
      await tester.pumpAndSettle();

      expect(
        cubit.state.forInput(0).effects.single.type,
        TrackEffectType.drive,
      );
      expect(find.byKey(const Key('monitorGraph_fx_0_0')), findsOneWidget);
    });

    testWidgets('selecting an effect opens its editor; type + remove work', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      cubit.addEffect(0);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_fxLabel_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_fxEditor')), findsOneWidget);

      await tester.tap(find.byKey(const Key('monitorGraph_fxType')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delay').last);
      await tester.pumpAndSettle();
      expect(
        cubit.state.forInput(0).effects.single.type,
        TrackEffectType.delay,
      );

      await tester.tap(find.byKey(const Key('monitorGraph_fxRemove')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).effects, isEmpty);
    });

    testWidgets('the per-card delete removes that effect', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      cubit
        ..addEffect(0)
        ..addEffect(0);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_fxDelete_0_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).effects, hasLength(1));
    });

    testWidgets('dragging an effect handle reorders the chain', (tester) async {
      await cubit.setEnabled(0, enabled: true);
      cubit
        ..addEffect(0)
        ..setEffectType(0, 0, TrackEffectType.drive)
        ..addEffect(0)
        ..setEffectType(0, 1, TrackEffectType.delay);
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
        cubit.state.forInput(0).effects.map((e) => e.type),
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

      await tester.tap(find.byKey(const Key('monitorGraph_node_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_routeToggle')), findsOneWidget);

      await tester.tap(find.byKey(const Key('monitorGraph_node_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitorGraph_routeToggle')), findsNothing);
    });

    testWidgets('tapping an output with nothing focused is a no-op', (
      tester,
    ) async {
      // Enabling through the cubit does not focus a node, so no input is wired.
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);

      await tester.tap(find.byKey(const Key('monitorGraph_out_1')));
      await tester.pumpAndSettle();
      expect(cubit.state.forInput(0).outputMask, 0x3); // unchanged
    });

    testWidgets('Stop disables monitoring of the focused input', (
      tester,
    ) async {
      await cubit.setEnabled(0, enabled: true);
      await pump(tester);
      // Focus it.
      await tester.tap(find.byKey(const Key('monitorGraph_node_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('monitorGraph_stop')));
      await tester.pumpAndSettle();

      expect(cubit.state.forInput(0).enabled, isFalse);
    });

    testWidgets('an output reached only by a dry send is amber', (
      tester,
    ) async {
      // Seed: input 0 monitored, wet → Out 2 only, dry → Out 1 only. Nothing
      // is focused (focus is view-local and starts null), so the output chips
      // show their union colours.
      await cubit.setEnabled(0, enabled: true);
      await cubit.setOutputMask(0, 0x2); // wet → bit 1 (Out 2)
      await cubit.setDryOutputMask(0, 0x1); // dry → bit 0 (Out 1)
      await pump(tester);

      final context = tester.element(
        find.byKey(const Key('monitorGraph_out_0')),
      );
      final surface = context.surface;
      final dryOut = tester.widget<ChannelChip>(
        find.byKey(const Key('monitorGraph_out_0')),
      );
      final wetOut = tester.widget<ChannelChip>(
        find.byKey(const Key('monitorGraph_out_1')),
      );

      // Out 1 is reached only by the dry send → amber, wired, not emphasised.
      expect(dryOut.color, surface.dryRoute);
      expect(dryOut.wired, isTrue);
      expect(dryOut.strong, isFalse);
      // Out 2 is reached by the wet send → blue.
      expect(wetOut.color, surface.wetRoute);
    });
  });
}
