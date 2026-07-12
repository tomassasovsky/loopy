import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/session/session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  group('SessionMonitorSyncListener', () {
    late _MockLooperRepository looper;
    late SettingsRepository settings;
    late MonitorCubit monitor;
    late _MockSessionCubit session;

    setUp(() {
      looper = _MockLooperRepository();
      settings = SettingsRepository(store: FakeKeyValueStore());
      monitor = MonitorCubit(repository: looper, settings: settings);
      session = _MockSessionCubit();
      when(looper.allMonitors).thenReturn(const {
        1: InputMonitor(input: 1, enabled: true, outputMask: 0x2),
      });
    });

    tearDown(() async {
      await monitor.close();
      await session.close();
    });

    Widget subject() => MultiBlocProvider(
      providers: [
        BlocProvider<MonitorCubit>.value(value: monitor),
        BlocProvider<SessionCubit>.value(value: session),
      ],
      child: const SessionMonitorSyncListener(
        child: SizedBox(),
      ),
    );

    testWidgets('re-syncs the MonitorCubit on a loaded outcome', (
      tester,
    ) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.loaded,
          ),
        ]),
        initialState: const SessionState(),
      );

      await tester.pumpWidget(subject());
      await tester.pump(); // deliver the streamed state to the listener
      await tester.pump(); // let the awaited syncFromRepository settle

      expect(monitor.state.forInput(1).enabled, isTrue);
      expect(monitor.state.forInput(1).outputMask, 0x2);
    });

    testWidgets('ignores non-loaded outcomes (e.g. saved)', (tester) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.saved,
          ),
        ]),
        initialState: const SessionState(),
      );

      await tester.pumpWidget(subject());
      await tester.pump();
      await tester.pump();

      expect(monitor.state.inputs, isEmpty);
      verifyNever(looper.allMonitors);
    });
  });
}
