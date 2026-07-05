import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  group('sessionSlug', () {
    test('keeps a clean name unchanged (idempotent for an existing slug)', () {
      expect(sessionSlug('My Song'), 'My Song');
      expect(sessionSlug(sessionSlug('My Song')!), 'My Song');
      expect(sessionSlug('take-2_final'), 'take-2_final');
    });

    test('trims and collapses internal whitespace', () {
      expect(sessionSlug('  spaced   out  '), 'spaced out');
    });

    test('turns disallowed characters into folded spaces', () {
      expect(sessionSlug('a/b:c'), 'a b c');
      expect(sessionSlug('Song #1 (mix)'), 'Song 1 mix');
    });

    test('two distinct inputs can fold to the same slug', () {
      expect(sessionSlug('My Song!'), sessionSlug('My Song'));
      expect(sessionSlug('My Song!'), 'My Song');
    });

    test('rejects names that sanitize to nothing', () {
      expect(sessionSlug(''), isNull);
      expect(sessionSlug('   '), isNull);
      expect(sessionSlug('!!!'), isNull); // only disallowed characters
      expect(sessionSlug(r'/\:*'), isNull);
    });
  });
}
