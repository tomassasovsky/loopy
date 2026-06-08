import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('App', () {
    testWidgets('renders the looper as the home page', (tester) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      final controllerRepository = ControllerRepository(sources: const []);
      final settings = SettingsRepository(store: FakeKeyValueStore());
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);

      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          settings: settings,
        ),
      );
      await tester.pump();

      expect(find.byType(LooperPage), findsOneWidget);
    });
  });
}
