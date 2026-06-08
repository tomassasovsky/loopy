import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/duplex_smoke/duplex_smoke.dart';

import '../../helpers/helpers.dart';

void main() {
  group('App', () {
    testWidgets('renders the duplex smoke harness', (tester) async {
      await tester.pumpWidget(App(engine: FakeAudioEngine()));
      expect(find.byType(DuplexSmokePage), findsOneWidget);
    });
  });
}
