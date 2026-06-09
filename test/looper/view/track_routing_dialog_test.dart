import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/looper/view/track_routing_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  group('showTrackRoutingDialog', () {
    late LooperBloc bloc;

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
      whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    });

    Future<void> pumpOpener(WidgetTester tester) async {
      await tester.pumpApp(
        BlocProvider<LooperBloc>.value(
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
      );
    }

    testWidgets('opens the routing panel with input and output chips', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('trackRouting_dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('trackRouting_input_chip_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('trackRouting_output_chip_1')),
        findsOneWidget,
      );
    });

    testWidgets('toggling an input chip dispatches LooperInputMaskChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Default input mask is 0x1 (input 0); add input 1 -> 0x3.
      await tester.tap(find.byKey(const Key('trackRouting_input_chip_1')));
      await tester.pump();

      verify(() => bloc.add(const LooperInputMaskChanged(0, 0x3))).called(1);
    });

    testWidgets('toggling an output chip dispatches LooperOutputMaskChanged', (
      tester,
    ) async {
      await pumpOpener(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Output mask 0x3 (0+1); removing channel 0 -> 0x2.
      await tester.tap(find.byKey(const Key('trackRouting_output_chip_0')));
      await tester.pump();

      verify(() => bloc.add(const LooperOutputMaskChanged(0, 0x2))).called(1);
    });
  });
}
