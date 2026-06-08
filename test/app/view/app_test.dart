import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/looper/looper.dart';

import '../../helpers/helpers.dart';

void main() {
  group('App', () {
    testWidgets('renders the looper as the home page', (tester) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      addTearDown(repository.dispose);

      await tester.pumpWidget(App(repository: repository));
      await tester.pump();

      expect(find.byType(LooperPage), findsOneWidget);
    });
  });
}
