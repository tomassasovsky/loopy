import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

/// Drains real-zone async so the bloc built in `setUp` finishes handling the
/// event the listener dispatched.
///
/// `setUp` runs OUTSIDE `testWidgets`' fake-async zone, so a bloc created there
/// schedules its event-stream microtasks — and the store writes those handlers
/// kick off — in the real zone, which `pump` / `pumpAndSettle` never flush.
/// Without this, an assertion on what the handler persisted reads the store
/// before anything was written: it would pass the negative test below no
/// matter what the code does.
Future<void> settleBlocEvents(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(Duration.zero));

void main() {
  group('SessionPersistenceSyncListener', () {
    late FakeAudioEngine engine;
    late LooperRepository looper;
    late SettingsRepository settings;
    late MonitorCubit monitor;
    late LooperBloc bloc;
    late _MockSessionCubit session;

    setUp(() {
      engine = FakeAudioEngine()
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
        );
      // A REAL repository over the fake engine, not a mock: the listener's two
      // halves both read the repository's own enumerations, so mocking them
      // would assert the test's fixture rather than the app's behaviour.
      looper = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      settings = SettingsRepository(store: FakeKeyValueStore());
      monitor = MonitorCubit(repository: looper, settings: settings);
      bloc = LooperBloc(repository: looper, settings: settings);
      session = _MockSessionCubit();
      looper
        ..setMonitorInputEnabled(input: 1, enabled: true)
        ..setMonitorOutput(input: 1, mask: 0x2);
    });

    tearDown(() async {
      await monitor.close();
      await bloc.close();
      await session.close();
      await looper.dispose();
    });

    Widget subject() => MultiBlocProvider(
      providers: [
        BlocProvider<MonitorCubit>.value(value: monitor),
        BlocProvider<LooperBloc>.value(value: bloc),
        BlocProvider<SessionCubit>.value(value: session),
      ],
      child: const SessionPersistenceSyncListener(
        child: SizedBox(),
      ),
    );

    void streamOutcome(SessionOutcome outcome) => whenListen(
      session,
      Stream.fromIterable([
        SessionState(status: SessionStatus.success, outcome: outcome),
      ]),
      initialState: const SessionState(),
    );

    testWidgets('re-syncs the MonitorCubit on a loaded outcome', (
      tester,
    ) async {
      streamOutcome(SessionOutcome.loaded);

      await tester.pumpWidget(subject());
      await tester.pump(); // deliver the streamed state to the listener
      await tester.pump(); // let the awaited syncFromRepository settle

      expect(monitor.state.forInput(1).enabled, isTrue);
      expect(monitor.state.forInput(1).outputMask, 0x2);
    });

    testWidgets('re-persists the applied chains on a loaded outcome', (
      tester,
    ) async {
      // The rig a load applies straight through the repository, past the bloc.
      looper
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
      streamOutcome(SessionOutcome.loaded);

      await tester.pumpWidget(subject());
      await tester.pump();
      await tester.pumpAndSettle();

      await settleBlocEvents(tester);
      expect(decodeFxChain(await settings.loadLaneEffects(0, 0)).entries, [
        isA<BuiltInEffect>().having(
          (e) => e.type,
          'type',
          TrackEffectType.drive,
        ),
      ]);
      expect(decodeFxChain(await settings.loadTrackFxChain(1)).entries, [
        isA<BuiltInEffect>().having(
          (e) => e.type,
          'type',
          TrackEffectType.reverb,
        ),
      ]);
      expect(decodeFxChain(await settings.loadMasterFxChain()).entries, [
        isA<BuiltInEffect>().having(
          (e) => e.type,
          'type',
          TrackEffectType.delay,
        ),
      ]);
    });

    testWidgets('ignores non-loaded outcomes (e.g. saved)', (tester) async {
      streamOutcome(SessionOutcome.saved);

      await tester.pumpWidget(subject());
      await tester.pump();
      await tester.pumpAndSettle();
      // Drain the same way the positive test does, or "nothing was written"
      // would hold simply because nothing had run yet.
      await settleBlocEvents(tester);

      expect(monitor.state.inputs, isEmpty);
      // Neither half ran: a save must not rewrite persistence. The Master key
      // is the sharpest probe — the resync writes it unconditionally.
      expect(await settings.loadMasterFxChain(), isNull);
    });
  });
}
