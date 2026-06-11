import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/looper/view/track_routing_dialog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  setUpAll(() => registerFallbackValue(const LooperRecordPressed(0)));

  group('showTrackRoutingDialog', () {
    late LooperBloc bloc;
    late SettingsRepository settings;

    const state = LooperState(
      tracks: [Track()],
      status: EngineStatus(
        inputChannels: 3,
        outputChannels: 2,
        isConnected: true,
      ),
    );

    setUp(() {
      bloc = _MockLooperBloc();
      settings = SettingsRepository(store: FakeKeyValueStore());
      whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    });

    Future<void> pumpOpener(WidgetTester tester) async {
      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<BigPictureCubit>(
                create: (_) => BigPictureCubit(settings: settings),
              ),
            ],
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        showTrackRoutingDialog(context: context, channel: 0),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// Opens the dialog and focuses lane 0 (so input/output/mix taps apply).
    Future<void> open(WidgetTester tester, {bool focus = true}) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (focus) {
        await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('opens the unified lane graph', (tester) async {
      await pumpOpener(tester);
      await open(tester, focus: false);

      expect(find.byKey(const Key('trackRouting_page')), findsOneWidget);
      expect(find.byKey(const Key('trackRouting_laneGraph')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_in_0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_out_0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_laneNode_0')), findsOneWidget);
      expect(find.text('Lane 1'), findsWidgets);
    });

    testWidgets('wiring a focused lane input dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('laneGraph_in_1')));
      await tester.pump();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, 1))).called(1);
    });

    testWidgets('toggling a focused lane output dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('laneGraph_out_0')));
      await tester.pump();

      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 0, 0x2)),
      ).called(1);
    });

    testWidgets('muting a focused lane dispatches the toggle', (tester) async {
      await pumpOpener(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('laneGraph_mute')));
      await tester.pump();

      verify(() => bloc.add(const LooperLaneMuteToggled(0, 0))).called(1);
    });

    testWidgets('adding a lane dispatches LooperLaneCountChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('laneGraph_addLane')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneCountChanged(0, 2))).called(1);
      expect(find.byKey(const Key('laneGraph_laneNode_1')), findsOneWidget);
    });

    testWidgets('removing the last lane dispatches the lower count', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('laneGraph_addLane')));
      await tester.pumpAndSettle();
      // Focus the new last lane, then remove it.
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_removeLane')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneCountChanged(0, 1))).called(1);
      expect(find.byKey(const Key('laneGraph_laneNode_1')), findsNothing);
    });

    testWidgets('removing a non-last lane shifts later lanes up', (
      tester,
    ) async {
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(
          tracks: [
            Track(
              lanes: [
                Lane(outputMask: 0x1),
                Lane(inputChannel: 1, outputMask: 0x2),
              ],
            ),
          ],
          status: EngineStatus(
            inputChannels: 3,
            outputChannels: 2,
            isConnected: true,
          ),
        ),
      );
      await settings.saveLaneCount(0, 2);
      await pumpOpener(tester);
      await open(tester, focus: false);

      // Focus and remove lane 0; lane 1's routing shifts onto lane 0.
      await tester.tap(find.byKey(const Key('laneGraph_laneNode_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_removeLane')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, 1))).called(1);
      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 0, 0x2)),
      ).called(1);
      verify(() => bloc.add(const LooperLaneCountChanged(0, 1))).called(1);
    });

    testWidgets('choosing a quantize override dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('trackRouting_settings_button')));
      await tester.pumpAndSettle();

      final on = find.byKey(const Key('trackRouting_quantize_on'));
      await tester.ensureVisible(on);
      await tester.tap(on);
      await tester.pump();
      verify(
        () => bloc.add(const LooperTrackQuantizeChanged(0, enabled: true)),
      ).called(1);
    });

    testWidgets('adding an effect dispatches the lane chain and opens editor', (
      tester,
    ) async {
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('laneGraph_addFx_0')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneEffectsChanged>()
                .having((e) => e.channel, 'channel', 0)
                .having((e) => e.lane, 'lane', 0)
                .having((e) => e.effects.length, 'length', 1),
          ),
        ),
      ).called(1);
      expect(find.byKey(const Key('laneGraph_fx_0_0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fxEditor')), findsOneWidget);
    });

    testWidgets('changing an effect type dispatches the new chain', (
      tester,
    ) async {
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('laneGraph_fxLabel_0_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('laneGraph_fxType')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filter').last);
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneEffectsChanged>()
                .having((e) => e.lane, 'lane', 0)
                .having(
                  (e) => e.effects.single.type,
                  'type',
                  TrackEffectType.filter,
                ),
          ),
        ),
      ).called(1);
    });

    testWidgets('dragging a param slider dispatches the granular event', (
      tester,
    ) async {
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await pumpOpener(tester);
      await open(tester, focus: false);

      await tester.tap(find.byKey(const Key('laneGraph_fxLabel_0_0')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('laneGraph_fxParam0')),
        const Offset(160, 0),
      );
      await tester.pump();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneEffectParamChanged>()
                .having((e) => e.lane, 'lane', 0)
                .having((e) => e.index, 'index', 0)
                .having((e) => e.param, 'param', 0),
          ),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('dragging a card reorders the lane chain', (tester) async {
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([
          TrackEffect(type: TrackEffectType.drive),
          TrackEffect(type: TrackEffectType.delay),
        ]),
      );
      await pumpOpener(tester);
      await open(tester, focus: false);

      final handle = find.byKey(const Key('laneGraph_fx_handle_0_0'));
      final target = find.byKey(const Key('laneGraph_drop_0_2'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneEffectsChanged>().having(
              (e) => e.effects.map((f) => f.type).toList(),
              'order',
              [TrackEffectType.delay, TrackEffectType.drive],
            ),
          ),
        ),
      ).called(1);
    });

    testWidgets('a saved per-lane chain is preloaded onto its lane', (
      tester,
    ) async {
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([
          TrackEffect(type: TrackEffectType.tremolo),
          TrackEffect(type: TrackEffectType.delay),
        ]),
      );
      await pumpOpener(tester);
      await open(tester, focus: false);

      expect(find.byKey(const Key('laneGraph_fx_0_0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_fx_0_1')), findsOneWidget);
      expect(find.text('Tremolo'), findsWidgets);
      expect(find.text('Delay'), findsWidgets);
    });

    testWidgets('a saved lane count restores multiple lane nodes', (
      tester,
    ) async {
      await settings.saveLaneCount(0, 2);
      await pumpOpener(tester);
      await open(tester, focus: false);

      expect(find.byKey(const Key('laneGraph_laneNode_0')), findsOneWidget);
      expect(find.byKey(const Key('laneGraph_laneNode_1')), findsOneWidget);
    });

    testWidgets('the add-lane button is disabled at the lane cap', (
      tester,
    ) async {
      await settings.saveLaneCount(0, 8); // LE_MAX_LANES
      await pumpOpener(tester);
      await open(tester, focus: false);

      final addLane = tester.widget<TextButton>(
        find.byKey(const Key('laneGraph_addLane')),
      );
      expect(addLane.onPressed, isNull);
    });
  });
}
