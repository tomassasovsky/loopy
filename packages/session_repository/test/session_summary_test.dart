import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  group('SessionSummary', () {
    test('value equality and hashCode are by name', () {
      const a = SessionSummary(name: 'My Song');
      const b = SessionSummary(name: 'My Song');
      const c = SessionSummary(name: 'Other');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString names the session', () {
      expect(
        const SessionSummary(name: 'My Song').toString(),
        contains('My Song'),
      );
    });
  });
}
