import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

void main() {
  group('LooperPage', () {
    testWidgets('wires its blocs and renders the Tracks view', (
      tester,
    ) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      final controllerRepository = ControllerRepository(sources: const []);
      final sessionRepository = SessionRepository(engine: FakeAudioEngine());
      final settings = SettingsRepository(store: FakeKeyValueStore());
      // The looper page renders the pedal faceplate, whose gate reads a
      // PedalCubit; unbound (no on-screen pedal) it shows the TracksView.
      final sim = SimulatorPedalTransport(inner: const NoopPedalTransport());
      final pedal = _MockPedalCubit();
      when(() => pedal.state).thenReturn(const PedalState());
      whenListen(
        pedal,
        const Stream<PedalState>.empty(),
        initialState: const PedalState(),
      );
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);

      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(value: repository),
            RepositoryProvider.value(value: controllerRepository),
            RepositoryProvider.value(value: sessionRepository),
            RepositoryProvider.value(value: settings),
            RepositoryProvider<SimulatorPedalTransport>.value(value: sim),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TracksCubit>(
                create: (_) => TracksCubit(settings: settings),
              ),
              // The Tracks view reads the shared control overlay + intents —
              // created by the providers (as in the app wiring) so disposal
              // happens with the tree, not in an awaited teardown.
              RepositoryProvider<ControlOverlay>(
                create: (_) => ControlOverlay(looper: repository),
              ),
              BlocProvider<ControlOverlayCubit>(
                create: (context) => ControlOverlayCubit(
                  overlay: context.read<ControlOverlay>(),
                ),
              ),
              RepositoryProvider<ControlIntents>(
                create: (context) => ControlIntents(
                  looper: repository,
                  overlay: context.read<ControlOverlay>(),
                  settings: settings,
                ),
              ),
              BlocProvider<PedalCubit>.value(value: pedal),
            ],
            child: LooperPage(sessionDirectory: () async => '.'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(TracksView), findsOneWidget);
    });
  });
}
