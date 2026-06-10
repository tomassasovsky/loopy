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
  });
}
