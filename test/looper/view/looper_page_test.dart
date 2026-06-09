import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('LooperPage', () {
    testWidgets('wires its blocs and renders the looper view', (tester) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      final controllerRepository = ControllerRepository(sources: const []);
      final sessionRepository = SessionRepository(engine: FakeAudioEngine());
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);

      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(value: repository),
            RepositoryProvider.value(value: controllerRepository),
            RepositoryProvider.value(value: sessionRepository),
          ],
          child: LooperPage(sessionDirectory: () async => '.'),
        ),
      );
      await tester.pump();

      expect(find.byType(LooperView), findsOneWidget);
    });
  });
}
