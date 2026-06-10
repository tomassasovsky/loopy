import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockUiModeCubit extends MockCubit<UiMode> implements UiModeCubit {}

void main() {
  group('LooperPage', () {
    testWidgets('wires its blocs and renders the looper view', (tester) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      final controllerRepository = ControllerRepository(sources: const []);
      final sessionRepository = SessionRepository(engine: FakeAudioEngine());
      final settings = SettingsRepository(store: FakeKeyValueStore());
      final uiMode = _MockUiModeCubit();
      final bank = BankCubit(settings: settings);
      whenListen(
        uiMode,
        const Stream<UiMode>.empty(),
        initialState: UiMode.desktop,
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
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UiModeCubit>.value(value: uiMode),
              BlocProvider<BankCubit>.value(value: bank),
            ],
            child: LooperPage(sessionDirectory: () async => '.'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(LooperView), findsOneWidget);
    });
  });
}
