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
        inputChannels: 2,
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
          child: BlocProvider<LooperBloc>.value(
            value: bloc,
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

    testWidgets('opens a single lane strip by default', (tester) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('trackRouting_page')), findsOneWidget);
      // One lane strip, with its input/output controls.
      expect(find.byKey(const Key('lane_0')), findsOneWidget);
      expect(find.byKey(const Key('lane_1')), findsNothing);
      expect(find.byKey(const Key('lane_0_input')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_output_0')), findsOneWidget);
      expect(find.text('Lane 1'), findsOneWidget);
    });

    testWidgets('choosing a lane input dispatches LooperLaneInputChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Open the input dropdown and select In 2 (channel index 1).
      await tester.tap(find.byKey(const Key('lane_0_input')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 2').last);
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneInputChanged(0, 0, 1))).called(1);
    });

    testWidgets('clicking an output chip dispatches LooperLaneOutputChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Default output mask 0x3 (out 1 + 2); toggling out 1 (index 0) -> 0x2.
      await tester.tap(find.byKey(const Key('lane_0_output_0')));
      await tester.pump();

      verify(
        () => bloc.add(const LooperLaneOutputChanged(0, 0, 0x2)),
      ).called(1);
    });

    testWidgets('toggling mute dispatches LooperLaneMuteToggled', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lane_0_mute')));
      await tester.pump();

      verify(() => bloc.add(const LooperLaneMuteToggled(0, 0))).called(1);
    });

    testWidgets('adding a lane dispatches LooperLaneCountChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trackRouting_addLane')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneCountChanged(0, 2))).called(1);
      // The second lane strip now renders and can be removed.
      expect(find.byKey(const Key('lane_1')), findsOneWidget);
      expect(find.byKey(const Key('lane_1_remove')), findsOneWidget);
    });

    testWidgets('removing the last lane dispatches the lower count', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trackRouting_addLane')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lane_1_remove')));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneCountChanged(0, 1))).called(1);
      expect(find.byKey(const Key('lane_1')), findsNothing);
    });

    testWidgets('choosing a quantize override dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Quantize / loop length live behind the AppBar settings button.
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

    testWidgets('choosing a loop multiple dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trackRouting_settings_button')));
      await tester.pumpAndSettle();

      final chip = find.byKey(const Key('trackRouting_multiple_2'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      verify(
        () => bloc.add(const LooperTrackMultipleChanged(0, 2)),
      ).called(1);
    });

    testWidgets('adding an effect dispatches the lane chain', (tester) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final add = find.byKey(const Key('lane_0_fx_add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();

      // A default (drive) effect is appended to lane 0 and its editor opens.
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
      expect(find.byKey(const Key('lane_0_fx_0')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_editor')), findsOneWidget);
    });

    testWidgets('the effect editor shows the type and parameter sliders', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lane_0_fx_type')), findsNothing);

      await tester.tap(find.byKey(const Key('lane_0_fx_add')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lane_0_fx_type')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_param0')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_param1')), findsOneWidget);
    });

    testWidgets('dragging a param slider dispatches the granular param event', (
      tester,
    ) async {
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Select the preloaded card to open its editor.
      await tester.tap(find.byKey(const Key('lane_0_fx_0')));
      await tester.pumpAndSettle();

      final slider = find.byKey(const Key('lane_0_fx_param0'));
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(200, 0));
      await tester.pump();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperLaneEffectParamChanged>()
                .having((e) => e.channel, 'channel', 0)
                .having((e) => e.lane, 'lane', 0)
                .having((e) => e.index, 'index', 0)
                .having((e) => e.param, 'param', 0),
          ),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('a saved per-lane chain is preloaded into the strip', (
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
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lane_0_fx_0')), findsOneWidget);
      expect(find.byKey(const Key('lane_0_fx_1')), findsOneWidget);
      expect(find.text('Tremolo'), findsWidgets);
      expect(find.text('Delay'), findsWidgets);
    });

    testWidgets('a saved lane count restores multiple strips', (tester) async {
      await settings.saveLaneCount(0, 2);
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lane_0')), findsOneWidget);
      expect(find.byKey(const Key('lane_1')), findsOneWidget);
      // Only the last lane in the stack is removable.
      expect(find.byKey(const Key('lane_0_remove')), findsNothing);
      expect(find.byKey(const Key('lane_1_remove')), findsOneWidget);
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
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lane_0_fx_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lane_0_fx_type')));
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
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final handle = find.byKey(const Key('lane_0_fx_handle_0'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
      }
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

    testWidgets('the add-lane button is disabled at the lane cap', (
      tester,
    ) async {
      await settings.saveLaneCount(0, 8); // LE_MAX_LANES
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final addLaneFinder = find.byKey(const Key('trackRouting_addLane'));
      await tester.scrollUntilVisible(
        addLaneFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final addLane = tester.widget<TextButton>(addLaneFinder);
      expect(addLane.onPressed, isNull);
    });
  });
}
