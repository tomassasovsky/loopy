import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late PerformanceRepository performance;
  late ControlCubit control;
  late PedalRepository pedalRepo;

  setUpAll(() {
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setLooperMode(any())).thenReturn(EngineResult.ok);

    settings = SettingsRepository(store: FakeKeyValueStore());
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    pedalRepo = PedalRepository(const NoopPedalTransport());
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
  });

  /// Seeds the mock bloc's [LooperState] both as the static `.state` and as
  /// the (empty, by default) stream's initial value.
  void seed(LooperState state, {Stream<LooperState>? stream}) {
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      stream ?? const Stream<LooperState>.empty(),
      initialState: state,
    );
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<ControlCubit>.value(value: control),
        ],
        child: const Scaffold(
          body: SingleChildScrollView(child: LooperModeSection()),
        ),
      ),
    ),
  );

  testWidgets('renders all five modes with Multi selected by default', (
    tester,
  ) async {
    seed(const LooperState());
    await pump(tester);

    for (final mode in LooperMode.values) {
      expect(
        find.byKey(Key('looperMode_option_${mode.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets(
    'selecting a different mode with NO track content applies '
    'immediately, with no confirmation dialog',
    (tester) async {
      seed(const LooperState()); // no tracks => hasContent is false
      await pump(tester);

      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('looperMode_confirm_dialog')), findsNothing);
      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.sync)),
      ).called(1);
    },
  );

  testWidgets('re-selecting the already-active mode is a no-op', (
    tester,
  ) async {
    seed(const LooperState());
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_multi')));
    await tester.pumpAndSettle();

    verifyNever(() => bloc.add(any()));
  });

  testWidgets(
    'selecting a different mode WHILE a track has content shows the D4 '
    'confirmation dialog and does NOT dispatch the mode change until '
    'confirmed — the engine would otherwise silently drop it',
    (tester) async {
      const hasContent = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 4000),
        ],
      );
      seed(hasContent);
      await pump(tester);

      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();

      // The confirmation is shown, and the mode change is NOT dispatched yet
      // — this is the exact silent-no-op the D4 UX flow exists to prevent.
      expect(
        find.byKey(const Key('looperMode_confirm_dialog')),
        findsOneWidget,
      );
      verifyNever(() => bloc.add(any()));
    },
  );

  testWidgets('cancelling the D4 confirmation leaves the mode unchanged', (
    tester,
  ) async {
    const hasContent = LooperState(
      tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
    );
    seed(hasContent);
    await pump(tester);

    await tester.tap(find.byKey(const Key('looperMode_option_sync')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('looperMode_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('looperMode_confirm_dialog')),
      findsNothing,
    );
    verifyNever(() => bloc.add(any()));
    // Nothing was cleared either — a cancel is a true no-op.
    verifyNever(() => repository.clear(channel: any(named: 'channel')));
  });

  testWidgets(
    'confirming the D4 dialog clears every track then dispatches the mode '
    'change — never a silent no-op',
    (tester) async {
      final controller = StreamController<LooperState>.broadcast();
      addTearDown(controller.close);
      const hasContent = LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
      );
      seed(hasContent, stream: controller.stream);
      // ControlCubit.clearAll() reads the LIVE repository snapshot (not the
      // bloc's cached state) to decide which tracks to clear.
      when(() => repository.state).thenReturn(hasContent);
      await pump(tester);

      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('looperMode_confirm_confirm')));
      // Let the confirm handler's `clearAll()` await settle and reach the
      // "await the bloc report cleared" point.
      await tester.pump();

      // ControlCubit.clearAll() actually cleared the content-bearing track
      // (channel 0, the interface default).
      verify(() => repository.clear()).called(1);

      // The mode change is still not dispatched — the flow is waiting for
      // the bloc to report the clear before it will proceed (the race this
      // whole mechanism exists to close).
      verifyNever(() => bloc.add(any()));

      // Simulate the repository's poll tick republishing the now-cleared
      // state through the bloc's stream (what LooperRepository's real
      // ticker does after a clear lands on the audio thread).
      const cleared = LooperState();
      when(() => bloc.state).thenReturn(cleared);
      controller.add(cleared);
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.sync)),
      ).called(1);
    },
  );

  testWidgets(
    'a clear that never settles within the bounded wait still does NOT '
    'dispatch the mode change — the timeout path must re-check, not '
    'dispatch unconditionally (that would recreate the exact silent D4 '
    'no-op this flow exists to prevent) — and surfaces a visible SnackBar '
    '(independent review of #295: the confirm dialog is already gone by '
    'this point, so without the SnackBar the timeout looked identical to a '
    'tap that never registered)',
    (tester) async {
      final controller = StreamController<LooperState>.broadcast();
      addTearDown(controller.close);
      const hasContent = LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
      );
      seed(hasContent, stream: controller.stream);
      when(() => repository.state).thenReturn(hasContent);
      await pump(tester);

      await tester.tap(find.byKey(const Key('looperMode_option_sync')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('looperMode_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => repository.clear()).called(1);

      // The confirm dialog is already dismissed at this point (its pop
      // animation has settled) — before the SnackBar fix, the screen here
      // looked identical to before the user ever tapped anything.
      expect(find.byKey(const Key('looperMode_confirm_dialog')), findsNothing);
      expect(
        find.byKey(const Key('looperMode_timeout_snackbar')),
        findsNothing,
      );

      // Never push a cleared state — the bloc keeps reporting content, so
      // the bounded wait runs out its full timeout.
      await tester.pump(const Duration(seconds: 3));

      // The mode change must never have been dispatched — dispatching it
      // while `bloc.state` still reports content would be silently dropped
      // by the engine's D4 lock, the exact failure mode this whole
      // confirm-then-clear-then-switch flow exists to prevent.
      verifyNever(() => bloc.add(any()));

      // But the timeout is no longer silent: a SnackBar tells the user to
      // retry, instead of leaving them with zero information.
      await tester.pump();
      expect(
        find.byKey(const Key('looperMode_timeout_snackbar')),
        findsOneWidget,
      );
    },
  );
}
