import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/theme/app_theme.dart';
import 'package:loopy/theme/looper_theme.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

void main() {
  group('AppTheme', () {
    void expectRoutingGraphMatchesSurface(
      RoutingGraphTheme? rg,
      SurfaceTheme surface,
    ) {
      expect(rg, isNotNull, reason: 'RoutingGraphTheme must be registered');
      // Anti-drift: every neutral routing-graph token is mapped straight from
      // the app's SurfaceTheme, so the two can never diverge silently.
      expect(rg!.background, surface.background);
      expect(rg.surface, surface.surface);
      expect(rg.card, surface.card);
      expect(rg.cardHigh, surface.cardHigh);
      expect(rg.line, surface.line);
      expect(rg.textPrimary, surface.textPrimary);
      expect(rg.textSecondary, surface.textSecondary);
      expect(rg.textTertiary, surface.textTertiary);
    }

    test(
      'tracks registers RoutingGraphTheme mapped from SurfaceTheme.dark',
      () {
        expectRoutingGraphMatchesSurface(
          AppTheme.neon.extension<RoutingGraphTheme>(),
          SurfaceTheme.dark,
        );
      },
    );

    test(
      'highContrast maps tokens from SurfaceTheme.highContrast',
      () {
        final theme = AppTheme.highContrast;
        expect(
          theme.extension<SurfaceTheme>(),
          same(SurfaceTheme.highContrast),
        );
        expectRoutingGraphMatchesSurface(
          theme.extension<RoutingGraphTheme>(),
          SurfaceTheme.highContrast,
        );
      },
    );

    // WCAG 1.4.3 / 1.4.11: the high-contrast palette must be strictly brighter
    // than the default so the OS "increase contrast" preference helps.
    test('high-contrast text/line tokens out-contrast the default theme', () {
      double luminance(Color c) => c.computeLuminance();
      // Relative contrast of text/line against the card it sits on.
      double ratio(Color fg, Color bg) {
        final a = luminance(fg);
        final b = luminance(bg);
        final hi = math.max(a, b);
        final lo = math.min(a, b);
        return (hi + 0.05) / (lo + 0.05);
      }

      const dark = SurfaceTheme.dark;
      const hc = SurfaceTheme.highContrast;
      // Dimmed-label text clears AA (>= 4.5:1) on the default card already...
      expect(ratio(dark.textTertiary, dark.card), greaterThanOrEqualTo(4.5));
      // ...and high contrast lifts it further.
      expect(
        ratio(hc.textTertiary, hc.card),
        greaterThan(ratio(dark.textTertiary, dark.card)),
      );
      // Non-text line/border clears the 3:1 component threshold in HC.
      expect(ratio(hc.line, hc.card), greaterThanOrEqualTo(3));
    });

    test('highContrast registers a LooperTheme', () {
      expect(
        AppTheme.highContrast.extension<LooperTheme>(),
        isNotNull,
      );
    });
  });
}
