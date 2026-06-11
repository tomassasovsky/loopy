import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';

const _a = RoutingGraphTheme(
  background: Color(0xFF000000),
  surface: Color(0xFF101010),
  card: Color(0xFF202020),
  cardHigh: Color(0xFF303030),
  line: Color(0xFF404040),
  textPrimary: Color(0xFF505050),
  textSecondary: Color(0xFF606060),
  textTertiary: Color(0xFF707070),
);

const _b = RoutingGraphTheme(
  background: Color(0xFFFFFFFF),
  surface: Color(0xFFEFEFEF),
  card: Color(0xFFDFDFDF),
  cardHigh: Color(0xFFCFCFCF),
  line: Color(0xFFBFBFBF),
  textPrimary: Color(0xFFAFAFAF),
  textSecondary: Color(0xFF9F9F9F),
  textTertiary: Color(0xFF8F8F8F),
);

void main() {
  group('RoutingGraphTheme', () {
    test('copyWith overrides only the given tokens', () {
      final result = _a.copyWith(
        card: const Color(0xFF123456),
        textPrimary: const Color(0xFF654321),
      );
      expect(result.card, const Color(0xFF123456));
      expect(result.textPrimary, const Color(0xFF654321));
      // Untouched tokens are preserved.
      expect(result.background, _a.background);
      expect(result.surface, _a.surface);
      expect(result.cardHigh, _a.cardHigh);
      expect(result.line, _a.line);
      expect(result.textSecondary, _a.textSecondary);
      expect(result.textTertiary, _a.textTertiary);
    });

    test('copyWith with no arguments returns an equal-valued theme', () {
      final result = _a.copyWith();
      expect(result.background, _a.background);
      expect(result.textTertiary, _a.textTertiary);
    });

    test('lerp at t=0 returns this, at t=1 returns the other', () {
      expect(_a.lerp(_b, 0).card, _a.card);
      expect(_a.lerp(_b, 1).card, _b.card);
    });

    test('lerp at t=0.5 interpolates each token', () {
      final mid = _a.lerp(_b, 0.5);
      expect(mid.background, Color.lerp(_a.background, _b.background, 0.5));
      expect(
        mid.textSecondary,
        Color.lerp(_a.textSecondary, _b.textSecondary, 0.5),
      );
    });

    test('lerp against a non-RoutingGraphTheme returns this unchanged', () {
      expect(_a.lerp(null, 0.5), same(_a));
    });
  });
}
