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

    testWidgets('opens the single-track signal-flow graph', (tester) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('trackRouting_dialog')), findsOneWidget);
      expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
      // Exactly one track node (this track) in the middle column.
      expect(find.byKey(const Key('routingNode_track_0')), findsOneWidget);
    });

    testWidgets('clicking an input node dispatches LooperInputMaskChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The track is pre-armed (initialArmed: 0); default input mask is 0x1, so
      // clicking input 2 (index 1) adds it -> 0x3.
      await tester.tap(find.byKey(const Key('routingNode_input_1')));
      await tester.pump();

      verify(() => bloc.add(const LooperInputMaskChanged(0, 0x3))).called(1);
    });

    testWidgets('clicking an output node dispatches LooperOutputMaskChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Output mask 0x3 (0+1); clicking output 1 (index 0) removes it -> 0x2.
      await tester.tap(find.byKey(const Key('routingNode_output_0')));
      await tester.pump();

      verify(() => bloc.add(const LooperOutputMaskChanged(0, 0x2))).called(1);
    });

    testWidgets('choosing a quantize override dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trackRouting_quantize_on')));
      await tester.pump();
      verify(
        () => bloc.add(const LooperTrackQuantizeChanged(0, enabled: true)),
      ).called(1);

      await tester.tap(find.byKey(const Key('trackRouting_quantize_off')));
      await tester.pump();
      verify(
        () => bloc.add(const LooperTrackQuantizeChanged(0, enabled: false)),
      ).called(1);
    });

    testWidgets('the Default chips name the resolved global value', (
      tester,
    ) async {
      await settings.saveQuantize(value: true);
      await settings.saveDefaultMultiple(2);
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Default (On)'), findsOneWidget);
      expect(find.text('Default (×2)'), findsOneWidget);
    });

    testWidgets('choosing a loop multiple dispatches the change', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trackRouting_multiple_2')));
      await tester.pump();
      verify(
        () => bloc.add(const LooperTrackMultipleChanged(0, 2)),
      ).called(1);
    });

    testWidgets('adding an after-track effect dispatches the chain', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final add = find.byKey(const Key('trackRouting_fx_addPost'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();

      // A default (drive, post) effect is appended and its editor opens.
      verify(
        () => bloc.add(
          any(
            that: isA<LooperTrackEffectsChanged>()
                .having((e) => e.channel, 'channel', 0)
                .having((e) => e.effects.length, 'length', 1)
                .having(
                  (e) => e.effects.first.stage,
                  'stage',
                  TrackEffectStage.post,
                ),
          ),
        ),
      ).called(1);
      expect(find.byKey(const Key('trackRouting_fx_card_0')), findsOneWidget);
    });

    testWidgets('the card editor shows the type and its parameter sliders', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('trackRouting_fx_type')), findsNothing);

      final add = find.byKey(const Key('trackRouting_fx_addPre'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();

      // The editor opens for the new effect: type selector + drive's params.
      expect(find.byKey(const Key('trackRouting_fx_type')), findsOneWidget);
      expect(find.byKey(const Key('trackRouting_fx_param0')), findsOneWidget);
      expect(find.byKey(const Key('trackRouting_fx_param1')), findsOneWidget);
    });

    testWidgets('moving an effect across the track changes its stage', (
      tester,
    ) async {
      // Start with one after-track effect (selected, editor open).
      await settings.saveTrackEffects(
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('trackRouting_fx_card_0'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();

      final before = find.text('Before track');
      await tester.ensureVisible(before);
      await tester.tap(before);
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperTrackEffectsChanged>().having(
              (e) => e.effects.first.stage,
              'stage',
              TrackEffectStage.pre,
            ),
          ),
        ),
      ).called(1);
    });

    testWidgets('dragging a param slider dispatches the granular param event', (
      tester,
    ) async {
      await settings.saveTrackEffects(
        0,
        encodeTrackEffects([TrackEffect(type: TrackEffectType.drive)]),
      );
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('trackRouting_fx_card_0'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();

      final slider = find.byKey(const Key('trackRouting_fx_param0'));
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(200, 0));
      await tester.pump();

      verify(
        () => bloc.add(
          any(
            that: isA<LooperTrackEffectParamChanged>()
                .having((e) => e.channel, 'channel', 0)
                .having((e) => e.index, 'index', 0)
                .having((e) => e.param, 'param', 0),
          ),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    testWidgets('a saved effect chain is preloaded into the dialog', (
      tester,
    ) async {
      await settings.saveTrackEffects(
        0,
        encodeTrackEffects([
          TrackEffect(
            type: TrackEffectType.tremolo,
            stage: TrackEffectStage.pre,
          ),
          TrackEffect(type: TrackEffectType.delay),
        ]),
      );
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Both saved effects render as cards.
      expect(find.byKey(const Key('trackRouting_fx_card_0')), findsOneWidget);
      expect(find.byKey(const Key('trackRouting_fx_card_1')), findsOneWidget);
      expect(find.text('Tremolo'), findsWidgets);
      expect(find.text('Delay'), findsWidgets);
    });
  });
}
